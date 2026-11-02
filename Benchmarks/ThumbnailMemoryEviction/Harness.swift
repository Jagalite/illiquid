import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

private let mib = 1024 * 1024
private typealias Key = NativeThumbnailCache.Key

private func key(_ index: Int, image: CGImage, source: Int = 0) -> Key {
    .init(path: "/synthetic/movie-\(source).mkv", version: "v1", halfSecond: index,
          width: image.width, height: image.height)
}

private func settings(_ memory: Int) -> ThumbnailPreferences {
    var value = ThumbnailPreferences()
    value.memoryMiB = memory
    value.diskMiB = 0
    return value
}

private func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func trace(_ cache: NativeThumbnailCache, scenario: String, step: Int,
                   observed: Int = -1) async {
    emit(["scenario": scenario, "step": step, "observed": observed,
          "receipt": await cache.evictionReceipt()])
}

private struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func verify() async {
    precondition(!NonDecodePerformance.isEnabled)
    let small = makeImage(token: 1)
    let unit = makeImage(width: 512, height: 512, token: 2)
    let large = makeImage(width: 1024, height: 1024, token: 3)
    let oversized = makeImage(width: 2048, height: 2048, token: 4)
    precondition(unit.bytesPerRow * unit.height == mib)

    // Count pressure, both caller priorities, and all four resident tiers.
    for background in [false, true] {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(128))
        for index in 0..<96 {
            await cache.insert(small, for: key(index, image: small),
                background: index % 3 != 0, storyboard: index < 12)
        }
        for index in 96..<160 {
            await cache.insert(small, for: key(index, image: small), background: background)
            await trace(cache, scenario: "count-\(background)", step: index)
        }
        _ = await cache.image(for: key(0, image: small), background: false)
        await trace(cache, scenario: "count-\(background)-promotion", step: 160)
    }

    // Single and multiple byte-budget victims, lowering the budget, oversized
    // rejection side effects, and no eligible background victim.
    for background in [false, true] {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(16))
        for index in 0..<12 {
            await cache.insert(unit, for: key(index, image: unit),
                background: index % 3 != 0, storyboard: index < 4)
        }
        await cache.configure(settings(8))
        await trace(cache, scenario: "bulk-\(background)", step: 0)
        await cache.insert(large, for: key(20, image: large), background: background)
        await trace(cache, scenario: "bulk-\(background)", step: 1)
        await cache.insert(oversized, for: key(21, image: oversized), background: background)
        await trace(cache, scenario: "bulk-\(background)", step: 2)

        let blocked = NativeThumbnailCache()
        await blocked.configure(settings(128))
        for index in 0..<96 {
            await blocked.insert(small, for: key(index, image: small),
                background: index < 12, storyboard: index < 12)
        }
        await blocked.insert(small, for: key(96, image: small), background: true)
        await trace(blocked, scenario: "blocked-\(background)", step: 0)
    }

    // Counter wrap preserves unsigned recency ordering. Equal minima must retain
    // the old filtered/sorted path's tie behavior (deterministic hashing in tests).
    for tie in [false, true] {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(128))
        await cache.setTestSerial(UInt64.max - 100)
        for index in 0..<96 {
            await cache.insert(small, for: key(index, image: small), background: false)
        }
        if tie { await cache.tieTestUseCounters() }
        for index in 96..<112 {
            await cache.insert(small, for: key(index, image: small), background: false)
            await trace(cache, scenario: "counter-\(tie)", step: index)
        }
    }

    // Complete state parity after deterministic mixed public-API operations.
    let pool = [small, unit, large, makeImage(width: 16, height: 16, token: 5),
                makeImage(width: 640, height: 360, token: 6)]
    for seed in 1...8 {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(128))
        var generator = Generator(state: UInt64(seed))
        for index in 0..<96 {
            let image = pool[index % pool.count]
            await cache.insert(image, for: key(index, image: image), background: index % 3 != 0,
                               storyboard: index < 12)
        }
        for step in 0..<256 {
            let number = generator.next()
            let index = Int((number >> 16) % 160)
            let image = pool[index % pool.count]
            let item = key(index, image: image, source: Int((number >> 48) % 3))
            var observed = -1
            switch number % 12 {
            case 0...6:
                await cache.insert(image, for: item, background: number & 0x100 != 0,
                                   storyboard: (number >> 32) % 13 == 0)
            case 7:
                if let value = await cache.image(for: item, background: number & 0x100 != 0) {
                    observed = imageToken(value)
                }
            case 8: await cache.configure(settings([8, 16, 128][Int((number >> 32) % 3)]))
            case 9: await cache.protectStoryboard(item)
            case 10: await cache.trimForMemoryPressure(critical: (number >> 32) % 8 == 0)
            default:
                if (number >> 32) % 16 == 0 { _ = await cache.clear() }
                else { await cache.selectStoryboardSource(item) }
            }
            await trace(cache, scenario: "random-\(seed)", step: step, observed: observed)
        }
    }

    // Image ownership must end on eviction; fixture pools elsewhere intentionally
    // keep pixels alive to exclude image allocation/deallocation from timings.
    do {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(8))
        weak var witness: CGImage?
        var victim: CGImage? = makeImage(width: 1024, height: 1024, token: 999)
        witness = victim
        await cache.insert(victim!, for: key(0, image: victim!), background: false)
        victim = nil
        precondition(witness != nil)
        await cache.insert(large, for: key(1, image: large), background: false)
        await cache.insert(large, for: key(2, image: large), background: false)
        precondition(witness == nil, "Evicted image is still retained")
        await trace(cache, scenario: "release", step: 0)
    }
}

