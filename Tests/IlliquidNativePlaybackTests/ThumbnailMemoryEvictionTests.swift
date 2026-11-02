import CoreGraphics
import Foundation
import Testing
import IlliquidCore
@testable import IlliquidNativePlayback

@Suite("Thumbnail memory eviction")
struct ThumbnailMemoryEvictionTests {
    private typealias Key = NativeThumbnailCache.Key
    private let mebibyte = 1024 * 1024

    @Test func countLimitEvictionHonorsProtectionBeforeBackgroundPriority() async throws {
        let cache = await configuredCache()
        let image = try makeImage(width: 16, height: 16)
        let keys = (0..<98).map { key($0, image: image) }

        // The oldest entry is protected background work. The newest resident
        // is unprotected background work; both precede foreground work only
        // within their own protection tier.
        await cache.insert(image, for: keys[0], background: true, storyboard: true)
        for index in 1..<95 {
            await cache.insert(image, for: keys[index], background: false)
        }
        await cache.insert(image, for: keys[95], background: true)
        await cache.insert(image, for: keys[96], background: false)
        await expectResidents(cache, candidates: Array(keys.prefix(97)),
            expected: Set(keys.prefix(95)).union([keys[96]]),
            bytes: 96 * image.bytesPerRow * image.height)

        // Once unprotected background work is gone, the oldest unprotected
        // foreground entry must go before the protected background entry.
        await cache.insert(image, for: keys[97], background: false)
        await expectResidents(cache, candidates: keys,
            expected: Set(keys).subtracting([keys[1], keys[95]]),
            bytes: 96 * image.bytesPerRow * image.height)
    }

    @Test func backgroundCountEvictionRejectsWhenOnlyProtectedOrForegroundEntriesRemain() async throws {
        let cache = await configuredCache()
        let image = try makeImage(width: 16, height: 16)
        let keys = (0..<98).map { key($0, image: image) }
        await cache.insert(image, for: keys[0], background: false)
        await cache.insert(image, for: keys[1], background: true, storyboard: true)
        await cache.insert(image, for: keys[2], background: true)
        for index in 3..<96 {
            await cache.insert(image, for: keys[index], background: false)
        }

        await cache.insert(image, for: keys[96], background: true)
        let expected = Set(keys.prefix(97)).subtracting([keys[2]])
        await expectResidents(cache, candidates: Array(keys.prefix(97)), expected: expected,
            bytes: 96 * image.bytesPerRow * image.height)

        // Promote the only eligible victim. A subsequent speculative insertion
        // must preserve the complete resident set rather than evict a protected
        // entry or the oldest foreground entry to satisfy the count limit.
        #expect(await cache.image(for: keys[96], background: false) === image)
        #expect(!(await cache.admitsBackground(size: CGSize(width: 16, height: 16))))
        await cache.insert(image, for: keys[97], background: true)
        await expectResidents(cache, candidates: keys, expected: expected,
            bytes: 96 * image.bytesPerRow * image.height)
    }

    @Test func foregroundHitsRefreshLRUButBackgroundHitsDoNot() async throws {
        let cache = await configuredCache(memoryMiB: 8)
        let image = try makeImage()
        try #require(image.bytesPerRow * image.height == mebibyte)
        let keys = (0..<10).map { key($0, image: image) }
        for index in 0..<8 {
            await cache.insert(image, for: keys[index], background: false)
        }

        #expect(await cache.image(for: keys[0], background: false) === image)
        #expect(await cache.image(for: keys[1], background: true) === image)
        await cache.insert(image, for: keys[8], background: false)
        await expectResidents(cache, candidates: Array(keys.prefix(9)),
            expected: Set(keys.prefix(9)).subtracting([keys[1]]), bytes: 8 * mebibyte)

        // The nonpromoting residency checks above must not perturb LRU order.
        await cache.insert(image, for: keys[9], background: false)
        await expectResidents(cache, candidates: keys,
            expected: Set(keys).subtracting([keys[1], keys[2]]), bytes: 8 * mebibyte)
    }

