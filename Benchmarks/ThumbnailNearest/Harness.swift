import CoreGraphics
import Darwin
import Foundation
import IlliquidCore
@testable import IlliquidNativePlayback

private typealias Key = NativeThumbnailCache.Key

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}

private struct Entry: @unchecked Sendable {
    let key: Key
    let image: CGImage
}

private struct Query: Sendable {
    let key: Key
    let maximumDistance: Double
    let fallbackTimes: [Double]
}

private struct Fixture: Sendable {
    let cache: NativeThumbnailCache
    let entries: [Entry]
    let queries: [Query]
}

private func key(_ bucket: Int, path: String = "/benchmark/video.mkv",
                 version: String = "version-1", width: Int = 160, height: Int = 90) -> Key {
    Key(path: path, version: version, halfSecond: bucket, width: width, height: height)
}

private func image(_ seed: Int) throws -> CGImage {
    let width = 8 + seed % 4, height = 8 + (seed / 4) % 3
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
        bytes[index * 4] = UInt8((seed * 43 + index * 7) & 255)
        bytes[index * 4 + 1] = UInt8((seed * 71 + index * 13) & 255)
        bytes[index * 4 + 2] = UInt8((seed * 19 + index * 29) & 255)
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let result = CGImage(width: width, height: height, bitsPerComponent: 8,
             bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw Failure(description: "Could not create fixture image") }
    return result
}

private func imageChecksum(_ image: CGImage) throws -> String {
    let count = image.width * image.height * 4
    guard let context = CGContext(data: nil, width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: image.width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data
    else { throw Failure(description: "Could not create image receipt") }
    memset(data, 0, count)
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var checksum: UInt64 = 0xCBF29CE484222325
    for index in 0..<count { checksum = (checksum ^ UInt64(bytes[index])) &* 0x100000001B3 }
    return String(checksum, radix: 16)
}

private func memoryFixture(entries: [Entry], queries: [Query]) async -> Fixture {
    let cache = NativeThumbnailCache()
    var preferences = ThumbnailPreferences()
    preferences.diskMiB = 0
    await cache.configure(preferences)
    for entry in entries {
        await cache.insert(entry.image, for: entry.key, background: false)
    }
    return Fixture(cache: cache, entries: entries, queries: queries)
}

private let cases = [
    "empty", "one-resident", "24-residents", "96-residents",
    "96-mixed-identities", "96-long-path", "24-fallback-duplicates", "missing-fallbacks",
    "96-nearby", "24-storyboard",
]

private func workload(_ name: String) async throws -> Fixture {
    try require(cases.contains(name), "Unknown workload: \(name)")
    let count: Int
    switch name {
    case "empty", "missing-fallbacks": count = 0
    case "one-resident": count = 1
    case "24-residents", "24-fallback-duplicates", "24-storyboard": count = 24
    default: count = 96
    }
    let path = name == "96-long-path"
        ? "/benchmark/" + String(repeating: "television-season-component/", count: 64) + "video.mkv"
        : "/benchmark/video.mkv"
    var entries: [Entry] = []
    for index in 0..<count {
        let mixed = name == "96-mixed-identities"
        entries.append(Entry(
            key: key(index * 4, path: mixed && index % 4 == 1 ? path + ".other" : path,
                     version: mixed && index % 4 == 2 ? "version-2" : "version-1",
                     width: mixed && index % 4 == 3 ? 161 : 160),
            image: try image(index)
        ))
    }
    let fallbacks: [Double]
    if name == "24-fallback-duplicates" {
        fallbacks = (0..<24).map { Double(($0 % 8) * 4) / 2 }
    } else if name == "missing-fallbacks" {
        fallbacks = (0..<24).map { Double($0 * 4) / 2 }
    } else if name == "24-storyboard" {
        fallbacks = (0..<24).map { Double($0 * 4 + 2) / 2 }
    } else {
        fallbacks = []
    }
    let targets = name == "24-storyboard" ? [3, 15, 47, 91] : [1, 13, 45, 89]
    let queries = targets.map {
        Query(key: key($0, path: path), maximumDistance: name == "96-nearby" ? 3 : 7_200,
              fallbackTimes: fallbacks)
    }
    return await memoryFixture(entries: entries, queries: queries)
}

private struct Selection: Encodable, Sendable {
    let timeBits: String
    let imageWidth: Int
    let imageHeight: Int
    let imageChecksum: String
    let residentIndex: Int?
}

private struct Receipt: Encodable, Sendable {
    let name: String
    let selected: Selection?

    private enum CodingKeys: String, CodingKey { case name, selected }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(selected, forKey: .selected)
    }
}

