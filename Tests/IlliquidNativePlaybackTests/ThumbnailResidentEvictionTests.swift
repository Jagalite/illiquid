import CoreGraphics
import Foundation
import Testing
import IlliquidCore
@testable import IlliquidNativePlayback

@Suite("Thumbnail resident eviction")
struct ThumbnailResidentEvictionTests {
    private let mebibyte = 1_024 * 1_024

    @Test func foregroundEvictionPreservesProtectionAndPriorityHierarchy() async throws {
        let cache = await makeCache(memoryMiB: 16)
        let value = try image(width: 1024, height: 1024)
        let keys = (0..<6).map { key($0, image: value) }

        // Priority must beat recency: protected foreground is oldest, while
        // unprotected background is newest.
        await cache.insert(value, for: keys[0], background: false, storyboard: true)
        await cache.insert(value, for: keys[1], background: true, storyboard: true)
        await cache.insert(value, for: keys[2], background: false)
        await cache.insert(value, for: keys[3], background: true)

        var settings = ThumbnailPreferences()
        settings.memoryMiB = 8
        settings.diskMiB = 0
        await cache.configure(settings)

        #expect(await cache.image(for: keys[0], background: true) === value)
        #expect(await cache.image(for: keys[1], background: true) === value)
        #expect(await cache.image(for: keys[2], background: true) == nil)
        #expect(await cache.image(for: keys[3], background: true) == nil)

        // Within the protected group, background loses before foreground,
        // even though the foreground resident is older.
        await cache.insert(value, for: keys[4], background: false)
        #expect(await cache.image(for: keys[0], background: true) === value)
        #expect(await cache.image(for: keys[1], background: true) == nil)
        #expect(await cache.image(for: keys[4], background: true) === value)

        // A newer unprotected foreground resident still loses to an older
        // protected foreground resident.
        await cache.insert(value, for: keys[5], background: false)
        #expect(await cache.image(for: keys[0], background: true) === value)
        #expect(await cache.image(for: keys[4], background: true) == nil)
        #expect(await cache.image(for: keys[5], background: true) === value)

        let usage = await cache.usage()
        #expect(usage.images == 2)
        #expect(usage.memoryBytes == 8 * mebibyte)
        #expect(usage.diskBytes == 0)
    }

    @Test func foregroundHitRefreshesLRUButBackgroundReadDoesNot() async throws {
        let cache = await makeCache()
        let value = try image(width: 16, height: 16)
        let keys = (0..<98).map { key($0, image: value) }
        for index in 0..<96 {
            await cache.insert(value, for: keys[index], background: false)
        }

        // Reconfiguration has no incoming entry: reaching the count cap alone
        // must not evict an otherwise in-budget resident.
        var settings = ThumbnailPreferences()
        settings.memoryMiB = 8
        settings.diskMiB = 0
        await cache.configure(settings)
        #expect(await cache.usage().images == 96)

        #expect(await cache.image(for: keys[0], background: false) === value)
        #expect(await cache.image(for: keys[1], background: true) === value)
        await cache.insert(value, for: keys[96], background: false)
        await cache.insert(value, for: keys[97], background: false)

        for index in keys.indices {
            let resident = await cache.image(for: keys[index], background: true)
            #expect((resident != nil) == (index != 1 && index != 2))
        }
        let usage = await cache.usage()
        #expect(usage.images == 96)
        #expect(usage.memoryBytes == 96 * value.bytesPerRow * value.height)
    }

    @Test func varyingImageSizesEvictOnlyTheRequiredLRUPrefix() async throws {
        let cache = await makeCache()
        let small = try image(width: 512, height: 512)       // 1 MiB
        let medium = try image(width: 1024, height: 512)     // 2 MiB
        let large = try image(width: 1024, height: 1024)     // 4 MiB
        let incoming = try image(width: 768, height: 1024)   // 3 MiB
        let first = key(0, image: small)
        let second = key(1, image: medium)
        let third = key(2, image: small)
        let fourth = key(3, image: large)
        let fifth = key(4, image: incoming)

        await cache.insert(small, for: first, background: false)
        await cache.insert(medium, for: second, background: false)
        await cache.insert(small, for: third, background: false)
        await cache.insert(large, for: fourth, background: false)
        #expect(await cache.usage().memoryBytes == 8 * mebibyte)

        // Exactly the oldest 1 MiB and 2 MiB entries are needed.
        await cache.insert(incoming, for: fifth, background: false)
        #expect(await cache.image(for: first, background: true) == nil)
        #expect(await cache.image(for: second, background: true) == nil)
        #expect(await cache.image(for: third, background: true) === small)
        #expect(await cache.image(for: fourth, background: true) === large)
        #expect(await cache.image(for: fifth, background: true) === incoming)

        let usage = await cache.usage()
        #expect(usage.images == 3)
        #expect(usage.memoryBytes == 8 * mebibyte)
    }

