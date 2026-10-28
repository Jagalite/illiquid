import CoreGraphics
import Foundation
import IlliquidCore
@testable import IlliquidNativePlayback

private enum Workload: String, CaseIterable, Sendable {
    case foregroundDefault = "foreground-16mib-storyboard"
    case backgroundDefault = "background-16mib-storyboard"
    case foregroundCapacity = "foreground-64mib"
    case backgroundCapacity = "background-64mib"
    case foregroundProtected = "foreground-64mib-storyboard"
    case backgroundProtected = "background-64mib-storyboard"
    case residentHit = "resident-hit-control"
    case existingInsert = "existing-insert-control"
    case shrink = "shrink-64-to-8mib"

    var background: Bool {
        self == .backgroundDefault || self == .backgroundCapacity || self == .backgroundProtected
    }
    var protectedCount: Int {
        switch self {
        case .foregroundDefault, .backgroundDefault, .foregroundProtected, .backgroundProtected, .shrink: 24
        default: 0
        }
    }
    var memoryMiB: Int {
        self == .foregroundDefault || self == .backgroundDefault ? 16 : 64
    }
    var isControl: Bool { self == .residentHit || self == .existingInsert }
}

private struct Snapshot: Codable, Equatable, Sendable {
    let present: [Int]
    let memoryBytes: Int
    let images: Int
}

private struct Trace: Codable, Sendable {
    let seed: UInt64
    let states: [Snapshot]
}

private struct Verification: Codable, Sendable {
    let traces: [Trace]
    let snapshots: Int
}

private struct Measurement: Codable, Sendable {
    let workload: String
    let iterations: Int
    let operations: Int
    let warmupIterations: Int
    let elapsedNS: UInt64
    let checksum: UInt64
    let finalState: Snapshot
}

private struct RNG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(bound))
    }
}

private enum HarnessError: Error { case arguments, imageAllocation, missingResident }

