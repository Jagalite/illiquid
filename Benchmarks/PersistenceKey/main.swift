import Dispatch
import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let caseNames = [
    "ascii-short", "ascii-long", "ascii-escaped", "ascii-directory",
    "unicode-nfc", "unicode-nfd", "unicode-long", "encoded-components",
    "localhost", "base-relative", "rejected-authorities",
    "playlist-last-1000", "playlist-miss-1000",
    "playlist-last-10000", "playlist-miss-10000", "playlist-unicode-last-1000",
    "file-reference-prefix", "control-character",
]

private struct Fixture {
    let queries: [URL]
    let playlist: FolderPlaylist?

    init(_ name: String) {
        if name.hasPrefix("playlist-") {
            let count = name.hasSuffix("10000") ? 10_000 : 1_000
            let parent = name.contains("unicode") ? "/Benchmark/Café/" : "/Benchmark/Media/"
            let folder = URL(fileURLWithPath: parent, isDirectory: true)
            let items = (0..<count).reversed().map { index in
                FolderPlaylistItem(url: URL(
                    fileURLWithPath: parent + "Episode \(index + 1).mkv", isDirectory: false
                ))
            }
            let value = FolderPlaylist(folderURL: folder, items: items)
            playlist = value
            let query = name.contains("miss")
                ? URL(fileURLWithPath: parent + "Missing.mkv", isDirectory: false)
                : value.items.last!.url
            // Four full scans amortize clocks without hiding large-input costs.
            queries = Array(repeating: query, count: 4)
            return
        }
        playlist = nil
        let base = URL(fileURLWithPath: "/Benchmark/Collection/Season/", isDirectory: true)
        queries = (0..<64).map { index in
            let suffix = "Episode-\(index + 1).mkv"
            switch name {
            case "ascii-short":
                return URL(fileURLWithPath: "/Media/Season/" + suffix, isDirectory: false)
            case "ascii-long":
                return URL(fileURLWithPath: "/Media/" + String(repeating: "A long collection directory/", count: 20) + suffix, isDirectory: false)
            case "ascii-escaped":
                return URL(string: "file:///Media/A%20B%23C%3FD%25/" + suffix)!
            case "ascii-directory":
                return URL(fileURLWithPath: "/Media/Season-\(index + 1)/", isDirectory: true)
            case "file-reference-prefix":
                // Exercise the conservative /.file/ fallback without creating
                // an id= file reference or requiring a real filesystem object.
                return URL(fileURLWithPath: "/.file/cache/" + suffix, isDirectory: false)
            case "control-character":
                // Tabs/newlines remain ASCII fast-path edges in PR #144.
                let control = index.isMultiple(of: 2) ? "\t" : "\n"
                return URL(fileURLWithPath: "/Media/A" + control + "B/" + suffix, isDirectory: false)
            case "unicode-nfc":
                return URL(string: "file:///Media/Caf%C3%A9/%C3%89pisode-\(index + 1).mkv")!
            case "unicode-nfd":
                return URL(string: "file:///Media/Cafe%CC%81/E%CC%81pisode-\(index + 1).mkv")!
            case "unicode-long":
                return URL(string: "file:///Media/" + String(repeating: "LongDirectory/", count: 40) + "Cafe%CC%81/" + suffix)!
            case "encoded-components":
                let components = ["Z/%2E%2E/A", "A%2FB", "A%252FB", "%2E/Season"]
                return URL(string: "file:///Media/" + components[index % components.count] + "/" + suffix)!
            case "localhost":
                return URL(string: "file://LOCALHOST/Media/" + suffix)!
            case "base-relative":
                return URL(string: "../Season/" + suffix, relativeTo: base)!
            case "rejected-authorities":
                let prefixes = ["file://remote.invalid", "file://user@localhost", "file://localhost:1234", "https://media.invalid"]
                return URL(string: prefixes[index % prefixes.count] + "/Media/" + suffix)!
            default:
                preconditionFailure("Unknown case")
            }
        }
    }
}

private enum Output {
    case keys([String?])
    case indices([Int?])

    var bytes: [[UInt8]?]? {
        if case .keys(let keys) = self { return keys.map { $0.map { Array($0.utf8) } } }
        return nil
    }
    var indices: [Int?]? {
        if case .indices(let indices) = self { return indices }
        return nil
    }
}