private func receipt(_ name: String, match: (CGImage, Double)?,
                     entries: [Entry]) throws -> Receipt {
    guard let (image, time) = match else { return Receipt(name: name, selected: nil) }
    return Receipt(name: name, selected: Selection(
        timeBits: String(time.bitPattern, radix: 16), imageWidth: image.width,
        imageHeight: image.height, imageChecksum: try imageChecksum(image),
        residentIndex: entries.firstIndex { $0.image === image }
    ))
}

private func inspect(_ name: String, fixture: Fixture) async throws -> [Receipt] {
    var receipts: [Receipt] = []
    for (offset, query) in fixture.queries.enumerated() {
        let match = await fixture.cache.nearest(
            to: query.key, maximumDistance: query.maximumDistance, fallbackTimes: query.fallbackTimes
        )
        receipts.append(try receipt("\(name)-\(offset)", match: match, entries: fixture.entries))
    }
    return receipts
}

private actor Gate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct Verification: Encodable, Sendable {
    let cases: [String]
    let fixtures: [Receipt]
    let checks: [String: String]
}

private func verify() async throws -> Verification {
    var receipts: [Receipt] = []
    var checks: [String: String] = [:]
    for name in cases {
        let fixture = try await workload(name)
        receipts += try await inspect(name, fixture: fixture)
    }

    let tieEntries = [
        Entry(key: key(2), image: try image(1)),
        Entry(key: key(-2), image: try image(2)),
    ]
    let edgeFallbacks = [
        Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude,
        -0.75, -0.25, 0.25, 0.75, 0.75, Double(Int.max) / 2, Double(Int.min) / 2,
    ]
    let bounds: [Double] = [-1, .nan, .infinity, -.infinity, -0.0, 0.5, 1.0.nextDown, 1, 2]
    let ties = await memoryFixture(entries: tieEntries, queries: bounds.map {
        Query(key: key(0), maximumDistance: $0, fallbackTimes: edgeFallbacks)
    })
    receipts += try await inspect("bounds-and-negative-tie", fixture: ties)
    let tied = await ties.cache.nearest(to: key(0), maximumDistance: 1)
    try require(tied?.0 === tieEntries[1].image && tied?.1 == -1,
                "Equal distance must prefer the lower bucket")
    checks["distance-tie"] = "lower signed bucket"

    for (name, buckets, target) in [
        ("positive-double-tie", [Int.max, Int.max - 1], Int.max),
        ("negative-double-tie", [Int.min + 1, Int.min], Int.min),
    ] {
        let entries = try buckets.enumerated().map { Entry(key: key($0.element), image: try image($0.offset + 10)) }
        let fixture = await memoryFixture(entries: entries, queries: [
            Query(key: key(target), maximumDistance: 0, fallbackTimes: []),
            Query(key: key(target), maximumDistance: Double.greatestFiniteMagnitude, fallbackTimes: edgeFallbacks),
        ])
        receipts += try await inspect(name, fixture: fixture)
        let match = await fixture.cache.nearest(to: key(target), maximumDistance: 0)
        let expectedIndex = buckets[0] < buckets[1] ? 0 : 1
        try require(match?.0 === entries[expectedIndex].image,
                    "Rounded Double distance ties must retain integer ordering")
    }

    let identityEntries = [
        Entry(key: key(10, path: "/benchmark/other.mkv"), image: try image(30)),
        Entry(key: key(10, version: "other"), image: try image(31)),
        Entry(key: key(10, width: 161), image: try image(32)),
        Entry(key: key(10, height: 91), image: try image(33)),
    ]
    let identities = await memoryFixture(entries: identityEntries, queries: [
        Query(key: key(10), maximumDistance: 0, fallbackTimes: [5, 5]),
    ])
    receipts += try await inspect("identity-isolation", fixture: identities)
    try require(await identities.cache.nearest(to: key(10), maximumDistance: 0) == nil,
                "Lookup crossed file/version/size identity")

    let cancelFixture = try await workload("24-fallback-duplicates")
    let gate = Gate()
    let cancelled = Task {
        await gate.wait()
        return await cancelFixture.cache.nearest(
            to: cancelFixture.queries[0].key, maximumDistance: 7_200,
            fallbackTimes: cancelFixture.queries[0].fallbackTimes
        ) == nil
    }
    cancelled.cancel()
    await gate.open()
    try require(await cancelled.value, "Cancelled lookup returned an image")
    checks["cancelled"] = "nil"

    // Real disk fallback and canonical-equivalent spellings are verified,
    // but filesystem/JPEG work is excluded from the timed component workloads.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("illiquid-nearest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = NativeThumbnailCache(directory: directory)
    let diskEntries = try [-2, -1, 1, 2].enumerated().map {
        Entry(key: key($0.element, path: "/benchmark/rounding.mkv"), image: try image($0.offset + 40))
    }
    for entry in diskEntries {
        await writer.insert(entry.image, for: entry.key, background: true)
        await writer.flushPendingWrites()
    }
    for (index, fallback) in [-0.75, -0.25, 0.25, 0.75].enumerated() {
        let reader = NativeThumbnailCache(directory: directory)
        let match = await reader.nearest(to: key(0, path: "/benchmark/rounding.mkv"),
                                        maximumDistance: 1, fallbackTimes: [fallback, fallback])
        try require(match?.1 == Double(Int((fallback * 2).rounded())) / 2,
                    "Fallback rounding changed")
        receipts.append(try receipt("disk-rounding-\(index)", match: match, entries: []))
        await reader.flushPendingWrites()
    }

    let original = key(20, path: "/benchmark/\u{00e9}pisode.mkv", version: "\u{00c5}")
    let equivalent = key(21, path: "/benchmark/e\u{0301}pisode.mkv", version: "A\u{030A}")
    try require(original.path == equivalent.path && original.version == equivalent.version,
                "Fixture strings are not canonically equivalent")
    let equivalentBucket = key(20, path: equivalent.path, version: equivalent.version)
    try require(original.digest != equivalentBucket.digest, "Fixture did not exercise exact digest spelling")
    let unicodeImage = try image(55)
    let unicodeEntry = Entry(key: original, image: unicodeImage)
    await writer.insert(unicodeImage, for: original, background: true)
    await writer.flushPendingWrites()
    let unicodeMatch = await writer.nearest(to: equivalent, maximumDistance: 1, fallbackTimes: [10, 10])
    try require(unicodeMatch?.0 === unicodeImage, "Equivalent strings missed resident image")
    receipts.append(try receipt("unicode-resident-promotion", match: unicodeMatch, entries: [unicodeEntry]))
    await writer.flushPendingWrites()
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    try require(names.contains("f-\(original.digest).jpg"), "Resident spelling lost during promotion")
    try require(!names.contains("f-\(equivalentBucket.digest).jpg"), "Query spelling replaced resident digest")
    checks["unicode-resident-digest"] = original.digest
    checks["unicode-query-digest"] = equivalentBucket.digest
    return Verification(cases: cases, fixtures: receipts, checks: checks)
}

