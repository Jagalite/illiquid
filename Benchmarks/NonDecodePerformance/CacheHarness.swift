import Foundation

func key(_ index: Int, path: String = "/movie.mkv") -> NativeThumbnailCache.Key {
    .init(path: path, version: "v1", halfSecond: index, width: 320, height: 180)
}

@main struct Main {
    static func main() async {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "benchmark" {
            let mode = args[2], iterations = Int(args[3])!
            if mode == "hex" {
                var digests: [[UInt8]] = []
                for i in 0..<256 { digests.append((0..<32).map { UInt8(($0 + i) % 256) }) }
                var checksum = 0
                let start = DispatchTime.now().uptimeNanoseconds
                for i in 0..<iterations {
                    #if CANDIDATE
                    let result = NativeThumbnailCache.Key.hexadecimal(digests[i % digests.count])
                    #else
                    let result = digests[i % digests.count].map { String(format: "%02x", $0) }.joined()
                    #endif
                    checksum += result.utf8.count + Int(result.utf8.first!)
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                print("{\"operation\":\"hex\",\"iterations\":\(iterations),\"ms_per_call\":\(elapsed/Double(iterations)),\"checksum\":\(checksum)}")
                return
            }
            let cache = NativeThumbnailCache()
            var settings = ThumbnailPreferences(); settings.memoryMiB = 128; settings.diskMiB = 0
            await cache.configure(settings)
            for i in 0..<96 {
                await cache.insert(CGImage(bytesPerRow: 1280, height: 180, token: i), for: key(i), background: i % 3 != 0,
                    storyboard: i >= 80)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            var checksum = 0
            for _ in 0..<iterations {
                if await cache.admitsBackground(size: CGSize(width: 320, height: 180)) { checksum += 1 }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            print("{\"operation\":\"admission_actor_roundtrip\",\"iterations\":\(iterations),\"ms_per_call\":\(elapsed/Double(iterations)),\"checksum\":\(checksum)}")
            return
        }
        var checks = 0
        #if CANDIDATE
        for value in 0..<256 {
            let bytes = [UInt8(value)]
            precondition(NativeThumbnailCache.Key.hexadecimal(bytes) == String(format: "%02x", value))
            checks += 1
        }
        precondition(NativeThumbnailCache.Key.hexadecimal([UInt8]()) == ""); checks += 1
        for length in [1,2,31,32,33,64,256,1024] {
            let bytes = (0..<length).map { UInt8(($0 * 137 + length) % 256) }
            precondition(NativeThumbnailCache.Key.hexadecimal(bytes) == bytes.map { String(format:"%02x",$0) }.joined())
            checks += 1
        }
        #endif
        // Differential output includes decisions and survivor identities; no timing.
        var trace: [String] = []
        for budget in [8,16,128] {
            for pattern in 0..<4 {
                let cache = NativeThumbnailCache()
                var settings = ThumbnailPreferences(); settings.memoryMiB = budget; settings.diskMiB = 0
                await cache.configure(settings)
                for i in 0..<130 {
                    let background = pattern == 0 ? false : pattern == 1 ? true : i % 3 != 0
                    await cache.insert(CGImage(bytesPerRow: 1280 + i % 3 * 64, height: 180, token: i), for: key(i), background: background,
                        storyboard: pattern == 3 && i % 5 == 0)
                    let size = CGSize(width: [160.0,320.0,1024.0][i % 3], height: 180)
                    let admits = await cache.admitsBackground(size: size)
                    let usage = await cache.usage()
                    precondition(usage.memoryBytes <= budget * 1024 * 1024 && usage.images <= 96)
                    trace.append("\(budget):\(pattern):\(i):\(admits):\(usage.memoryBytes):\(usage.images)")
                    checks += 1
                }
                // Warning retains the same victims/order/protection as baseline.
                await cache.trimForMemoryPressure(critical: false)
                for i in 0..<130 {
                    if let image = await cache.image(for: key(i), background: true) { trace.append("survivor:\(image.token)") }
                }
                await cache.trimForMemoryPressure(critical: true)
                let usage = await cache.usage()
                precondition(usage.memoryBytes == 0 && usage.images == 0)
                let readmitted = await cache.admitsBackground(size: CGSize(width: 320,height:180)); precondition(readmitted)
                checks += 2
                // Public API remains usable after a critical purge.
                await cache.insert(CGImage(bytesPerRow: 1280,height:180,token:999), for:key(999),background:false,storyboard:true)
                let reloaded = await cache.image(for: key(999),background:true); precondition(reloaded?.token == 999)
                checks += 1
            }
        }
        // Verify cache-owned references disappear; do not claim process RSS returns.
        do {
            let cache = NativeThumbnailCache()
            var image: CGImage? = CGImage(bytesPerRow:1280,height:180)
            weak var witness: CGImage?
            witness = image
            await cache.insert(image!,for:key(0),background:false)
            image = nil
            precondition(witness != nil)
            await cache.trimForMemoryPressure(critical:true)
            precondition(witness == nil)
            checks += 2
            #if CANDIDATE
            for size in [CGSize(width:CGFloat.infinity,height:180), CGSize(width:CGFloat.nan,height:180),
                         CGSize(width:-1,height:180),CGSize(width:0,height:180),CGSize(width:2049,height:180)] {
                let invalid = await cache.admitsBackground(size:size); precondition(!invalid); checks += 1
            }
            #endif
        }
        // Emit a deterministic trace to compare baseline/candidate externally.
        print(trace.joined(separator:"\n"))
        print("checks=\(checks)")
    }
}
