import Dispatch
import Foundation
import IlliquidCore
import IlliquidPlayer

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message) }
}

private struct Workload: Encodable {
    let pattern: String
    let count: Int
    var id: String { "\(pattern)/\(count)" }

    enum CodingKeys: String, CodingKey { case id, pattern, count }
    func encode(to encoder: Encoder) throws {
        var output = encoder.container(keyedBy: CodingKeys.self)
        try output.encode(id, forKey: .id)
        try output.encode(pattern, forKey: .pattern)
        try output.encode(count, forKey: .count)
    }

    init(pattern: String, count: Int) { self.pattern = pattern; self.count = count }
}

private let ordinaryPatterns = [
    "folder_first", "folder_middle", "folder_last", "folder_missing",
    "standalone_first", "standalone_last", "standalone_missing", "remote",
]
private let specialPatterns = [
    "unicode_folder", "unicode_standalone", "invalid_source", "invalid_items",
    "duplicates_folder", "duplicates_standalone",
]

private func workloads() -> [Workload] {
    ordinaryPatterns.flatMap { pattern in
        [0, 1, 32, 1_000, 10_000].map { Workload(pattern: pattern, count: $0) }
    } + specialPatterns.flatMap { pattern in
        [1, 32, 1_000].map { Workload(pattern: pattern, count: $0) }
    }
}

private struct Fixture {
    let workload: Workload
    let checkpoint: CheckpointBenchmark
    let expectedSource: MediaSource
    let expectedFolder: URL?
    let expectedItems: [FolderPlaylistItem]
    let expectedIndex: Int?
    let expectedIDs: [String]?

    init(_ workload: Workload) throws {
        let pattern = workload.pattern
        let count = workload.count
        try require(count >= 0 && count <= 100_000, "Invalid fixture size")
        try require((ordinaryPatterns + specialPatterns).contains(pattern), "Unknown fixture")
        let unicode = pattern.hasPrefix("unicode_")
        let duplicates = pattern.hasPrefix("duplicates_")
        let unsupportedItems = pattern == "invalid_items"
        let root = unicode ? "/Media/Caf\u{00E9}/\u{65E5}\u{672C}\u{8A9E}/A deliberately long season folder" : "/Media/Series"
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        var input: [FolderPlaylistItem] = []
        var expected: [FolderPlaylistItem] = []
        input.reserveCapacity(count)
        for occurrence in 0..<count {
            let identity = duplicates ? occurrence / 2 : occurrence
            let url = unsupportedItems
                ? URL(string: "https://example.invalid/Series/Episode-\(identity).mkv")!
                : URL(fileURLWithPath: "\(root)/Episode-\(identity).mkv")
            let item = FolderPlaylistItem(
                url: url,
                externalSubtitleURLs: [URL(fileURLWithPath: "/Subtitles/\(occurrence).srt")],
                dateAdded: Date(timeIntervalSince1970: Double(occurrence))
            )
            input.append(item)
            // Independent fixture identities define first-occurrence metadata.
            if !duplicates || occurrence % 2 == 0 { expected.append(item) }
        }
        let standalone = pattern.hasPrefix("standalone_") || pattern.hasSuffix("_standalone")
        let missing = pattern.hasSuffix("_missing")
        let chosenIndex: Int
        if pattern.hasSuffix("_first") { chosenIndex = 0 }
        else if pattern.hasSuffix("_middle") { chosenIndex = count / 2 }
        else { chosenIndex = max(0, count - 1) }
        let identity = duplicates ? chosenIndex / 2 : chosenIndex
        let localTarget = URL(fileURLWithPath: "\(root)/Episode-\(identity).mkv")
        let source: MediaSource
        if pattern == "remote" {
            source = .remoteStream(URL(string: "https://example.invalid/live.m3u8")!)
        } else if pattern == "invalid_source" {
            source = .localFile(URL(string: "file://archive.invalid/Series/Episode-\(identity).mkv")!)
        } else if missing || count == 0 {
            source = .localFile(URL(fileURLWithPath: "\(root)/Missing.mkv"))
        } else if unicode {
            // The source spelling remains raw; item construction uses NFC.
            let decomposed = root.decomposedStringWithCanonicalMapping
            source = .localFile(URL(fileURLWithPath: "\(decomposed)/Transient/../Episode-\(identity).mkv"))
        } else {
            source = .localFile(localTarget)
        }
        if unicode && count > 0 {
            try require(source.url.absoluteString != input[chosenIndex].url.absoluteString,
                        "Unicode fixture lost its raw alias spelling")
            try require(NormalizedFileURL.persistenceKey(for: source.url)
                        == NormalizedFileURL.persistenceKey(for: input[chosenIndex].url),
                        "Unicode fixture identities must agree")
        }
        let matches = count > 0 && !missing && !unsupportedItems
            && pattern != "remote" && pattern != "invalid_source"
        let savedIDs: [String]? = count == 0 ? nil : expected.reversed().map(\.id)
        self.workload = workload
        expectedSource = source
        expectedFolder = !standalone && matches ? folder : nil
        expectedItems = expected
        expectedIndex = count == 0 ? nil : chosenIndex
        expectedIDs = savedIDs
        checkpoint = CheckpointBenchmark(
            source: source, folder: standalone ? nil : folder, playlist: input,
            index: expectedIndex, position: 73.5, wasPaused: true,
            unshuffledPlaylistIDs: savedIDs
        )
    }

