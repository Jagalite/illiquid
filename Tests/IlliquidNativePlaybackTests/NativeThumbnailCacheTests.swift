import CoreGraphics
import Foundation
import ImageIO
import Testing
import IlliquidCore
@testable import IlliquidNativePlayback

@Suite("Global thumbnail cache")
struct NativeThumbnailCacheTests {
    @Test func residentEntryLimitEvictsEvenBelowByteBudget() async throws {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences(); settings.diskMiB = 0
        await cache.configure(settings)
        let value = try image(width: 16, height: 16)
        for position in 0..<97 {
            await cache.insert(value, for: key(position), background: false)
        }
        #expect(await cache.usage().images == 96)
        #expect(await cache.image(for: key(0), background: false) == nil)
        #expect(await cache.image(for: key(96), background: false) != nil)
    }

    @Test func protectedEntryLimitRejectsSpeculativeDecode() async throws {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences(); settings.diskMiB = 0
        await cache.configure(settings)
        let value = try image(width: 16, height: 16)
        for position in 0..<96 {
            await cache.insert(value, for: key(position), background: true, storyboard: true)
        }
        #expect(await cache.usage().images == 96)
        #expect(!(await cache.admitsBackground(size: CGSize(width: 16, height: 16))))
        await cache.selectStoryboardSource(.init(path: "/other.mkv", version: "new", halfSecond: 0, width: 16, height: 16))
        #expect(await cache.admitsBackground(size: CGSize(width: 16, height: 16)))
    }

