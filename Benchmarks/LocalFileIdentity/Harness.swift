import Foundation
import IlliquidCore

struct Workload: Codable, Sendable {
    let id: String
    let api: String
    let size: Int
}

struct Prepared {
    let work: (Int) -> UInt64
    let expected: [UInt64]
    let semantics: [[UInt8]?]
}

enum Failure: Error { case mismatch(String) }

private func token(_ value: String?) -> UInt64 {
    guard let value else { return 0 }
    return UInt64(value.utf8.count) &* 65_537
        &+ UInt64(value.utf8.first ?? 0) &* 257
        &+ UInt64(value.utf8.last ?? 0) &+ 1
}

private func bytes(_ value: String?) -> [UInt8]? { value.map { Array($0.utf8) } }
private func reference(_ url: URL) -> String? { NormalizedFileURL.normalize(url)?.path }
private func file(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: false) }

@main
struct IdentityBenchmark {
    static let workloads: [Workload] = [
        Workload(id: "key-ascii-short", api: "key", size: 64),
        Workload(id: "key-ascii-long", api: "key", size: 64),
        Workload(id: "key-ascii-escaped", api: "key", size: 64),
        Workload(id: "key-ascii-alias", api: "key", size: 64),
        Workload(id: "key-ascii-relative", api: "key", size: 64),
        Workload(id: "key-unicode-nfc", api: "key", size: 64),
        Workload(id: "key-unicode-nfd", api: "key", size: 64),
        Workload(id: "key-rejected-https", api: "key", size: 64),
        Workload(id: "key-rejected-authority", api: "key", size: 64),
        Workload(id: "same-file-ascii", api: "sameFile", size: 64),
        Workload(id: "same-file-unicode", api: "sameFile", size: 64),
        Workload(id: "playlist-lookup-32-last", api: "lookup", size: 32),
        Workload(id: "playlist-lookup-1000-first", api: "lookup", size: 1_000),
        Workload(id: "playlist-lookup-1000-middle", api: "lookup", size: 1_000),
        Workload(id: "playlist-lookup-1000-last", api: "lookup", size: 1_000),
        Workload(id: "playlist-lookup-1000-miss", api: "lookup", size: 1_000),
        Workload(id: "playlist-lookup-10000-last", api: "lookup", size: 10_000),
        Workload(id: "playlist-lookup-1000-unicode", api: "lookup", size: 1_000),
        Workload(id: "playlist-dedup-1000-unique", api: "deduplicate", size: 1_000),
        Workload(id: "playlist-dedup-1000-duplicates", api: "deduplicate", size: 1_000),
    ]

    static func urls(_ id: String) -> [URL] {
        (0..<64).map { index in
            switch id {
            case "key-ascii-short":
                return file("/Movies/Episode \(index).mkv")
            case "key-ascii-long":
                return file("/Volumes/Archive/" + String(repeating: "Series and Season/", count: 32)
                            + "Episode \(index).mkv")
            case "key-ascii-escaped":
                return file("/Volumes/Media Share/100% #1 + [director's cut]/Episode \(index)?.mkv")
            case "key-ascii-alias":
                return URL(string: "file://LOCALHOST/Movies/Season/../Episode%20\(index).mkv?ignored=1#part")!
            case "key-ascii-relative":
                return URL(string: "Season/../Episode%20\(index).mkv",
                           relativeTo: URL(fileURLWithPath: "/Movies/", isDirectory: true))!
            case "key-unicode-nfc":
                return file("/Movies/Caf\u{00E9}/\u{65E5}\u{672C}\u{8A9E}/Episode \(index).mkv")
            case "key-unicode-nfd":
                return file("/Movies/Cafe\u{0301}/A\u{030A}land/Episode \(index).mkv")
            case "key-rejected-https":
                return URL(string: "https://example.invalid/Movies/Episode\(index).mkv")!
            case "key-rejected-authority":
                return URL(string: "file://media.example.invalid/Movies/Episode\(index).mkv")!
            default:
                preconditionFailure("Unknown key workload")
            }
        }
    }

