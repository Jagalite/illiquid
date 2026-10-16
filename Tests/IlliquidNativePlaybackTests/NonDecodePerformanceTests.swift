import CoreGraphics
import CryptoKit
import Foundation
import IlliquidCore
import Testing
@testable import IlliquidNativePlayback

/// Real-framework qualification for the portable experiment's changes.
/// Run this suite on macOS; Linux platform-double tests do not replace it.
@Suite("Non-decoding performance regressions")
struct NonDecodePerformanceTests {
    @Test func hexadecimalIsByteIdenticalToLegacyFormatting() {
        for count in [0, 1, 2, 31, 32, 33, 64, 256, 1024] {
            let bytes = (0..<count).map { UInt8(($0 * 137 + count) % 256) }
            #expect(NativeThumbnailCache.Key.hexadecimal(bytes)
                == bytes.map { String(format: "%02x", $0) }.joined())
        }
        for value in UInt8.min...UInt8.max {
            #expect(NativeThumbnailCache.Key.hexadecimal([value]) == String(format: "%02x", value))
        }
    }

    @Test func completeDiskKeyMatchesLegacyJSONAndCryptoKitDigest() throws {
        for path in ["/movie.mkv", "/字幕/épisode 01.mkv", "/a%25/movie.mkv"] {
            for bucket in [0, 1, 721, 86400] {
                let key = NativeThumbnailCache.Key(path: path, version: "identity:version:1",
                    halfSecond: bucket, width: 320, height: 180)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let data = try encoder.encode(key)
                let legacy = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                #expect(key.digest == legacy)
            }
        }
    }

    @Test func invalidAdmissionDimensionsDoNotTrap() async {
        let cache = NativeThumbnailCache()
        let invalid: [CGSize] = [
            .init(width: CGFloat.nan, height: 180),
            .init(width: CGFloat.infinity, height: 180),
            .init(width: 320, height: CGFloat.infinity),
            .init(width: -1, height: 180),
            .init(width: 0, height: 180),
            .init(width: 2049, height: 180),
        ]
        for size in invalid { #expect(!(await cache.admitsBackground(size: size))) }
        #expect(await cache.admitsBackground(size: CGSize(width: 320, height: 180)))
    }

    @Test func criticalPressureClearsResidentsWithoutInvalidatingExternalImage() async throws {
        let cache = NativeThumbnailCache()
        var preferences = ThumbnailPreferences()
        preferences.diskMiB = 0
        await cache.configure(preferences)
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let key = NativeThumbnailCache.Key(path: "/movie.mkv", version: "v1", halfSecond: 0, width: 16, height: 16)
        await cache.insert(image, for: key, background: true, storyboard: true)
        #expect(await cache.usage().images == 1)
        await cache.trimForMemoryPressure(critical: true)
        #expect(await cache.usage().images == 0)
        #expect(await cache.usage().memoryBytes == 0)
        #expect(await cache.image(for: key, background: true) == nil)
        #expect(image.width == 16 && image.height == 16)
        await cache.insert(image, for: key, background: false)
        #expect(await cache.image(for: key, background: false) === image)
    }
}