    func verifiedRecord() throws -> PlaybackSessionRecord {
        let before = Date()
        var record = checkpoint.record()
        let after = Date()
        try require(record.updatedAt >= before && record.updatedAt <= after, "Timestamp outside call bounds")
        try require(record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion, "Schema mismatch")
        try require(record.source == expectedSource, "Source mismatch")
        try require(record.source.url.absoluteString == expectedSource.url.absoluteString, "Source bytes differ")
        try require(record.collectionFolder == expectedFolder, "Folder mismatch: \(workload.id)")
        try require(record.playlistItems == expectedItems, "Playlist or metadata mismatch")
        try require(record.playlistIndex == expectedIndex, "Index mismatch")
        try require(record.unshuffledPlaylistIDs == expectedIDs, "Saved order mismatch")
        try require(record.position == 73.5 && record.wasPaused, "Playback fields differ")
        // Only wall-clock sampling is nondeterministic; serialization below
        // compares every other field and exact URL/Unicode representation.
        record.updatedAt = Date(timeIntervalSince1970: 0)
        return record
    }
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func fingerprint(_ bytes: Data) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(value, radix: 16)
}

private func cpuNanoseconds() -> UInt64 {
    var now = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &now) == 0)
    return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
}

@inline(never)
private func consume(_ fixture: Fixture) -> UInt64 {
    func operation() -> UInt64 {
        let record = fixture.checkpoint.record()
        return UInt64(record.playlistItems.count) &+ UInt64(record.collectionFolder == nil ? 0 : 1)
            &+ UInt64(record.playlistIndex ?? 0) &+ record.position.bitPattern
    }
    #if canImport(Darwin)
    return autoreleasepool(invoking: operation)
    #else
    return operation()
    #endif
}

private struct Observation: Encodable {
    let pattern: String
    let count: Int
    let iterations: Int
    let wall_ns: UInt64
    let cpu_ns: UInt64
    let checksum: String
    let semantic_checksum: String
    let expected_count: Int
    let has_folder: Bool
}

private struct Verification: Encodable {
    let id: String
    let record: PlaybackSessionRecord
}

@main
enum Driver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "list":
            print(String(decoding: try encoded(workloads()), as: UTF8.self))
        case "verify":
            for workload in workloads() {
                let fixture = try Fixture(workload)
                let result = Verification(id: workload.id, record: try fixture.verifiedRecord())
                print(String(decoding: try encoded(result), as: UTF8.self))
            }
        case "measure":
            guard args.count == 4, let count = Int(args[2]), let iterations = Int(args[3]),
                  iterations > 0 && iterations <= 10_000_000 else {
                throw Failure("measure PATTERN COUNT ITERATIONS")
            }
            let fixture = try Fixture(Workload(pattern: args[1], count: count))
            let semantic = fingerprint(try encoded(fixture.verifiedRecord()))
            let expected = UInt64(fixture.expectedItems.count)
                &+ UInt64(fixture.expectedFolder == nil ? 0 : 1)
                &+ UInt64(fixture.expectedIndex ?? 0) &+ Double(73.5).bitPattern
            for _ in 0..<2 { try require(consume(fixture) == expected, "Warmup checksum mismatch") }
            var checksum: UInt64 = 0
            let cpuStart = cpuNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum &+= consume(fixture) }
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = cpuNanoseconds() - cpuStart
            try require(checksum == expected &* UInt64(iterations), "Measurement checksum mismatch")
            let finalSemantic = fingerprint(try encoded(fixture.verifiedRecord()))
            try require(finalSemantic == semantic, "Complete checkpoint changed after measurement")
            let result = Observation(
                pattern: args[1], count: count, iterations: iterations,
                wall_ns: wall, cpu_ns: cpu, checksum: String(checksum, radix: 16),
                semantic_checksum: semantic, expected_count: fixture.expectedItems.count,
                has_folder: fixture.expectedFolder != nil
            )
            print(String(decoding: try encoded(result), as: UTF8.self))
        default:
            throw Failure("Expected list, verify, or measure")
        }
    }
}
