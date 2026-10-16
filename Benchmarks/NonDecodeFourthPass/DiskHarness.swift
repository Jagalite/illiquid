// Production cache control flow, real filesystem, explicitly synthetic image bytes.
import Foundation
#if os(Linux)
import Glibc
#endif
#if ALLOCATION_METER
@_silgen_name("meter_begin") func meter_begin()
@_silgen_name("meter_end") func meter_end()
@_silgen_name("meter_requests") func meter_requests() -> UInt64
@_silgen_name("meter_bytes") func meter_bytes() -> UInt64
#endif
struct CheckFailure: Error, CustomStringConvertible { let description: String }
@main struct DiskHarness {
    static func key(_ n: Int) -> NativeThumbnailCache.Key {
        .init(path: "/test/\(n).mkv", version: "v1", halfSecond: n, width: 64, height: 64)
    }
    static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("illiquid-v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    static func put(_ root: URL, _ key: NativeThumbnailCache.Key, foreground: Bool, token: Int = 1, bytes: Int = 128) throws {
        try CGImage(token: token, payloadBytes: bytes).encoded().write(to: path(root, key, foreground))
    }
    static func path(_ root: URL, _ key: NativeThumbnailCache.Key, _ foreground: Bool) -> URL {
        root.appendingPathComponent("\(foreground ? "f" : "b")-\(key.digest).jpg")
    }
    static func physical(_ root: URL) throws -> (Int, Int) {
        let list = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var count = 0, bytes = 0
        for url in list where url.pathExtension == "jpg" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { count += 1; bytes += values.fileSize ?? 0 }
        }; return (count, bytes)
    }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 1 || args[1] == "tests" { try await tests(); return }
        let mode = args[1], n = Int(args[2])!, iterations = args.count > 3 ? Int(args[3])! : 1
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = key(1_000_000)
        for i in 0..<n {
            let k = key(i)
            try put(root, k, foreground: false)
            // Distinct dates for deterministic trim workloads.
            if mode == "churn" { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i))], ofItemAtPath: path(root,k,false).path) }
        }
        if mode == "first-fg" || mode == "warm" { try put(root,target,foreground:true,token:42) }
        if mode == "first-bg" || mode == "background" { try put(root,target,foreground:false,token:42) }
        let cache = NativeThumbnailDiskCache(directory: root)
        if mode == "warm" || mode == "churn" { _ = await cache.bytes() }
        var tokens = 0
        #if ALLOCATION_METER
        meter_begin()
        #endif
        let begin = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations {
            switch mode {
            case "inventory": tokens += await cache.bytes()
            case "series": tokens += await cache.image(for:key(i % max(1,n)),background:false)?.token ?? 0
            case "churn":
                await cache.insert(CGImage(token:i,payloadBytes:128),for:key(2_000_000+i),background:true,epoch:0)
                tokens += 1
            default:
                tokens += await cache.image(for:target,background:mode == "background")?.token ?? 0
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - begin
        #if ALLOCATION_METER
        meter_end()
        #endif
        let stats = await cache.testStats()
        var row: [String: Any] = ["mode":mode,"count":n,"iterations":iterations,"elapsed_ns":elapsed,"tokens":tokens,
            "inventoried_before_usage":stats.inventoried,"indexed_count_before_usage":stats.count]
        #if ALLOCATION_METER
        row["allocation_requests"] = meter_requests(); row["allocation_request_bytes"] = meter_bytes()
        #endif
        let usageBegin = DispatchTime.now().uptimeNanoseconds
        let finalBytes = await cache.bytes()
        row["usage_after_ns"] = DispatchTime.now().uptimeNanoseconds - usageBegin
        row["read_plus_usage_ns"] = elapsed + (row["usage_after_ns"] as! UInt64)
        let final = try physical(root)
        row["final_accounted_bytes"] = finalBytes; row["physical_bytes"] = final.1
        row["physical_files"] = final.0
        guard finalBytes == final.1 else { throw CheckFailure(description:"benchmark accounting mismatch") }
        let expectedToken = ["first-fg","first-bg","background","warm"].contains(mode) ? iterations * 42 : (mode == "miss" ? 0 : tokens)
        guard tokens == expectedToken else { throw CheckFailure(description:"unexpected return token") }
        try emit(row)
    }
    static func tests() async throws {
        var checks = 0, cases = 0
        func check(_ value: Bool, _ label: String) throws {
            checks += 1; if !value { throw CheckFailure(description:label) }
        }
        // Baseline diagnostic: do not label a known incorrect result as a passing test.
        do {
            let root=try directory(); defer { try? FileManager.default.removeItem(at:root) }
            let k=key(0);try put(root,k,foreground:false,token:11,bytes:128);try put(root,k,foreground:true,token:22,bytes:256)
            let cache=NativeThumbnailDiskCache(directory:root)
            let bytes=await cache.bytes(), result=await cache.image(for:k,background:true)
            let cleared=await cache.clear(epoch:1), remaining=try physical(root)
            #if CANDIDATE
            try check(bytes==384,"all physical duplicate bytes counted")
            try check(result?.token==22,"foreground duplicate preferred")
            try check(cleared && remaining.0==0,"both aliases cleared")
            #else
            try emit(["diagnostic":"duplicate-v3","accounted":bytes,"physical_before":384,"selected_token":result?.token ?? -1,"clear_reported":cleared,"files_remaining":remaining.0])
            #endif
            cases += 1
        }
        #if CANDIDATE
        // Both creation orders, both pre-inventoried and direct reads.
        for reverse in [false,true] { for inventory in [false,true] {
            let root=try directory(); defer { try? FileManager.default.removeItem(at:root) }
            let k=key(1)
            for fg in reverse ? [true,false] : [false,true] {try put(root,k,foreground:fg,token:fg ? 22:11,bytes:fg ? 256:128)}
            let cache=NativeThumbnailDiskCache(directory:root); if inventory { _=await cache.bytes() }
            try check(await cache.image(for:k,background:false)?.token==22,"foreground precedence independent of enumeration order")
            try check(await cache.bytes()==384,"lookup preserves accounting of valid backup")
            try check(await cache.clear(epoch:1),"clear succeeds")
            try check(try physical(root).0==0,"clear removes both copies")
            cases += 1
        }}
        // Corrupt preferred copy, valid backup; only corrupt physical file is dropped.
        for inventory in [false,true] {
            let root=try directory(); defer { try? FileManager.default.removeItem(at:root) }
            let k=key(2);try put(root,k,foreground:false,token:9)
            try Data("corrupt".utf8).write(to:path(root,k,true))
            let cache=NativeThumbnailDiskCache(directory:root); if inventory {_=await cache.bytes()}
            try check(await cache.image(for:k,background:false)?.token==9,"fallback survives corrupt foreground")
            try check(await cache.bytes()==128,"corrupt alias removed, good one counted once")
            try check(try physical(root).0==1,"promotion leaves one regular file")
            cases += 1
        }
        // Duplicate count/byte budgets, protected foreground tier.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(3);try put(root,k,foreground:false,bytes:600_000);try put(root,k,foreground:true,token:7,bytes:600_000)
            let cache=NativeThumbnailDiskCache(directory:root);var prefs=ThumbnailPreferences();prefs.diskMiB=1;await cache.configure(prefs)
            try check(await cache.bytes()==600_000,"byte budget sees both copies")
            try check(await cache.image(for:k,background:true)?.token==7,"background duplicate evicted first")
            try check(try physical(root).0==1,"physical quota enforced")
            cases += 1
        }
        // Failure removes other known files but keeps failure accounted and returns false.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(4);try put(root,k,foreground:false);try put(root,k,foreground:true,bytes:256)
            let cache=NativeThumbnailDiskCache(directory:root);_=await cache.bytes()
            let replaced=path(root,k,true);try FileManager.default.removeItem(at:replaced)
            try FileManager.default.createDirectory(at:replaced,withIntermediateDirectories:true)
            try Data([1]).write(to:replaced.appendingPathComponent("sentinel"))
            try check(!(await cache.clear(epoch:1)),"failed unlink is not clear success")
            try check(FileManager.default.fileExists(atPath:replaced.appendingPathComponent("sentinel").path),"never recursively remove sentinel")
            try check(await cache.bytes()==256,"failed physical removal remains conservatively accounted")
            try check(!FileManager.default.fileExists(atPath:path(root,k,false).path),"other alias removed despite failure")
            cases += 1
        }
        // Fallback's promotion must not overwrite a directory occupying f-name.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(5);try put(root,k,foreground:false,token:8)
            try FileManager.default.createDirectory(at:path(root,k,true),withIntermediateDirectories:true)
            let cache=NativeThumbnailDiskCache(directory:root)
            try check(await cache.image(for:k,background:false)?.token==8,"directory alias ignored")
            try check(await cache.testIsBackground(k)==false,"failed rename retains foreground tier")
            try check(await cache.bytes()==128,"only regular file counted")
            try check(await cache.clear(epoch:1),"recognized files cleared")
            try check(FileManager.default.fileExists(atPath:path(root,k,true).path),"unrecognized directory untouched")
            cases += 1
        }
        // File disappeared after indexing; stale destination accounting reconciled on move.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(6);try put(root,k,foreground:false,token:17);try put(root,k,foreground:true,bytes:256)
            let cache=NativeThumbnailDiskCache(directory:root);_=await cache.bytes()
            try FileManager.default.removeItem(at:path(root,k,true))
            try check(await cache.image(for:k,background:false)?.token==17,"missing alias falls back")
            try check(await cache.bytes()==128,"reconciled bytes after disappeared alias")
            cases += 1
        }
        // Reservations cover both physical aliases by logical digest.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(7);try put(root,k,foreground:false,bytes:700_000)
            let cache=NativeThumbnailDiskCache(directory:root);var prefs=ThumbnailPreferences();prefs.diskMiB=1;await cache.configure(prefs);_=await cache.bytes()
            try check(await cache.testReservation(k.digest),"reserve foreground digest")
            await cache.insert(CGImage(payloadBytes:700_000),for:key(8),background:true,epoch:0)
            try check(await cache.image(for:k,background:true) != nil,"reservation prevents eviction")
            try check(await cache.image(for:key(8),background:true)==nil,"speculative insert rejected instead")
            await cache.testReleaseReservations();cases += 1
        }
        // Clear during encoding does not repopulate old epoch.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let gate=EncodeGate();let cache=NativeThumbnailDiskCache(directory:root,encode:{image in await gate.wait();return image.encoded()})
            let task=Task{await cache.insert(CGImage(),for:key(10),background:true,epoch:0)}
            let entered = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: gate.entered.wait(timeout: .now() + 10) == .success)
                }
            }
            try check(entered, "encoder entered before clear")
            try check(await cache.clear(epoch:1),"clear during encode")
            await gate.open();await task.value
            try check(await cache.bytes()==0 && (try physical(root).0)==0,"old encode cannot resurrect")
            cases += 1
        }
        // Static final-component symlink is not a readable cache entry.
        do {
            let root=try directory(), other=try directory()
            defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:other)}
            let k=key(12), target=other.appendingPathComponent("outside")
            try CGImage(token:99).encoded().write(to:target)
            try put(root,k,foreground:false,token:77)
            try FileManager.default.createSymbolicLink(at:path(root,k,true),withDestinationURL:target)
            let cache=NativeThumbnailDiskCache(directory:root)
            try check(await cache.image(for:k,background:false)?.token==77,"do not follow a cache symlink")
            try check(await cache.clear(epoch:1),"clear known regular file")
            try check(try CGImage.decode(Data(contentsOf:target))?.token==99,"outside symlink target unchanged")
            cases += 1
        }
        // Count quota uses physical files, including duplicate aliases.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            for i in 0..<4097 {try put(root,key(30_000+i),foreground:false);try put(root,key(30_000+i),foreground:true)}
            let cache=NativeThumbnailDiskCache(directory:root)
            let bytes=await cache.bytes(), count=try physical(root).0
            try check(count==8191 && bytes==8191*128,"physical count quota includes duplicate aliases")
            for i in 0..<4097 {try check(FileManager.default.fileExists(atPath:path(root,key(30_000+i),true).path),"foreground alias survives background trim")}
            try check(await cache.clear(epoch:1),"clear full duplicate inventory")
            try check(try physical(root).0==0,"no duplicate orphan remains")
            cases += 1
        }
        // Deterministic mixed operations, real filesystem compared after every op.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let cache=NativeThumbnailDiskCache(directory:root);var prefs=ThumbnailPreferences();prefs.diskMiB=1;await cache.configure(prefs)
            var state:UInt64=0x12345678,epoch:UInt64=0
            for i in 0..<600 {
                state=state &* 6364136223846793005 &+ 1442695040888963407
                let k=key(Int((state>>8)%48));let op=Int(state%7)
                switch op {
                case 0,1,2: await cache.insert(CGImage(token:i,payloadBytes:40_000+Int(state%4)*1000),for:k,background:op != 0,epoch:epoch)
                case 3: _=await cache.image(for:k,background:false)
                case 4: _=cache.enqueuePromotion(k,epoch:epoch);await cache.flushPromotions()
                case 5: _=await cache.image(for:k,background:true)
                default: if i%31==0 {epoch += 1;try check(await cache.clear(epoch:epoch),"mixed clear")}
                }
                let actual=try physical(root), bytes=await cache.bytes(), stats=await cache.testStats()
                try check(bytes==actual.1,"physical bytes match index at op \(i)")
                try check(stats.count==actual.0,"physical file count matches at op \(i)")
                try check(bytes<=1_048_576,"budget holds at op \(i)")
            };cases += 1
        }
        #endif
        #if DIRECT_LOOKUP
        // No full inventory or retained partial index across foreground-only misses/hits.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(500);try put(root,k,foreground:false,token:23)
            let cache=NativeThumbnailDiskCache(directory:root)
            for i in 0..<100 {
                let match=await cache.image(for:i%2==0 ? k:key(1000+i),background:false)
                try check(i%2==0 ? match?.token==23:match==nil,"exact hit/miss")
                let stats=await cache.testStats()
                try check(!stats.inventoried && stats.count==0 && stats.bytes==0,"no growing partial index")
            }
            try check(await cache.bytes()==128,"usage forces correct inventory")
            try check(await cache.testStats().inventoried,"usage inventories")
            cases += 1
        }
        // Promotion before inventory, both enqueue and awaited paths.
        for queued in [false,true] {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            let k=key(501);try put(root,k,foreground:false)
            let cache=NativeThumbnailDiskCache(directory:root)
            if queued {try check(cache.enqueuePromotion(k,epoch:0),"queued reservation");await cache.flushPromotions()}
            else {await cache.promote(k,epoch:0)}
            try check(FileManager.default.fileExists(atPath:path(root,k,true).path),"exact promotion persisted")
            try check(!(await cache.testStats().inventoried),"promotion avoids scan")
            try check(await cache.bytes()==128,"later inventory counts promotion once")
            cases += 1
        }
        // Direct read does not admit new disk bytes until complete budget enforcement.
        do {
            let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
            try put(root,key(510),foreground:true,token:2,bytes:700_000);try put(root,key(511),foreground:false,bytes:700_000)
            let cache=NativeThumbnailDiskCache(directory:root);var prefs=ThumbnailPreferences();prefs.diskMiB=1;await cache.configure(prefs)
            try check(await cache.image(for:key(510),background:false)?.token==2,"read preexisting oversized cache")
            try check(!(await cache.testStats().inventoried),"direct read is not inventory")
            await cache.insert(CGImage(payloadBytes:100_000),for:key(512),background:true,epoch:0)
            try check(await cache.testStats().inventoried,"insertion forces full scan")
            try check(try physical(root).1<=1_048_576,"new bytes admitted only inside quota")
            try check(await cache.bytes()==(try physical(root).1),"full accounting after new insert")
            cases += 1
        }
        #endif
        try emit(["checks":checks,"cases":cases,"result":"passed","image_adapter":true])
    }
}