    static func prepare(_ workload: Workload) throws -> Prepared {
        switch workload.api {
        case "key":
            let inputs = urls(workload.id)
            let expectedKeys = inputs.map(reference)
            for (input, expected) in zip(inputs, expectedKeys) {
                guard bytes(NormalizedFileURL.persistenceKey(for: input)) == bytes(expected) else {
                    throw Failure.mismatch("Key bytes: \(workload.id), \(input.absoluteString)")
                }
            }
            return Prepared(
                work: { token(NormalizedFileURL.persistenceKey(for: inputs[$0 % inputs.count])) },
                expected: expectedKeys.map(token), semantics: expectedKeys.map(bytes)
            )
        case "sameFile":
            let unicode = workload.id == "same-file-unicode"
            let left = urls(unicode ? "key-unicode-nfc" : "key-ascii-short")
            let right = left.enumerated().map { index, value in
                index.isMultiple(of: 2) ? value
                    : file(value.deletingLastPathComponent().path + "/Different \(index).mkv")
            }
            let expected = zip(left, right).map { lhs, rhs -> UInt64 in
                guard let a = reference(lhs), let b = reference(rhs) else { return 0 }
                return a == b ? 1 : 0
            }
            for index in left.indices {
                guard NormalizedFileURL.representsSameFile(left[index], right[index])
                        == (expected[index] == 1) else {
                    throw Failure.mismatch("Identity comparison")
                }
            }
            return Prepared(
                work: { NormalizedFileURL.representsSameFile(left[$0 % 64], right[$0 % 64]) ? 1 : 0 },
                expected: expected,
                semantics: (left + right).map { bytes(reference($0)) }
            )
        case "lookup":
            let folder = workload.id.hasSuffix("-unicode") ? "/Movies/Caf\u{00E9}" : "/Movies"
            let items = (0..<workload.size).map { index in
                FolderPlaylistItem(url: file("\(folder)/Episode \(index).mkv"),
                                   dateAdded: Date(timeIntervalSince1970: Double(index)))
            }
            let selected: Int
            if workload.id.hasSuffix("-first") { selected = 0 }
            else if workload.id.hasSuffix("-middle") { selected = workload.size / 2 }
            else { selected = workload.size - 1 }
            let missing = workload.id.hasSuffix("-miss")
            let indices = Array(repeating: missing ? 0 : selected, count: 64)
            let targets = (0..<64).map {
                file("\(folder)/Season \($0)/../Episode \(missing ? workload.size : selected).mkv")
            }
            for index in targets.indices {
                guard PlaylistMutation.indexPreservingCurrentIdentity(
                    currentURL: targets[index], fallbackIndex: nil, in: items
                ) == indices[index] else { throw Failure.mismatch("Playlist selection") }
            }
            return Prepared(
                work: { index in
                    UInt64(PlaylistMutation.indexPreservingCurrentIdentity(
                        currentURL: targets[index % 64], fallbackIndex: nil, in: items
                    )! + 1)
                },
                expected: indices.map { UInt64($0 + 1) },
                semantics: items.map { bytes(reference($0.url)) }
            )
        case "deduplicate":
            let unique = (0..<workload.size).map { index in
                FolderPlaylistItem(url: file("/Movies/Episode \(index).mkv"),
                                   dateAdded: Date(timeIntervalSince1970: Double(index)))
            }
            let inputs = workload.id.hasSuffix("-duplicates") ? unique + unique + unique + unique : unique
            guard PlaylistMutation.deduplicated(inputs) == unique else {
                throw Failure.mismatch("First-item metadata/order")
            }
            // Keep the result observable without recomputing its identity keys.
            func receipt(_ result: [FolderPlaylistItem]) -> UInt64 {
                UInt64(result.count) &* 65_537
                    &+ UInt64(result.first?.dateAdded?.timeIntervalSince1970 ?? 0)
                    &+ UInt64(result.last?.dateAdded?.timeIntervalSince1970 ?? 0)
            }
            return Prepared(
                work: { _ in receipt(PlaylistMutation.deduplicated(inputs)) },
                expected: [receipt(unique)], semantics: unique.map { bytes(reference($0.url)) }
            )
        default:
            throw Failure.mismatch("Unknown API")
        }
    }

    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    struct Verification: Encodable {
        let workload: Workload
        let expected: [UInt64]
        let semantics: [[UInt8]?]
    }

    struct Observation: Encodable {
        let workload: Workload
        let iterations: Int
        let elapsedNanoseconds: UInt64
        let nanosecondsPerOperation: Double
        let checksum: UInt64
        let expectedChecksum: UInt64
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--list" {
            try emit(workloads)
            return
        }
        if args.count == 2, args[1] == "--verify" {
            let results = try workloads.map { workload in
                let prepared = try prepare(workload)
                return Verification(workload: workload, expected: prepared.expected,
                                    semantics: prepared.semantics)
            }
            try emit(results)
            return
        }
        guard args.count == 3,
              let workload = workloads.first(where: { $0.id == args[1] }),
              let iterations = Int(args[2]), iterations > 0, iterations <= 10_000_000 else {
            throw Failure.mismatch("Usage: --list | --verify | WORKLOAD ITERATIONS")
        }
        let prepared = try prepare(workload)
        for index in 0..<4 {
            guard prepared.work(index) == prepared.expected[index % prepared.expected.count] else {
                throw Failure.mismatch("Warm-up")
            }
        }
        var expectedChecksum: UInt64 = 0
        for index in 0..<iterations {
            expectedChecksum &+= prepared.expected[index % prepared.expected.count]
        }
        var checksum: UInt64 = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations { checksum &+= prepared.work(index) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        guard checksum == expectedChecksum else { throw Failure.mismatch("Timed result checksum") }
        try emit(Observation(workload: workload, iterations: iterations,
                             elapsedNanoseconds: elapsed,
                             nanosecondsPerOperation: Double(elapsed) / Double(iterations),
                             checksum: checksum, expectedChecksum: expectedChecksum))
    }
}