@main
private struct Driver {
    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func makeImage(width: Int = 368, height: Int = 208) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw HarnessError.imageAllocation }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw HarnessError.imageAllocation }
        return image
    }

    static func key(_ index: Int, source: Int = 0, width: Int = 368, height: Int = 208) -> NativeThumbnailCache.Key {
        .init(
            path: "/benchmark/Media Library/Season 01/Example Video \(source).mkv",
            version: "file-identity:104857600:2026.123456789:2025.987654321",
            halfSecond: index, width: width, height: height
        )
    }

    static func settings(_ memoryMiB: Int) -> ThumbnailPreferences {
        var result = ThumbnailPreferences()
        result.memoryMiB = memoryMiB
        result.diskMiB = 0
        return result
    }

    static func snapshot(
        _ cache: NativeThumbnailCache, keys: [NativeThumbnailCache.Key], indices: [Int]
    ) async -> Snapshot {
        var present: [Int] = []
        for index in indices {
            // Background reads do not promote residents or alter their recency.
            if await cache.image(for: keys[index], background: true) != nil {
                present.append(index)
            }
        }
        let usage = await cache.usage()
        precondition(present.count == usage.images, "Survivor probes must account for every resident")
        precondition(usage.diskBytes == 0, "Timing and differential fixtures must not use disk caching")
        return Snapshot(present: present, memoryBytes: usage.memoryBytes, images: usage.images)
    }

    static func prepare(
        _ workload: Workload, images: [CGImage], keys: [NativeThumbnailCache.Key]
    ) async -> NativeThumbnailCache {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(workload.memoryMiB))
        for index in 0..<(workload.isControl ? 24 : 96) {
            let protected = index < workload.protectedCount
            // Keep eight foreground residents during default-budget background
            // churn, as occurs when speculative work shares the hover cache.
            let foregroundAnchor = workload == .backgroundDefault && (24..<32).contains(index)
            await cache.insert(images[index % images.count], for: keys[index],
                               background: (workload.background && !foregroundAnchor) || protected || workload.isControl,
                               storyboard: protected)
        }
        return cache
    }

    static func measure(_ workload: Workload, iterations: Int) async throws -> Measurement {
        let images = try (0..<96).map { _ in try makeImage() }
        let warmup = workload == .shrink ? 2 : 64
        let count = workload == .shrink || workload.isControl ? 96 : 96 + warmup + iterations
        let keys = (0..<count).map { key($0) }
        if workload == .shrink {
            var elapsed: UInt64 = 0
            var checksum: UInt64 = 0
            var finalState = Snapshot(present: [], memoryBytes: 0, images: 0)
            for iteration in 0..<(warmup + iterations) {
                let cache = await prepare(workload, images: images, keys: keys)
                let bounded = settings(8)
                let start = DispatchTime.now().uptimeNanoseconds
                await cache.configure(bounded)
                let duration = DispatchTime.now().uptimeNanoseconds - start
                let usage = await cache.usage()
                if iteration >= warmup {
                    elapsed += duration
                    checksum &+= UInt64(usage.memoryBytes + usage.images)
                }
                if iteration == warmup + iterations - 1 {
                    finalState = await snapshot(cache, keys: keys, indices: Array(keys.indices))
                }
            }
            return Measurement(workload: workload.rawValue, iterations: iterations,
                               operations: iterations, warmupIterations: warmup,
                               elapsedNS: elapsed, checksum: checksum, finalState: finalState)
        }

        let cache = await prepare(workload, images: images, keys: keys)
        var checksum: UInt64 = 0
        for iteration in 0..<warmup {
            if workload == .residentHit {
                guard await cache.image(for: keys[iteration % 24], background: false) != nil
                else { throw HarnessError.missingResident }
            } else {
                let index = workload.isControl ? iteration % 24 : 96 + iteration
                await cache.insert(images[index % images.count], for: keys[index], background: workload.background)
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<iterations {
            if workload == .residentHit {
                guard let hit = await cache.image(for: keys[iteration % 24], background: false)
                else { throw HarnessError.missingResident }
                checksum &+= UInt64(hit.width)
            } else {
                let index = workload.isControl ? iteration % 24 : 96 + warmup + iteration
                await cache.insert(images[index % images.count], for: keys[index], background: workload.background)
                checksum &+= UInt64(index)
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let indices = Array(Set(Array(0..<96) + Array(max(96, count - 128)..<count))).sorted()
        let finalState = await snapshot(cache, keys: keys, indices: indices)
        return Measurement(workload: workload.rawValue, iterations: iterations,
                           operations: iterations, warmupIterations: warmup,
                           elapsedNS: elapsed, checksum: checksum, finalState: finalState)
    }

    static func verify() async throws -> Verification {
        let images = try [
            makeImage(), makeImage(width: 512, height: 512),
            makeImage(width: 1024, height: 1024), makeImage(width: 1536, height: 1536)
        ]
        let keys = (0..<128).map { key($0, source: $0 / 64, width: 2048, height: 2048) }
        var traces: [Trace] = []
        for seed in [UInt64(1), 7, 42, 20261028] {
            var random = RNG(state: seed)
            let cache = NativeThumbnailCache()
            await cache.configure(settings(64))
            // Reach the real entry cap before exercising mixed ownership.
            for index in 0..<96 {
                await cache.insert(images[0], for: keys[index], background: index % 3 != 0,
                                   storyboard: index % 4 == 0)
            }
            var states: [Snapshot] = [
                await snapshot(cache, keys: keys, indices: Array(keys.indices))
            ]
            for _ in 0..<128 {
                let index = random.next(keys.count)
                switch random.next(10) {
                case 0:
                    await cache.configure(settings([8, 16, 64][random.next(3)]))
                case 1:
                    _ = await cache.image(for: keys[index], background: false)
                case 2:
                    await cache.selectStoryboardSource(keys[index])
                case 3:
                    await cache.protectStoryboard(keys[index])
                default:
                    await cache.insert(images[random.next(images.count)], for: keys[index],
                                       background: random.next(2) == 0,
                                       storyboard: random.next(4) == 0)
                }
                states.append(await snapshot(cache, keys: keys, indices: Array(keys.indices)))
            }
            traces.append(Trace(seed: seed, states: states))
        }
        return Verification(traces: traces, snapshots: traces.reduce(0) { $0 + $1.states.count })
    }

    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw HarnessError.arguments }
        switch command {
        case "list":
            try emit(["workloads": Workload.allCases.map(\.rawValue)])
        case "verify":
            try emit(await verify())
        case "measure":
            guard arguments.count == 3, let workload = Workload(rawValue: arguments[1]),
                  let iterations = Int(arguments[2]), iterations > 0
            else { throw HarnessError.arguments }
            try emit(await measure(workload, iterations: iterations))
        default:
            throw HarnessError.arguments
        }
    }
}