private struct Measurement: Encodable, Sendable {
    let caseName: String
    let iterations: Int
    let operations: Int
    let elapsedNanoseconds: UInt64
    let checksum: String
    let publishedSamples: Int
    private enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, operations, checksum
        case elapsedNanoseconds = "elapsed_ns"
        case publishedSamples = "published_samples"
    }
}

@inline(never)
private func perform(_ fixture: Fixture, iterations: Int) async -> (UInt64, Int) {
    var checksum: UInt64 = 0xCBF29CE484222325
    var hits = 0
    for index in 0..<iterations {
        let query = fixture.queries[index & 3]
        let match = await fixture.cache.nearest(
            to: query.key, maximumDistance: query.maximumDistance, fallbackTimes: query.fallbackTimes
        )
        if let (image, time) = match {
            hits += 1
            checksum = (checksum ^ time.bitPattern) &* 0x100000001B3
            checksum = (checksum ^ UInt64(image.width)) &* 0x100000001B3
            checksum = (checksum ^ UInt64(image.height)) &* 0x100000001B3
        } else {
            checksum = (checksum ^ UInt64(index)) &* 0x100000001B3
        }
    }
    return (checksum, hits)
}

private func measure(_ name: String, iterations: Int) async throws -> Measurement {
    try require(iterations > 0, "Iterations must be positive")
    let fixture = try await workload(name)
    _ = await perform(fixture, iterations: 512)
    let start = DispatchTime.now().uptimeNanoseconds
    let (checksum, hits) = await perform(fixture, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    withExtendedLifetime(fixture) {}
    let expectsHit = name != "empty" && name != "missing-fallbacks"
    try require(hits == (expectsHit ? iterations : 0), "Unexpected measured hit count")
    return Measurement(caseName: name, iterations: iterations, operations: iterations,
                       elapsedNanoseconds: elapsed, checksum: String(checksum, radix: 16),
                       publishedSamples: hits)
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

@main
private struct Harness {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--mode", "verify"] {
                try emit(await verify())
            } else if arguments.count == 6, arguments[0] == "--mode", arguments[1] == "measure",
                      arguments[2] == "--case", arguments[4] == "--iterations",
                      let count = Int(arguments[5]) {
                try emit(await measure(arguments[3], iterations: count))
            } else {
                throw Failure(description: "Usage: --mode verify | --mode measure --case NAME --iterations N")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