    @Test func storyboardApproximationLoadsFromDiskAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NativeThumbnailCache(directory: directory)
        let value = try image()
        await cache.insert(value, for: key(200), background: true, storyboard: true)
        await cache.flushPendingWrites()
        let restarted = NativeThumbnailCache(directory: directory)
        let match = try #require(await restarted.nearest(to: key(500), maximumDistance: 7_200, fallbackTimes: [100]))
        #expect(match.1 == 100 && match.0.width == value.width)
        #expect(await restarted.nearest(to: key(500), maximumDistance: 30, fallbackTimes: [100]) == nil)
        let replaced = NativeThumbnailCache.Key(path: key(500).path, version: "replacement", halfSecond: 500, width: 2048, height: 2048)
        #expect(await restarted.nearest(to: replaced, maximumDistance: 7_200, fallbackTimes: [100]) == nil)
    }

    @Test func localPreparationCannotEvictStoryboardButPressureCan() async throws {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences(); settings.memoryMiB = 8; settings.diskMiB = 0
        await cache.configure(settings)
        let large = try image(width: 1024, height: 1024)
        await cache.insert(large, for: key(1), background: true, storyboard: true)
        await cache.insert(large, for: key(2), background: true, storyboard: true)
        #expect(!(await cache.admitsBackground(size: CGSize(width: 1024, height: 1024))))
        await cache.insert(large, for: key(3), background: true)
        #expect(await cache.image(for: key(1), background: true) != nil)
        #expect(await cache.image(for: key(2), background: true) != nil)
        #expect(await cache.image(for: key(3), background: true) == nil)
        let nextSource = NativeThumbnailCache.Key(path: "/test/next.mkv", version: "2", halfSecond: 0, width: 2048, height: 2048)
        await cache.selectStoryboardSource(nextSource)
        #expect(await cache.admitsBackground(size: CGSize(width: 1024, height: 1024)))
        await cache.trimForMemoryPressure(critical: true)
        #expect(await cache.usage().images == 0)
    }

    @Test func memoryPressureReclaimsSpeculativeImagesFirstAndPreservesDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NativeThumbnailCache(directory: directory)
        let value = try image(width: 512, height: 512)
        await cache.insert(value, for: key(1), background: false)
        await cache.flushPendingWrites()
        await cache.insert(value, for: key(2), background: true)
        await cache.flushPendingWrites()
        let diskBytes = await cache.usage().diskBytes
        #expect(diskBytes > 0)
        await cache.trimForMemoryPressure(critical: false)
        #expect(await cache.usage().memoryBytes == value.bytesPerRow * value.height)
        #expect(await cache.image(for: key(1), background: false) === value)
        await cache.trimForMemoryPressure(critical: true)
        #expect(await cache.usage().memoryBytes == 0)
        #expect(await cache.usage().images == 0)
        #expect(await cache.usage().diskBytes == diskBytes)
        #expect(await cache.image(for: key(2), background: false) != nil)
        let restarted = NativeThumbnailCache(directory: directory)
        #expect(await restarted.usage().diskBytes == diskBytes)
    }
    private actor EncodingGate {
        var isBlocked = false
        private var continuation: CheckedContinuation<Void, Never>?
        var hasStarted: Bool { continuation != nil }
        func block() { isBlocked = true }
        func wait() async {
            if isBlocked { await withCheckedContinuation { continuation = $0 } }
        }
        func resume() {
            isBlocked = false
            continuation?.resume(); continuation = nil
        }
    }
    private static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    func image(width: Int = 100, height: Int = 100) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    func key(_ time: Int) -> NativeThumbnailCache.Key {
        .init(path: "/test/video.mkv", version: "1", halfSecond: time, width: 2048, height: 2048)
    }

    @Test func backgroundCannotEvictForegroundWhenMemoryIsFull() async throws {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences(); settings.memoryMiB = 8; settings.diskMiB = 0
        await cache.configure(settings)
        let large = try image(width: 1024, height: 1024)
        await cache.insert(large, for: key(1), background: false)
        await cache.insert(large, for: key(2), background: false)
        await cache.insert(large, for: key(3), background: true)
        #expect(await cache.image(for: key(1), background: false) === large)
        #expect(await cache.image(for: key(2), background: false) === large)
        #expect(await cache.image(for: key(3), background: true) == nil)
        #expect(await cache.usage().memoryBytes == 8 * 1024 * 1024)
    }

    @Test func foregroundHitPromotesSpeculativeMemoryAndShrinkingEvictsBackgroundFirst() async throws {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences(); settings.memoryMiB = 16; settings.diskMiB = 0
        await cache.configure(settings)
        let large = try image(width: 1024, height: 1024)
        for time in 1...3 { await cache.insert(large, for: key(time), background: true) }
        #expect(await cache.image(for: key(1), background: false) != nil)
        settings.memoryMiB = 8; await cache.configure(settings)
        #expect(await cache.image(for: key(1), background: true) != nil)
        #expect(await cache.image(for: key(2), background: true) == nil)
        #expect(await cache.usage().memoryBytes <= 8 * 1024 * 1024)
    }

    @Test func foregroundInsertPromotesAnExistingBackgroundResident() async throws {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences(); settings.memoryMiB = 8; settings.diskMiB = 0
        await cache.configure(settings)
        let large = try image(width: 1024, height: 1024)
        await cache.insert(large, for: key(1), background: true)
        await cache.insert(large, for: key(2), background: false)
        await cache.insert(large, for: key(1), background: false)
        await cache.insert(large, for: key(3), background: true)
        #expect(await cache.image(for: key(1), background: true) === large)
        #expect(await cache.image(for: key(3), background: true) == nil)
    }

    @Test func foregroundPromotionSurvivesWriterPressureAndInFlightEncoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try image()
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let jpeg = data as Data
        let gate = EncodingGate()
        let cache = NativeThumbnailCache(directory: directory, encode: { _ in
            await gate.wait()
            return jpeg
        })
        for time in 1...2 {
            await cache.insert(image, for: key(time), background: true)
            await cache.flushPendingWrites()
        }
        await gate.block()
        await cache.insert(image, for: key(3), background: true)
        for _ in 0..<100 where !(await gate.hasStarted) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.hasStarted)
        // Multiple promotions while an encode owns the writer must all survive,
        // including the image whose background encoding is still in flight.
        for time in 1...3 { #expect(await cache.image(for: key(time), background: false) === image) }
        await gate.resume()
        await cache.flushPendingWrites()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.hasPrefix("f-") })
    }

    @Test func diskRoundTripStableIdentityAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NativeThumbnailCache(directory: directory)
        let image = try image()
        await cache.insert(image, for: key(1), background: true)
        await cache.flushPendingWrites()
        let reopened = NativeThumbnailCache(directory: directory)
        let decoded = try #require(await reopened.image(for: key(1), background: false))
        #expect(decoded.width == image.width && decoded.height == image.height)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).first?.hasPrefix("f-") == true)
        let changed = NativeThumbnailCache.Key(path: key(1).path, version: "2", halfSecond: 1, width: 2048, height: 2048)
        #expect(await reopened.image(for: changed, background: false) == nil)
        await reopened.clear()
        #expect(await reopened.usage().memoryBytes == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func fileReplacementChangesKeyAndCorruptDiskEntryIsDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("media.mkv")
        try Data([1]).write(to: file)
        let first = try #require(NativeThumbnailCache.key(url: file, time: 1, size: CGSize(width: 100, height: 100)))
        try Data([1, 2]).write(to: file)
        let replacement = try #require(NativeThumbnailCache.key(url: file, time: 1, size: CGSize(width: 100, height: 100)))
        #expect(first != replacement)
        let corrupt = root.appendingPathComponent("f-\(replacement.digest).jpg")
        try Data([1]).write(to: corrupt)
        let cache = NativeThumbnailCache(directory: root)
        #expect(await cache.image(for: replacement, background: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func sourceSwitchReusesGlobalImages() async throws {
        guard let root = ProcessInfo.processInfo.environment["ILLIQUID_NATIVE_FIXTURE_DIR"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent("h264-aac.mp4")
        let generator = NativeTimelineThumbnailGenerator()
        let image = try #require(await generator.thumbnail(for: url, at: 1,
            maximumPixelSize: CGSize(width: 320, height: 180), sourceRevision: 1))
        await generator.invalidate(for: 2)
        let reused = await generator.thumbnail(for: url, at: 1,
            maximumPixelSize: CGSize(width: 320, height: 180), sourceRevision: 3)
        #expect(reused === image)
    }

    @Test func nearbyLookupNeverCrossesFileVersionOrRequestedSize() async throws {
        let cache = NativeThumbnailCache()
        let image = try image()
        await cache.insert(image, for: key(20), background: true)
        let near = await cache.nearest(to: key(24), maximumDistance: 3)
        #expect(near?.0 === image && near?.1 == 10)
        #expect(await cache.nearest(to: key(40), maximumDistance: 3) == nil)
        let replaced = NativeThumbnailCache.Key(path: key(24).path, version: "2", halfSecond: 24, width: 2048, height: 2048)
        #expect(await cache.nearest(to: replaced, maximumDistance: 3) == nil)
    }

    @Test func settingDiskBudgetToZeroRemovesPreviouslyPersistedEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NativeThumbnailCache(directory: directory)
        await writer.insert(try image(), for: key(1), background: false)
        await writer.flushPendingWrites()
        let reader = NativeThumbnailCache(directory: directory)
        var settings = ThumbnailPreferences(); settings.diskMiB = 0
        await reader.configure(settings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func decoderReleaseIsSerializedAfterNativeOwnershipEnds() async throws {
        let started = DispatchSemaphore(value: 0)
        let nativeReturn = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let worker = TimelineThumbnailWorker(release: { released.signal() }) { _, _ in
            started.signal()
            _ = nativeReturn.wait(timeout: .now() + 3)
            return nil
        }
        let request = Task { await worker.image(for: .init(url: URL(fileURLWithPath: "/unused.mkv"),
            seconds: 0, size: CGSize(width: 100, height: 100))) }
        #expect(await Task.detached { Self.wait(started, seconds: 2) }.value)
        worker.cancelAll(releasingResources: true)
        #expect(await request.value == nil)
        #expect(!Self.wait(released, seconds: 0))
        nativeReturn.signal()
        #expect(await Task.detached { Self.wait(released, seconds: 2) }.value)
        // An already idle context is released too, without another decode.
        worker.cancelAll(releasingResources: true)
        #expect(await Task.detached { Self.wait(released, seconds: 2) }.value)
    }

    @Test func idleCleanupDoesNotCancelANewerDecode() async throws {
        let started = DispatchSemaphore(value: 0), nativeReturn = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        defer { nativeReturn.signal() }
        let expected = try image()
        let worker = TimelineThumbnailWorker(requestTimeout: 3, release: { released.signal() }) { _, _ in
            started.signal()
            _ = nativeReturn.wait(timeout: .now() + 2)
            return expected
        }
        let request = Task { await worker.image(for: .init(url: URL(fileURLWithPath: "/unused.mkv"),
            seconds: 0, size: CGSize(width: 100, height: 100))) }
        #expect(await Task.detached { Self.wait(started, seconds: 1) }.value)
        worker.releaseResourcesWhenIdle()
        #expect(!Self.wait(released, seconds: 0))
        nativeReturn.signal()
        #expect(await request.value === expected)
        #expect(await Task.detached { Self.wait(released, seconds: 1) }.value)
    }

    @Test func clearCannotBeUndoneByQueuedPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NativeThumbnailCache(directory: directory)
        let image = try image(width: 640, height: 360)
        for time in 0..<20 { await cache.insert(image, for: key(time), background: false) }
        #expect(await cache.clear())
        await cache.flushPendingWrites()
        #expect(await cache.usage().diskBytes == 0)
        #expect(await cache.usage().memoryBytes == 0)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.isEmpty)
    }

    @Test func symlinkVersionTracksTheTargetRatherThanTheLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.mkv"), link = root.appendingPathComponent("link.mkv")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let first = try #require(NativeThumbnailCache.key(url: link, time: 0, size: CGSize(width: 100, height: 100)))
        try Data([1, 2]).write(to: target)
        let second = try #require(NativeThumbnailCache.key(url: link, time: 0, size: CGSize(width: 100, height: 100)))
        #expect(first != second)
    }

    @Test func stalledMetadataHasBoundedCallersAndOnePhysicalOwner() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = ThumbnailBlockingReader<Int>(timeout: 0.05)
        let first = Task { await reader.read {
            started.signal()
            _ = Self.wait(release, seconds: 3)
            return 1
        } }
        #expect(await Task.detached { Self.wait(started, seconds: 2) }.value)
        #expect(await first.value == nil)
        // Expiration did not make an occupied native slot available again.
        for _ in 0..<20 { #expect(await reader.read { 2 } == nil) }
        release.signal()
        var recovered: Int?
        for _ in 0..<100 where recovered == nil {
            try await Task.sleep(for: .milliseconds(5))
            recovered = await reader.read { 3 }
        }
        #expect(recovered == 3)
    }
}