private func benchmarkStream(_ name: String, iterations: Int) async {
    let cache = NativeThumbnailCache()
    await cache.configure(settings(name == "byte-budget" ? 16 : 128))
    // Pixel construction and key construction are outside the measured region.
    // Distinct real CGImages on macOS; metadata-only objects on Linux.
    let images = (0..<256).map { makeImage(token: $0 + 100) }
    let incomingKeys = images.enumerated().map { key($0.offset + 1000, image: $0.element) }
    let residentKeys = (0..<96).map { key($0, image: images[$0]) }
    for index in 0..<96 {
        let protected = (name == "count-mixed" || name == "count-background") && index < 12
        let background: Bool
        switch name {
        case "count-background": background = index >= 32 || protected
        case "count-mixed": background = index % 3 != 0
        default: background = false
        }
        await cache.insert(images[index], for: residentKeys[index],
                           background: background, storyboard: protected)
    }

    let incomingBackground = name == "count-background" || name == "no-victim"
    var checksum: UInt64 = 0
    // Warmup uses the same path and reaches steady occupancy before timing.
    for index in 0..<512 {
        if name == "resident-hit" {
            let image = await cache.image(for: residentKeys[index % 96], background: false)!
            checksum &+= UInt64(image.bytesPerRow)
        } else {
            await cache.insert(images[index % 256], for: incomingKeys[index % 256],
                               background: incomingBackground)
        }
    }
    let cpuStart = cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        if name == "resident-hit" {
            let image = await cache.image(for: residentKeys[index % 96], background: false)!
            checksum &+= UInt64(image.bytesPerRow)
        } else {
            await cache.insert(images[index % 256], for: incomingKeys[index % 256],
                               background: incomingBackground)
        }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = cpuNanoseconds() - cpuStart
    let receipt = await cache.evictionReceipt() + ["checksum=\(checksum)"]
    emit(["case": name, "iterations": iterations, "elapsed_ns": elapsed,
          "cpu_ns": cpu, "receipt": receipt])
}

private func benchmarkBulk(_ name: String, iterations: Int) async {
    let images = (0..<96).map { makeImage(width: 512, height: 512, token: $0 + 1) }
    let large = makeImage(width: 1024, height: 1024, token: 100)
    let residentKeys = images.enumerated().map { key($0.offset, image: $0.element) }
    let incoming = key(100, image: large)
    var elapsed: UInt64 = 0
    var cpu: UInt64 = 0
    var checksum = 0
    var final: [String] = []
    // Each timed operation has its own freshly populated cache. Fixture setup
    // and receipt generation are excluded; index -1 is an excluded warmup.
    for repetition in -1..<iterations {
        let cache = NativeThumbnailCache()
        await cache.configure(settings(name == "bulk-configure" ? 128 : 8))
        let count = name == "bulk-configure" ? 96 : 8
        for index in 0..<count {
            await cache.insert(images[index], for: residentKeys[index],
                background: index % 3 != 0, storyboard: index < 2)
        }
        let cpuStart = cpuNanoseconds()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        if name == "bulk-configure" { await cache.configure(settings(8)) }
        else { await cache.insert(large, for: incoming, background: false) }
        let wallEnd = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = cpuNanoseconds()
        if repetition >= 0 {
            elapsed += wallEnd - wallStart
            cpu += cpuEnd - cpuStart
            checksum += (await cache.usage()).images
        }
        final = await cache.evictionReceipt()
    }
    emit(["case": name, "iterations": iterations, "elapsed_ns": elapsed,
          "cpu_ns": cpu, "receipt": final + ["checksum=\(checksum)"]])
}

@main
private struct Driver {
    static func main() async {
        precondition(!NonDecodePerformance.isEnabled)
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "verify" {
            await verify()
            return
        }
        precondition(arguments.count == 4 && arguments[1] == "benchmark")
        let name = arguments[2]
        let iterations = Int(arguments[3])!
        precondition(iterations > 0)
        if name.hasPrefix("bulk-") { await benchmarkBulk(name, iterations: iterations) }
        else { await benchmarkStream(name, iterations: iterations) }
    }
}
