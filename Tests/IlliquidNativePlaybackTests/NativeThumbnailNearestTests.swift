import CoreGraphics
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

@Suite("Native thumbnail nearest lookup", .serialized)
struct NativeThumbnailNearestTests {
    @Test func exactMatchWinsAndEqualDistancesPreferEarlierTime() async throws {
        let cache = await memoryCache()
        let earlier = try image(gray: 0.2)
        let later = try image(gray: 0.8)
        await cache.insert(later, for: key(22), background: false)
        await cache.insert(earlier, for: key(18), background: false)

        let tied = try #require(await cache.nearest(to: key(20), maximumDistance: 1))
        #expect(tied.0 === earlier)
        #expect(tied.1 == 9)

        let exact = try image(gray: 0.5)
        await cache.insert(exact, for: key(20), background: false)
        let match = try #require(await cache.nearest(to: key(20), maximumDistance: 0))
        #expect(match.0 === exact)
        #expect(match.1 == 10)
    }

    @Test func distanceBoundaryIsInclusiveForEitherDirection() async throws {
        for bucket in [18, 22] {
            let cache = await memoryCache()
            let expected = try image()
            await cache.insert(expected, for: key(bucket), background: true)
            #expect(await cache.nearest(
                to: key(20), maximumDistance: Double(1).nextDown
            ) == nil)
            let match = try #require(await cache.nearest(
                to: key(20), maximumDistance: 1
            ))
            #expect(match.0 === expected)
            #expect(match.1 == Double(bucket) / 2)
        }
    }

    @Test func sourceVersionAndEachSizeDimensionRemainPartOfIdentity() async throws {
        let cache = await memoryCache()
        let value = try image()
        await cache.insert(value, for: key(20), background: false)
        for query in [
            key(20, path: "/test/other.mkv"),
            key(20, version: "replacement"),
            key(20, width: 17),
            key(20, height: 17),
        ] {
            #expect(await cache.nearest(
                to: query, maximumDistance: 10, fallbackTimes: [10]
            ) == nil)
        }
        #expect(await cache.nearest(
            to: key(20), maximumDistance: 0
        )?.0 === value)
    }

    @Test func invalidDistancesRejectEvenAnExactResidentHit() async throws {
        let cache = await memoryCache()
        await cache.insert(try image(), for: key(20), background: false)
        for distance in [-0.1, Double.infinity, -.infinity, .nan] {
            #expect(await cache.nearest(
                to: key(20), maximumDistance: distance, fallbackTimes: [10]
            ) == nil)
        }
    }

    @Test func missingEarlierFallbackDoesNotHideResidentHit() async throws {
        let cache = await memoryCache()
        let expected = try image()
        await cache.insert(expected, for: key(14), background: true)
        // The missing five-second fallback ties the resident seven-second
        // image and must be attempted first without ending the search.
        let match = try #require(await cache.nearest(
            to: key(12), maximumDistance: 1,
            fallbackTimes: [5, 5.01, 4.99, 5, .nan, .infinity,
                -.infinity, Double.greatestFiniteMagnitude]
        ))
        #expect(match.0 === expected)
        #expect(match.1 == 7)
    }

    @Test func restartFallbackQuantizationAndCorruptFirstCandidate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NativeThumbnailCache(directory: directory)
        let value = try image()
        let corruptKey = key(10)
        let validKey = key(14)
        await writer.insert(value, for: corruptKey, background: true)
        await writer.flushPendingWrites()
        await writer.insert(value, for: validKey, background: true)
        await writer.flushPendingWrites()

        let corruptURL = directory.appendingPathComponent("b-\(corruptKey.digest).jpg")
        try #require(FileManager.default.fileExists(atPath: corruptURL.path))
        try Data([0, 1, 2]).write(to: corruptURL)

        let restarted = NativeThumbnailCache(directory: directory)
        // 4.75 rounds to bucket 10 and 6.75 rounds to bucket 14. Repeated
        // storyboard times must not change the earlier-first search order.
        let match = try #require(await restarted.nearest(
            to: key(12), maximumDistance: 1,
            fallbackTimes: [6.75, 7, 4.75, 5, 5.1, 6.75, .nan, .infinity]
        ))
        #expect(match.1 == 7)
        #expect(match.0.width == value.width)
        #expect(match.0.height == value.height)
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
        #expect(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("f-\(validKey.digest).jpg").path
        ))
    }

    @Test func finiteNegativeFallbackKeepsExistingQuantization() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NativeThumbnailCache(directory: directory)
        await writer.insert(try image(), for: key(-3), background: true)
        await writer.flushPendingWrites()
        let restarted = NativeThumbnailCache(directory: directory)
        // nearest accepts finite fallback times independently of makeKey's
        // public nonnegative-time validation. Preserve rounding away from zero.
        let match = try #require(await restarted.nearest(
            to: key(0), maximumDistance: 1.5, fallbackTimes: [-1.25, -1.5]
        ))
        #expect(match.1 == -1.5)
    }

    @Test func cancelledLookupReturnsNoResidentImage() async throws {
        let cache = await memoryCache()
        let target = key(20)
        await cache.insert(try image(), for: target, background: false)
        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.nearest(
                to: target, maximumDistance: 0, fallbackTimes: [10]
            )
        }
        #expect(await lookup.value == nil)
    }

    @Test func extremeBucketsPreserveDoubleDistanceAndIntegerTieBreak() async throws {
        let cache = await memoryCache()
        let earlier = try image(gray: 0.2)
        let later = try image(gray: 0.8)
        await cache.insert(later, for: key(Int.max), background: false)
        await cache.insert(earlier, for: key(Int.max - 1), background: false)
        // These different integer buckets collapse to the same Double. The
        // existing comparator breaks that distance tie with the integer bucket,
        // even when the query's integer bucket exactly matches the later key.
        #expect(Double(Int.max) == Double(Int.max - 1))
        let tied = try #require(await cache.nearest(
            to: key(Int.max), maximumDistance: 0
        ))
        #expect(tied.0 === earlier)
        #expect(tied.1 == Double(Int.max - 1) / 2)

        // Distance computation must also avoid overflowing signed subtraction.
        let distant = try #require(await cache.nearest(
            to: key(Int.min), maximumDistance: Double.greatestFiniteMagnitude
        ))
        #expect(distant.0 === earlier)
    }

    @Test func canonicalUnicodeEqualityPreservesResidentDiskSpelling() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NativeThumbnailCache(directory: directory)
        let residentKey = key(12, path: "/test/Cafe\u{0301}.mkv")
        let queryKey = key(12, path: "/test/Caf\u{00E9}.mkv")
        // Swift's String equality normalizes these spellings, while JSON-backed
        // disk digests retain their distinct UTF-8 representations.
        #expect(residentKey == queryKey)
        #expect(residentKey.digest != queryKey.digest)
        let value = try image()
        await cache.insert(value, for: residentKey, background: true)
        await cache.flushPendingWrites()
        #expect(FileManager.default.fileExists(atPath:
            directory.appendingPathComponent("b-\(residentKey.digest).jpg").path
        ))

        let match = try #require(await cache.nearest(
            to: queryKey, maximumDistance: 0, fallbackTimes: [6, 6.01, 6]
        ))
        #expect(match.0 === value)
        #expect(match.1 == 6)
        await cache.flushPendingWrites()
        let filenames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(filenames == ["f-\(residentKey.digest).jpg"])
    }

    private func memoryCache() async -> NativeThumbnailCache {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences()
        settings.diskMiB = 0
        await cache.configure(settings)
        return cache
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("illiquid-nearest-\(UUID().uuidString)", isDirectory: true)
    }

    private func image(gray: CGFloat = 0.5) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return try #require(context.makeImage())
    }

    private func key(
        _ bucket: Int, path: String = "/test/video.mkv", version: String = "1",
        width: Int = 16, height: Int = 16
    ) -> NativeThumbnailCache.Key {
        .init(path: path, version: version, halfSecond: bucket, width: width, height: height)
    }
}