    @Test func byteBudgetInsertionEvictsTheMinimalOrderedPrefix() async throws {
        let cache = await configuredCache(memoryMiB: 8)
        let small = try makeImage()
        let large = try makeImage(width: 1024, height: 1024)
        try #require(small.bytesPerRow * small.height == mebibyte)
        try #require(large.bytesPerRow * large.height == 4 * mebibyte)
        let keys = (0..<8).map { key($0, image: small) }
        let incoming = key(8, image: large)
        for index in 0..<8 {
            await cache.insert(small, for: keys[index],
                background: [0, 2, 5].contains(index), storyboard: [0, 4].contains(index))
        }

        // One victim cannot make room. Remove background 2 and 5, then
        // foreground 1 and 3; keep both protected entries and newer foreground
        // entries. A fifth eviction would unnecessarily discard useful work.
        await cache.insert(large, for: incoming, background: false)
        await expectResidents(cache, candidates: keys + [incoming],
            expected: [keys[0], keys[4], keys[6], keys[7], incoming], bytes: 8 * mebibyte)
        #expect(await cache.image(for: incoming, background: true) === large)
    }

    @Test func budgetReductionOrdersAllFourProtectionAndBackgroundTiers() async throws {
        let cache = await configuredCache(memoryMiB: 16)
        let image = try makeImage()
        try #require(image.bytesPerRow * image.height == mebibyte)
        let keys = (0..<12).map { key($0, image: image) }
        for index in 0..<12 {
            await cache.insert(image, for: keys[index],
                background: [1, 3, 10, 11].contains(index), storyboard: index < 9)
        }

        var preferences = ThumbnailPreferences()
        preferences.memoryMiB = 8
        preferences.diskMiB = 0
        await cache.configure(preferences)

        // Remove unprotected background 10/11, unprotected foreground 9, then
        // protected background 1. Protected foreground 0 is older than all of
        // them but belongs to the final eviction tier.
        await expectResidents(cache, candidates: keys,
            expected: Set(keys).subtracting([keys[1], keys[9], keys[10], keys[11]]),
            bytes: 8 * mebibyte)
    }

    @Test(arguments: [false, true])
    func oversizedInsertionReclaimsOnlyEligibleResidents(background: Bool) async throws {
        let cache = await configuredCache(memoryMiB: 8)
        let small = try makeImage()
        let oversized = try makeImage(width: 2048, height: 2048)
        try #require(small.bytesPerRow * small.height == mebibyte)
        try #require(oversized.bytesPerRow * oversized.height == 16 * mebibyte)
        let keys = (0..<3).map { key($0, image: small) }
        let incoming = key(3, image: oversized)
        await cache.insert(small, for: keys[0], background: true)
        await cache.insert(small, for: keys[1], background: false)
        await cache.insert(small, for: keys[2], background: true, storyboard: true)

        // Even an unadmittable insertion reclaims eligible entries. Preserve
        // that existing behavior without evicting foreground/storyboard work
        // for a background request.
        await cache.insert(oversized, for: incoming, background: background)
        let expected: Set<Key> = background ? [keys[1], keys[2]] : []
        await expectResidents(cache, candidates: keys + [incoming], expected: expected,
            bytes: expected.count * mebibyte)
    }

    private func configuredCache(memoryMiB: Int = 16) async -> NativeThumbnailCache {
        let cache = NativeThumbnailCache()
        var preferences = ThumbnailPreferences()
        preferences.memoryMiB = memoryMiB
        preferences.diskMiB = 0
        await cache.configure(preferences)
        return cache
    }

    private func makeImage(width: Int = 512, height: Int = 512) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func key(_ halfSecond: Int, image: CGImage) -> Key {
        .init(path: "/synthetic/memory-eviction.mkv", version: "1", halfSecond: halfSecond,
            width: image.width, height: image.height)
    }

    private func expectResidents(_ cache: NativeThumbnailCache, candidates: [Key],
                                 expected: Set<Key>, bytes: Int) async {
        for key in candidates {
            // Background reads inspect residency without refreshing LRU or
            // promoting entries; this cache has no disk backing.
            let present = await cache.image(for: key, background: true) != nil
            #expect(present == expected.contains(key), "Unexpected residency for bucket \(key.halfSecond)")
        }
        let usage = await cache.usage()
        #expect(usage.images == expected.count)
        #expect(usage.memoryBytes == bytes)
        #expect(usage.diskBytes == 0)
    }
}