@inline(never)
private func run(_ fixture: Fixture) -> Output {
    if let playlist = fixture.playlist {
        return .indices(fixture.queries.map { playlist.index(of: $0) })
    }
    return .keys(fixture.queries.map { NormalizedFileURL.persistenceKey(for: $0) })
}

private func originalOutput(_ fixture: Fixture) -> Output {
    if let playlist = fixture.playlist {
        // Independent old identity operation; neither item.id nor
        // representsSameFile may be used because they call the candidate.
        let itemKeys = playlist.items.map { NormalizedFileURL.normalize($0.url)?.path }
        return .indices(fixture.queries.map { query in
            guard let queryKey = NormalizedFileURL.normalize(query)?.path else { return nil }
            return itemKeys.firstIndex { $0.map { $0 == queryKey } ?? false }
        })
    }
    return .keys(fixture.queries.map { NormalizedFileURL.normalize($0)?.path })
}

private struct URLReceipt: Encodable {
    let absolute: String
    let relative: String
    let base: String?
    let directory: Bool
    init(_ url: URL) {
        absolute = url.absoluteString
        relative = url.relativeString
        base = url.baseURL?.absoluteString
        directory = url.hasDirectoryPath
    }
}

private struct Receipt: Encodable {
    let queryURLs: [URLReceipt]
    let itemURLs: [URLReceipt]
    let keysUTF8: [[UInt8]?]?
    let indices: [Int?]?
}

private struct Measurement: Encodable {
    let elapsedNanoseconds: UInt64
    let cpuElapsedTicks: UInt64
    let clockTicksPerSecond: UInt64
    let iterations: Int
    let operationsPerIteration: Int
    let itemCount: Int
    let locale: String
    let output: Receipt
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--list" {
    FileHandle.standardOutput.write(try encoder.encode(caseNames))
    FileHandle.standardOutput.write(Data([10]))
} else {
    guard CommandLine.arguments.count == 3,
          caseNames.contains(CommandLine.arguments[1]),
          let iterations = Int(CommandLine.arguments[2]), iterations > 0 else {
        fatalError("Usage: persistence-key-probe CASE POSITIVE_ITERATIONS (or --list)")
    }
    let fixture = Fixture(CommandLine.arguments[1])
    let expected = originalOutput(fixture)
    let expectedBytes = expected.bytes
    let expectedIndices = expected.indices
    let warmup = run(fixture)
    precondition(warmup.bytes == expectedBytes && warmup.indices == expectedIndices,
                 "Warmup differs from original normalize(url)?.path oracle")
    var elapsed: UInt64 = 0
    var cpuTicks: UInt64 = 0
    let invalidClock = clock_t(truncatingIfNeeded: -1)
    for _ in 0..<iterations {
        let cpuStart = clock()
        let start = DispatchTime.now().uptimeNanoseconds
        let output = run(fixture)
        let finish = DispatchTime.now().uptimeNanoseconds
        let cpuFinish = clock()
        precondition(cpuStart != invalidClock && cpuFinish != invalidClock && cpuFinish >= cpuStart)
        elapsed += finish - start
        cpuTicks += UInt64(cpuFinish - cpuStart)
        // Byte conversion and verification consume every key after the timer.
        precondition(output.bytes == expectedBytes && output.indices == expectedIndices,
                     "Result differs from original identity oracle")
    }
    let measurement = Measurement(
        elapsedNanoseconds: elapsed, cpuElapsedTicks: cpuTicks,
        clockTicksPerSecond: UInt64(CLOCKS_PER_SEC), iterations: iterations,
        operationsPerIteration: fixture.queries.count, itemCount: fixture.playlist?.count ?? 0,
        locale: Locale.current.identifier,
        output: Receipt(queryURLs: fixture.queries.map(URLReceipt.init),
                        itemURLs: fixture.playlist?.items.map { URLReceipt($0.url) } ?? [],
                        keysUTF8: expectedBytes, indices: expectedIndices)
    )
    FileHandle.standardOutput.write(try encoder.encode(measurement))
    FileHandle.standardOutput.write(Data([10]))
}