    @Test func insufficientBackgroundReclamationPreservesProtectedAndForegroundImages() async throws {
        let cache = await makeCache()
        let medium = try image(width: 1024, height: 512)
        let large = try image(width: 1024, height: 1024)
        let protected = key(0, image: medium)
        let foreground = key(1, image: large)
        let speculative = key(2, image: medium)
        let incoming = key(3, image: large)

        await cache.insert(medium, for: protected, background: true, storyboard: true)
        await cache.insert(large, for: foreground, background: false)
        await cache.insert(medium, for: speculative, background: true)

        // Reclaim the eligible 2 MiB, then reject the 4 MiB insertion without
        // touching the storyboard or foreground resident.
        await cache.insert(large, for: incoming, background: true)
        #expect(await cache.image(for: protected, background: true) === medium)
        #expect(await cache.image(for: foreground, background: true) === large)
        #expect(await cache.image(for: speculative, background: true) == nil)
        #expect(await cache.image(for: incoming, background: true) == nil)

        let usage = await cache.usage()
        #expect(usage.images == 2)
        #expect(usage.memoryBytes == 6 * mebibyte)
    }

    @Test func backgroundEntryPressureCannotEvictMixedProtectedAndForegroundResidents() async throws {
        let cache = await makeCache()
        let value = try image(width: 16, height: 16)
        let keys = (0..<97).map { key($0, image: value) }
        for index in 0..<96 {
            let storyboard = index.isMultiple(of: 2)
            await cache.insert(value, for: keys[index],
                               background: storyboard, storyboard: storyboard)
        }

        // Ample byte capacity, but no eligible victim for the entry cap.
        await cache.insert(value, for: keys[96], background: true)
        for index in 0..<96 {
            #expect(await cache.image(for: keys[index], background: true) === value)
        }
        #expect(await cache.image(for: keys[96], background: true) == nil)

        let usage = await cache.usage()
        #expect(usage.images == 96)
        #expect(usage.memoryBytes == 96 * value.bytesPerRow * value.height)
    }

    @Test(arguments: [false, true])
    func oversizedInsertionStillEvictsAllEligibleResidents(background: Bool) async throws {
        let cache = await makeCache()
        let resident = try image(width: 1024, height: 512)
        let oversized = try image(width: 2048, height: 2048)
        let protected = key(0, image: resident)
        let foreground = key(1, image: resident)
        let speculative = key(2, image: resident)
        let incoming = key(3, image: oversized)

        await cache.insert(resident, for: protected, background: true, storyboard: true)
        await cache.insert(resident, for: foreground, background: false)
        await cache.insert(resident, for: speculative, background: true)

        // Preserve the existing trim-before-admission contract even though a
        // 16 MiB image cannot fit the 8 MiB budget.
        await cache.insert(oversized, for: incoming, background: background)

        let protectedRemains = await cache.image(for: protected, background: true) != nil
        let foregroundRemains = await cache.image(for: foreground, background: true) != nil
        #expect(protectedRemains == background)
        #expect(foregroundRemains == background)
        #expect(await cache.image(for: speculative, background: true) == nil)
        #expect(await cache.image(for: incoming, background: true) == nil)

        let usage = await cache.usage()
        #expect(usage.images == (background ? 2 : 0))
        #expect(usage.memoryBytes == (background ? 4 * mebibyte : 0))
    }

    private func makeCache(memoryMiB: Int = 8) async -> NativeThumbnailCache {
        let cache = NativeThumbnailCache()
        var settings = ThumbnailPreferences()
        settings.memoryMiB = memoryMiB
        settings.diskMiB = 0
        await cache.configure(settings)
        return cache
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let value = try #require(context.makeImage())
        #expect(value.bytesPerRow == width * 4)
        return value
    }

    private func key(_ index: Int, image: CGImage) -> NativeThumbnailCache.Key {
        .init(path: "/synthetic/resident-eviction/video.mkv", version: "1",
              halfSecond: index, width: image.width, height: image.height)
    }
}
