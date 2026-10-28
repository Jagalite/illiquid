import Foundation
import IlliquidCore

private struct Workload: Codable, Sendable {
    let id: String
    let api: String
    let kind: String
    let count: Int
    let match: String
}

private struct Measurement: Codable {
    let workload: Workload
    let iterations: Int
    let calls: Int
    let elapsedMilliseconds: Double
    let nanosecondsPerCall: Double
    let checksum: String
}

private enum QualificationError: Error {
    case invalidArguments
    case byteParity(String)
    case resultMismatch(String)
}

private let workloads: [Workload] = {
    var result = [
        Workload(id: "key-prepared-ascii", api: "key", kind: "ascii", count: 256, match: ""),
        Workload(id: "key-lexical-alias", api: "key", kind: "alias", count: 256, match: ""),
        Workload(id: "key-long-ascii", api: "key", kind: "long", count: 128, match: ""),
        Workload(id: "key-escaped-ascii", api: "key", kind: "escaped", count: 256, match: ""),
        Workload(id: "key-localhost", api: "key", kind: "localhost", count: 256, match: ""),
        Workload(id: "key-unicode-early", api: "key", kind: "unicode-early", count: 256, match: ""),
        Workload(id: "key-unicode-late", api: "key", kind: "unicode-late", count: 128, match: ""),
        Workload(id: "key-unusual-path", api: "key", kind: "unusual", count: 128, match: ""),
        Workload(id: "key-rejected-authority", api: "key", kind: "rejected", count: 256, match: ""),
        Workload(id: "normalize-ascii-control", api: "normalize", kind: "ascii", count: 256, match: ""),
    ]
    for api in ["folder", "mutation"] {
        for count in [32, 1_000, 10_000] {
            for match in ["last", "missing"] {
                result.append(Workload(id: "\(api)-ascii-\(count)-\(match)",
                    api: api, kind: "ascii", count: count, match: match))
            }
        }
        result.append(Workload(id: "\(api)-ascii-1000-first",
            api: api, kind: "ascii", count: 1_000, match: "first"))
        result.append(Workload(id: "\(api)-unicode-1000-last",
            api: api, kind: "unicode-early", count: 1_000, match: "last"))
    }
    return result
}()

private func makeURL(kind: String, index: Int) -> URL {
    let number = String(repeating: "0", count: max(0, 6 - String(index).count)) + String(index)
    let filename = "Episode \(number).mkv"
    let longPrefix = String(repeating: "Long ASCII directory/", count: 24)
    switch kind {
    case "alias":
        return URL(string: "file:///Media/Discard/../Season/./Episode%20\(number).mkv")!
    case "long":
        return URL(fileURLWithPath: "/Media/\(longPrefix)\(filename)", isDirectory: false)
    case "escaped":
        return URL(string: "file:///Media/Season%20%231/Film%20%25%3F%3B%5C-\(number).mkv")!
    case "localhost":
        return URL(string: "file://LOCALHOST/Media/Season/Episode%20\(number).mkv")!
    case "unicode-early":
        return URL(fileURLWithPath: "/Caf\u{00e9}/Season/\(filename)", isDirectory: false)
    case "unicode-late":
        return URL(fileURLWithPath: "/Media/\(longPrefix)/Cafe\u{0301}/\(filename)", isDirectory: false)
    case "unusual":
        return URL(string: "file:///Media/%2E%2E/Season//Episode%20\(number).mkv")!
    case "rejected":
        return URL(string: "file://media.example.invalid/Media/Episode%20\(number).mkv")!
    default:
        return URL(fileURLWithPath: "/Media/Season/\(filename)", isDirectory: false)
    }
}

private func consume(_ key: String?) -> UInt64 {
    UInt64(key?.utf8.count ?? 0) + 1
}

@inline(never)
private func keyBatch(_ urls: [URL], iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        for url in urls {
            checksum &+= consume(NormalizedFileURL.persistenceKey(for: url))
        }
    }
    return checksum
}

@inline(never)
private func normalizeBatch(_ urls: [URL], iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        for url in urls {
            checksum &+= consume(NormalizedFileURL.normalize(url)?.path)
        }
    }
    return checksum
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

@main
private struct Driver {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            try emit(workloads)
            return
        }
        guard arguments.count == 2,
              let workload = workloads.first(where: { $0.id == arguments[0] }),
              let iterations = Int(arguments[1]), iterations > 0
        else { throw QualificationError.invalidArguments }

        let urls = (0..<workload.count).map { makeURL(kind: workload.kind, index: $0) }
        var expectedBatch: UInt64 = 0
        // Check exact bytes before the clock; String == is insufficient on Darwin.
        for url in urls {
            let expected = NormalizedFileURL.normalize(url)?.path
            let actual = NormalizedFileURL.persistenceKey(for: url)
            guard expected.map({ Array($0.utf8) }) == actual.map({ Array($0.utf8) })
            else { throw QualificationError.byteParity(url.absoluteString) }
            expectedBatch &+= consume(expected)
        }

        let operation: (Int) -> UInt64
        let callsPerIteration: Int
        if workload.api == "key" {
            operation = { keyBatch(urls, iterations: $0) }
            callsPerIteration = urls.count
        } else if workload.api == "normalize" {
            operation = { normalizeBatch(urls, iterations: $0) }
            callsPerIteration = urls.count
        } else {
            // Preparation and sorting are deliberately outside the timed region.
            let items = urls.map { FolderPlaylistItem(url: $0) }
            let folder = FolderPlaylist(
                folderURL: URL(fileURLWithPath: "/Media", isDirectory: true), items: items)
            let query: URL
            let expectedIndex: Int?
            switch workload.match {
            case "first":
                query = urls[0]
                expectedIndex = 0
            case "last":
                query = urls[urls.count - 1]
                expectedIndex = urls.count - 1
            default:
                query = makeURL(kind: workload.kind, index: urls.count + 100)
                expectedIndex = workload.api == "mutation" ? 0 : nil
            }
            let lookup: () -> Int?
            if workload.api == "folder" {
                lookup = { folder.index(of: query) }
            } else {
                lookup = {
                    PlaylistMutation.indexPreservingCurrentIdentity(
                        currentURL: query, fallbackIndex: nil, in: items)
                }
            }
            guard lookup() == expectedIndex
            else { throw QualificationError.resultMismatch(workload.id) }
            expectedBatch = UInt64((expectedIndex ?? -1) + 1)
            operation = { count in
                var checksum: UInt64 = 0
                for _ in 0..<count {
                    checksum &+= UInt64((lookup() ?? -1) + 1)
                }
                return checksum
            }
            callsPerIteration = 1
        }

        let warmup = operation(2)
        guard warmup == expectedBatch &* 2
        else { throw QualificationError.resultMismatch(workload.id + " warmup") }
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = operation(iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        guard checksum == expectedBatch &* UInt64(iterations)
        else { throw QualificationError.resultMismatch(workload.id + " measurement") }
        let calls = iterations * callsPerIteration
        try emit(Measurement(workload: workload, iterations: iterations, calls: calls,
            elapsedMilliseconds: Double(elapsed) / 1_000_000,
            nanosecondsPerCall: Double(elapsed) / Double(calls),
            checksum: String(checksum)))
    }
}
