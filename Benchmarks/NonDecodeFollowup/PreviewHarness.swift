import Foundation

func key(_ position: Int) -> NativeThumbnailCache.Key {
    .init(path: "/synthetic/video.mkv", version: "1", halfSecond: position, width: 16, height: 16)
}
func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("illiquid-preview-research-" + UUID().uuidString)
}
func awaitSignal(_ signal: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            precondition(signal.wait(timeout: .now() + 10) == .success, "test gate did not open")
            continuation.resume()
        }
    }
}

@main struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "tests" {
            try await tests(); return
        }
        let milliseconds = Int(args[1])!, mode = args[2]
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let cache = NativeThumbnailCache(directory: path)
        let image = CGImage()
        await cache.insert(image, for: key(1), background: mode != "hot")
        await cache.flushPendingWrites()
        let disk = await cache.testDisk()
        let delivered = Flag(), deliveredBeforeRelease = Flag()
        var blocker: Task<Void, Never>?
        if mode != "unblocked" {
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            blocker = Task.detached { await disk.testBlock(started: started, release: release) }
            await awaitSignal(started)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                if delivered.get() { deliveredBeforeRelease.set() }
                release.signal()
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let found = await cache.image(for: key(1), background: false)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(found === image)
        delivered.set()
        if let blocker { await blocker.value }
        await cache.flushPendingWrites()
        let foreground = await disk.testIsBackground(key(1)) == false
        precondition(foreground)
        if mode == "promotion" {
            #if CANDIDATE
            precondition(deliveredBeforeRelease.get(), "candidate resident hit waited behind the blocked disk actor")
            #else
            precondition(!deliveredBeforeRelease.get(), "baseline no longer reproduces the blocked promotion")
            #endif
        }
        if mode == "hot" { precondition(deliveredBeforeRelease.get(), "unchanged hot-hit control blocked") }
        let data = try JSONSerialization.data(withJSONObject: [
            "injected_disk_block_ms": milliseconds, "mode": mode,
            "resident_hit_ns": elapsed, "delivered_before_disk_release": mode == "unblocked" ? NSNull() : deliveredBeforeRelease.get() as Any,
            "foreground_metadata_after_flush": foreground
        ], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func tests() async throws {
        var checks = 0
        #if CANDIDATE
        // Reservations are in place while the disk actor is unavailable. Either
        // drainer/insert execution order must preserve the claimed foreground file.
        for _ in 0..<30 {
            let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
            let disk = NativeThumbnailDiskCache(directory: path)
            var preferences = ThumbnailPreferences(); preferences.diskMiB = 1
            await disk.configure(preferences)
            let large = CGImage(payloadBytes: 800_000)
            await disk.insert(large, for: key(1), background: true, epoch: 0)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let blocker = Task.detached { await disk.testBlock(started: entered, release: release) }
            await awaitSignal(entered)
            precondition(disk.enqueuePromotion(key(1), epoch: 0))
            let insertion = Task(priority: .userInitiated) {
                await disk.insert(large, for: key(2), background: true, epoch: 0)
            }
            release.signal()
            await blocker.value; await insertion.value; await disk.flushPromotions()
            let protected = await disk.testIsBackground(key(1))
            let speculative = await disk.testIsBackground(key(2))
            precondition(protected == false && speculative == nil)
            checks += 2
        }
        // An encoding suspension may outlive dequeue of its promotion; promotion
        // must latch onto the in-flight encode, not vanish with the queue entry.
        do {
            let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
            let gate = EncodeGate()
            let disk = NativeThumbnailDiskCache(directory: path, encode: { image in
                await gate.wait(); return image.encoded()
            })
            let pending = Task { await disk.insert(CGImage(), for: key(1), background: true, epoch: 0) }
            await awaitSignal(gate.entered)
            precondition(disk.enqueuePromotion(key(1), epoch: 0))
            await disk.flushPromotions()
            await gate.open(); await pending.value
            let background = await disk.testIsBackground(key(1))
            precondition(background == false); checks += 1
        }
        // The bounded queue never discards existing claims to admit a newer one.
        do {
            let disk = NativeThumbnailDiskCache(directory: nil)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let blocker = Task.detached { await disk.testBlock(started: entered, release: release) }
            await awaitSignal(entered)
            for i in 0..<128 { precondition(disk.enqueuePromotion(key(i), epoch: 0)); checks += 1 }
            precondition(!disk.enqueuePromotion(key(128), epoch: 0)); checks += 1
            release.signal(); await blocker.value; await disk.flushPromotions()
            let count = await disk.testPendingPromotions()
            precondition(count == 0); checks += 1
        }
        #endif
        // Clear while encoding cannot resurrect an older epoch's disk or RAM entry.
        do {
            let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
            let gate = EncodeGate()
            let cache = NativeThumbnailCache(directory: path, encode: { image in
                await gate.wait(); return image.encoded()
            })
            await cache.insert(CGImage(), for: key(1), background: true)
            await awaitSignal(gate.entered)
            let cleared = await cache.clear(); precondition(cleared)
            await gate.open(); await cache.flushPendingWrites()
            let usage = await cache.usage()
            precondition(usage.memoryBytes == 0 && usage.diskBytes == 0 && usage.images == 0)
            checks += 3
        }
        // Warning/critical pressure and restart loading still use actual actor
        // bookkeeping and actual FileManager I/O, but test images are NOT JPEGs.
        do {
            let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
            let cache = NativeThumbnailCache(directory: path)
            await cache.insert(CGImage(token: 11), for: key(1), background: true)
            await cache.flushPendingWrites()
            await cache.trimForMemoryPressure(critical: true)
            let restored = await cache.image(for: key(1), background: false)
            precondition(restored?.token == 11)
            await cache.flushPendingWrites()
            let restarted = NativeThumbnailCache(directory: path)
            let diskRestored = await restarted.image(for: key(1), background: false)
            precondition(diskRestored?.token == 11)
            checks += 2
        }
        print("{\"preview_integration_checks\":\(checks),\"image_adapter\":\"test-only non-JPEG\",\"filesystem\":\"real Foundation\"}")
    }
}
