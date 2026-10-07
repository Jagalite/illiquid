import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Thumbnail cache measurements", .serialized)
struct ThumbnailCacheQualificationTests {
    @Test func measureNativeCacheTiers() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_CACHE_FIXTURE"],
              let output = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_CACHE_RECEIPT"] else { return }
        let keptDirectory = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_CACHE_DIRECTORY"]
        let directory = keptDirectory.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-measure-\(UUID())")
        defer { if keptDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        let requiresDisk = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_CACHE_REQUIRE_DISK_HIT"] == "1"
        let url = URL(fileURLWithPath: fixture)
        let size = CGSize(width: 368, height: 208)
        let usesDisk = ProcessInfo.processInfo.environment["ILLIQUID_THUMBNAIL_CACHE_DISABLE_DISK"] != "1"
        let generator = NativeTimelineThumbnailGenerator(cacheDirectory: usesDisk ? directory : nil)
        var records: [[String: Any]] = []
        func measure(_ label: String, _ operation: () async -> CGImage?) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            let image = try #require(await operation())
            records.append(["stage": label, "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                            "width": image.width, "height": image.height])
        }
        try await measure(requiresDisk ? "cold-process-disk-hit" : usesDisk ? "decode-and-enqueue-persistence" : "decode-disk-disabled") {
            await generator.thumbnail(for: url, at: 1.5, maximumPixelSize: size, sourceRevision: 1, allowDecoding: !requiresDisk)
        }
        for _ in 0..<20 {
            try await measure("memory-hit") { await generator.thumbnail(for: url, at: 1.5, maximumPixelSize: size, sourceRevision: 1) }
        }
        await generator.invalidate(for: 2)
        try await measure("return-to-file") {
            await generator.thumbnail(for: url, at: 1.5, maximumPixelSize: size, sourceRevision: 3)
        }
        await generator.flushPendingCacheWrites()
        if usesDisk {
        let reopened = NativeTimelineThumbnailGenerator(cacheDirectory: directory)
        try await measure("new-generator-disk-hit") {
            await reopened.thumbnail(for: url, at: 1.5, maximumPixelSize: size, allowDecoding: false)
        }
        // A disk hit must not need a native decoder, and nearest output reports
        // its represented timestamp rather than relabeling the image as exact.
        let near = try #require(await reopened.cachedThumbnail(for: url, at: 3, size: size,
            maximumDistance: 3, sourceRevision: 1))
        #expect(near.position == 1.5)
        try await measure("background-decode") {
            await reopened.thumbnail(for: url, at: 2.5, maximumPixelSize: size, background: true)
        }
        await reopened.flushPendingCacheWrites()
        try await measure("foreground-promotion") {
            await reopened.thumbnail(for: url, at: 2.5, maximumPixelSize: size, sourceRevision: 1)
        }
        await reopened.releaseIdleResources()
        }
        let data = try JSONSerialization.data(withJSONObject: ["fixture": fixture, "records": records], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
        await generator.releaseIdleResources()
    }
}
