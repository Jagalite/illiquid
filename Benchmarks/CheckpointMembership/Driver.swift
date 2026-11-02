import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidPlayer

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private let fixedDate = Date(timeIntervalSince1970: 1_234)
private let folder = URL(fileURLWithPath: "/Performance Library/Season 01", isDirectory: true)
private let workloadNames = [
    "valid-32-first", "valid-32-middle", "valid-32-last",
    "valid-1000-first", "valid-1000-middle", "valid-1000-last",
    "valid-10000-first", "valid-10000-middle", "valid-10000-last",
    "nil-index-1000", "nil-index-10000", "stale-index-1000", "stale-first-32", "absent-source-1000",
    "no-folder-1000", "no-folder-10000", "remote-1000", "empty", "single-valid", "single-absent",
    "unsupported-only-1", "unsupported-only-32", "unsupported-unicode-1",
    "invalid-source-unsupported-32", "invalid-source-unsupported-1000", "invalid-source-unicode-1",
]

private struct Fixture {
    let name: String
    let checkpoint: PlaybackCheckpoint
    let expectedItems: [FolderPlaylistItem]
    let expectedFolder: URL?
    let expectedPosition: Double

    init(_ name: String, source: MediaSource, items: [FolderPlaylistItem],
         index: Int?, belongs: Bool, collection: URL? = folder,
         expectedItems: [FolderPlaylistItem]? = nil, position: Double = 42.25,
         expectedPosition: Double = 42.25, paused: Bool = true, unshuffled: [String]? = nil) {
        self.name = name
        checkpoint = PlaybackCheckpoint(source: source, folder: collection, playlist: items,
            index: index, position: position, wasPaused: paused, unshuffledPlaylistIDs: unshuffled)
        self.expectedItems = expectedItems ?? items
        expectedFolder = belongs ? collection : nil
        self.expectedPosition = expectedPosition
    }
}

private func item(_ identity: Int, occurrence: Int? = nil) -> FolderPlaylistItem {
    let occurrence = occurrence ?? identity
    return FolderPlaylistItem(
        url: folder.appendingPathComponent("Episode \(identity).mkv"),
        externalSubtitleURLs: occurrence.isMultiple(of: 7)
            ? [folder.appendingPathComponent("Episode \(identity)-\(occurrence).en.srt")] : [],
        dateAdded: Date(timeIntervalSince1970: 946_684_800 + Double(occurrence) * 61))
}

private func workload(_ name: String) throws -> Fixture {
    guard workloadNames.contains(name) else { throw ProbeError("Unknown workload: \(name)") }
    if name == "empty" {
        return Fixture(name, source: .localFile(item(0).url), items: [], index: nil, belongs: false)
    }
    if name.hasPrefix("single-") {
        let entry = item(0)
        return Fixture(name, source: .localFile(name == "single-valid" ? entry.url : item(1).url),
            items: [entry], index: 0, belongs: name == "single-valid")
    }
    if name.hasPrefix("invalid-source-") {
        let count = Int(name.split(separator: "-").last!)!
        let sourceURL = URL(string: "file://other-host/Performance%20Library/Season%2001/Episode%200.mkv")!
        let entries: [FolderPlaylistItem]
        if name == "invalid-source-unicode-1" {
            // Preserve raw lexical and Unicode work through the decoded-item
            // path. The source's unsupported authority cannot match this item.
            let localURL = URL(fileURLWithPath:
                "/Volumes/Media/日本語のシリーズ/Season 01/../Season 02/Cafe\u{301} – 第十二話 1080p.mkv")
            entries = [try decodedItem(localURL, date: 1_234)]
        } else {
            entries = (0..<count).map { index in
                FolderPlaylistItem(
                    url: URL(string: "https://example.invalid/Episode%20\(index).mkv")!,
                    dateAdded: Date(timeIntervalSince1970: Double(index)))
            }
        }
        return Fixture(name, source: .localFile(sourceURL), items: entries,
            index: count - 1, belongs: false)
    }
    if name.hasPrefix("unsupported-") {
        let count = Int(name.split(separator: "-").last!)!
        let entries = (0..<count).map { index in
            FolderPlaylistItem(
                url: URL(string: "https://example.invalid/Episode%20\(index).mkv")!,
                dateAdded: Date(timeIntervalSince1970: Double(index)))
        }
        // Deliberately keep the valid local source's lexical and Unicode work
        // nontrivial. No playlist URL can establish local-file membership.
        let sourceURL = name == "unsupported-unicode-1"
            ? URL(fileURLWithPath: "/Volumes/Media/日本語のシリーズ/Season 01/../Season 02/Cafe\u{301} – 第十二話 1080p.mkv")
            : item(0).url
        return Fixture(name, source: .localFile(sourceURL), items: entries,
            index: count - 1, belongs: false)
    }
    let parts = name.split(separator: "-")
    let count: Int
    if name.hasPrefix("valid-") { count = Int(parts[1])! }
    else { count = Int(parts.last!)! }
    let items = (0..<count).map { item($0) }
    if name.hasPrefix("valid-") {
        let index = parts.last == "first" ? 0 : (parts.last == "middle" ? count / 2 : count - 1)
        return Fixture(name, source: .localFile(items[index].url), items: items, index: index, belongs: true)
    }
    if name.hasPrefix("nil-index-") {
        return Fixture(name, source: .localFile(items.last!.url), items: items, index: nil, belongs: true)
    }
    if name == "stale-index-1000" {
        return Fixture(name, source: .localFile(items.last!.url), items: items, index: 0, belongs: true)
    }
    if name == "stale-first-32" {
        return Fixture(name, source: .localFile(items[0].url), items: items, index: count - 1, belongs: true)
    }
    if name == "absent-source-1000" {
        return Fixture(name, source: .localFile(item(count + 1).url), items: items,
            index: count / 2, belongs: false)
    }
    if name.hasPrefix("no-folder-") {
        return Fixture(name, source: .localFile(items.last!.url), items: items,
            index: count - 1, belongs: true, collection: nil)
    }
    return Fixture(name, source: .remoteStream(URL(string: "https://example.invalid/video.m3u8")!),
        items: items, index: count / 2, belongs: false)
}

// Codable construction deliberately bypasses FolderPlaylistItem's normalizing
// initializer, as restored session data can do. The original URL/subtitle bytes
// and first duplicate's metadata must survive checkpoint construction.
private struct RawItem: Encodable {
    let url: URL
    let externalSubtitleURLs: [URL]
    let dateAdded: Date?
}

private func decodedItem(_ url: URL, subtitles: [URL] = [], date: Double = 10) throws -> FolderPlaylistItem {
    try JSONDecoder().decode(FolderPlaylistItem.self,
        from: JSONEncoder().encode(RawItem(url: url, externalSubtitleURLs: subtitles,
            dateAdded: Date(timeIntervalSince1970: date))))
}

private struct Generator {
    var state: UInt64 = 0x793C_F24A_928B_164D
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 16) % UInt64(upperBound))
    }
}

private func verificationFixtures() throws -> [Fixture] {
    var result = try workloadNames.map(workload)
    let ordinary = (0..<5).map { item($0) }
    for index in [nil, -1, Int.min, 5, Int.max] as [Int?] {
        result.append(Fixture("index-\(index.map(String.init) ?? "nil")", source: .localFile(ordinary[3].url),
            items: ordinary, index: index, belongs: true))
    }
    let remote = URL(string: "https://example.invalid/Episode%203.mkv")!
    let foreign = URL(string: "file://other-host/Performance%20Library/Season%2001/Episode%203.mkv")!
    let credentialed = URL(string: "file://user:password@localhost/Performance%20Library/Season%2001/Episode%203.mkv")!
    let ported = URL(string: "file://localhost:99/Performance%20Library/Season%2001/Episode%203.mkv")!
    for (label, url) in [("http", remote), ("foreign", foreign), ("credentials", credentialed), ("port", ported)] {
        result.append(Fixture("unsupported-source-\(label)", source: .localFile(url),
            items: ordinary, index: 3, belongs: false))
        let invalid = try decodedItem(url)
        result.append(Fixture("unsupported-hint-\(label)", source: .localFile(ordinary[3].url),
            items: [invalid, ordinary[3]], index: 0, belongs: true))
        result.append(Fixture("unsupported-only-\(label)", source: .localFile(ordinary[3].url),
            items: [invalid], index: 0, belongs: false))
    }
    result.append(Fixture("remote-enum-file-url", source: .remoteStream(ordinary[3].url),
        items: ordinary, index: 3, belongs: true))
    result.append(Fixture("folder-representation-preserved", source: .localFile(ordinary[3].url),
        items: ordinary, index: 3, belongs: true, collection: remote))
    let localhost = URL(string: "file://localhost/Performance%20Library/Season%2001/Episode%203.mkv")!
    result.append(Fixture("localhost-alias", source: .localFile(localhost),
        items: ordinary, index: 3, belongs: true))
    let relative = URL(string: "../Episode%203.mkv",
        relativeTo: folder.appendingPathComponent("nested", isDirectory: true))!
    result.append(Fixture("relative-source", source: .localFile(relative),
        items: ordinary, index: 3, belongs: true))
    result.append(Fixture("decoded-relative-item", source: .localFile(ordinary[3].url),
        items: [try decodedItem(relative)], index: 0, belongs: true))
    let nfc = URL(string: "file:///Performance%20Library/Caf%C3%A9.mkv")!
    let nfd = URL(string: "file:///Performance%20Library/Cafe%CC%81.mkv")!
    let rawFirst = try decodedItem(nfd, subtitles: [
        URL(string: "file:///Subtitles/z.srt")!, URL(string: "file:///Subtitles/a.srt")!], date: 31)
    let rawLast = try decodedItem(nfc, subtitles: [URL(string: "file:///Subtitles/replaced.srt")!], date: 99)
    result.append(Fixture("unicode-alias", source: .localFile(nfc), items: [rawFirst], index: 0, belongs: true))
    result.append(Fixture("duplicate-hint-metadata", source: .localFile(nfc),
        items: [rawFirst, ordinary[0], rawLast], index: 2, belongs: true,
        expectedItems: [rawFirst, ordinary[0]],
        unshuffled: ["Cafe\u{301}", "Caf\u{e9}", "missing", "Cafe\u{301}"]))
    let withQuery = URL(string: "file:///Performance%20Library/Season%2001/Episode%203.mkv?edition=1#chapter")!
    result.append(Fixture("file-query-fragment", source: .localFile(withQuery),
        items: ordinary, index: 3, belongs: true))
    for (label, value) in [("negative", -10.0), ("nan", Double.nan), ("positive-infinity", Double.infinity),
                           ("negative-infinity", -Double.infinity)] {
        result.append(Fixture("position-\(label)", source: .localFile(ordinary[3].url),
            items: ordinary, index: 3, belongs: true, position: value, expectedPosition: 0))
    }
    // Integer fixture identities supply the membership/deduplication oracle.
    // No production normalizer or membership implementation derives expectations.
    var generator = Generator()
    for sample in 0..<96 {
        let count = [0, 1, 2, 5, 32, 64][sample % 6]
        let identityCount = max(1, count / 3)
        var input: [FolderPlaylistItem] = []
        var expected: [FolderPlaylistItem] = []
        var identities: [Int] = []
        var seen: Set<Int> = []
        for occurrence in 0..<count {
            let identity = generator.next(identityCount)
            let entry = item(identity, occurrence: occurrence + 10_000)
            input.append(entry)
            identities.append(identity)
            if seen.insert(identity).inserted { expected.append(entry) }
        }
        let target = sample.isMultiple(of: 4) ? identityCount + 1 : generator.next(identityCount)
        let isRemote = sample.isMultiple(of: 11)
        let source: MediaSource = isRemote ? .remoteStream(remote) : .localFile(item(target).url)
        let index: Int?
        switch sample % 7 {
        case 0: index = identities.firstIndex(of: target)
        case 1: index = nil
        case 2: index = count > 0 ? generator.next(count) : 0
        case 3: index = -1
        case 4: index = count
        case 5: index = Int.max
        default: index = Int.min
        }
        result.append(Fixture("generated-\(sample)", source: source, items: input, index: index,
            belongs: !isRemote && identities.contains(target), collection: sample.isMultiple(of: 9) ? nil : folder,
            expectedItems: expected, position: Double(sample) * 1.25, expectedPosition: Double(sample) * 1.25,
            paused: sample.isMultiple(of: 2), unshuffled: sample.isMultiple(of: 3) ? ["saved", "saved", "removed"] : nil))
    }
    return result
}

private func utf8(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
private func bits(_ value: Double) -> String { String(value.bitPattern, radix: 16) }

private struct URLReceipt: Codable, Equatable {
    let absoluteUTF8: String
    let relativeUTF8: String
    let baseAbsoluteUTF8: String?
    let baseRelativeUTF8: String?
    init(_ url: URL) {
        absoluteUTF8 = utf8(url.absoluteString)
        relativeUTF8 = utf8(url.relativeString)
        baseAbsoluteUTF8 = url.baseURL.map { utf8($0.absoluteString) }
        baseRelativeUTF8 = url.baseURL.map { utf8($0.relativeString) }
    }
}

private struct SourceReceipt: Codable, Equatable {
    let kind: String
    let url: URLReceipt
    init(_ source: MediaSource) {
        switch source {
        case .localFile: kind = "localFile"
        case .remoteStream: kind = "remoteStream"
        }
        url = URLReceipt(source.url)
    }
}

private struct ItemReceipt: Codable, Equatable {
    let url: URLReceipt
    let subtitleURLs: [URLReceipt]
    let dateAddedBits: String?
    init(_ item: FolderPlaylistItem) {
        url = URLReceipt(item.url)
        subtitleURLs = item.externalSubtitleURLs.map(URLReceipt.init)
        dateAddedBits = item.dateAdded.map { bits($0.timeIntervalSince1970) }
    }
}

private struct RecordReceipt: Codable, Equatable {
    let schemaVersion: Int
    let source: SourceReceipt
    let collectionFolder: URLReceipt?
    let playlistItems: [ItemReceipt]
    let playlistIndex: Int?
    let unshuffledIDsUTF8: [String]?
    let positionBits: String
    let wasPaused: Bool
    let updatedAtBits: String

    init(_ record: PlaybackSessionRecord) {
        schemaVersion = record.schemaVersion
        source = SourceReceipt(record.source)
        collectionFolder = record.collectionFolder.map(URLReceipt.init)
        playlistItems = record.playlistItems.map(ItemReceipt.init)
        playlistIndex = record.playlistIndex
        unshuffledIDsUTF8 = record.unshuffledPlaylistIDs?.map(utf8)
        positionBits = bits(record.position)
        wasPaused = record.wasPaused
        updatedAtBits = bits(record.updatedAt.timeIntervalSince1970)
    }

    init(expected fixture: Fixture) {
        schemaVersion = PlaybackSessionRecord.currentSchemaVersion
        source = SourceReceipt(fixture.checkpoint.source)
        collectionFolder = fixture.expectedFolder.map(URLReceipt.init)
        playlistItems = fixture.expectedItems.map(ItemReceipt.init)
        playlistIndex = fixture.checkpoint.index
        unshuffledIDsUTF8 = fixture.checkpoint.unshuffledPlaylistIDs?.map(utf8)
        positionBits = bits(fixture.expectedPosition)
        wasPaused = fixture.checkpoint.wasPaused
        updatedAtBits = bits(fixedDate.timeIntervalSince1970)
    }
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func fingerprint(_ bytes: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
}

@inline(__always)
private func temporaryPool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

// This separately compiled driver cannot see the production method body. Only
// the original production record() implementation performs membership work.
@inline(never)
private func produce(_ fixture: Fixture) -> PlaybackSessionRecord {
    temporaryPool { fixture.checkpoint.record() }
}

private func verifiedRecord(_ fixture: Fixture) throws -> RecordReceipt {
    let before = Date()
    var record = produce(fixture)
    let after = Date()
    guard record.updatedAt >= before, record.updatedAt <= after else {
        throw ProbeError("\(fixture.name): updatedAt is outside its construction interval")
    }
    // The timestamp is the only nondeterministic field. Check it before fixing
    // the value used by complete byte-preserving differential comparisons.
    record.updatedAt = fixedDate
    let actual = RecordReceipt(record)
    let expected = RecordReceipt(expected: fixture)
    guard actual == expected, try encoded(actual) == encoded(expected) else {
        throw ProbeError("\(fixture.name): complete record differs from independently expected fields")
    }
    return actual
}

private struct VerifiedCase: Encodable {
    let id: String
    let input_count: Int
    let output_count: Int
    let expected_folder: Bool
    let output_fingerprint: String
    let record: RecordReceipt
}

private struct Verification: Encodable {
    let schema = 1
    let count: Int
    let timestamp_bounds_checked = true
    let cases: [VerifiedCase]
}

private func verify() throws -> Verification {
    var cases: [VerifiedCase] = []
    for fixture in try verificationFixtures() {
        let receipt = try temporaryPool { try verifiedRecord(fixture) }
        cases.append(VerifiedCase(id: fixture.name, input_count: fixture.checkpoint.playlist.count,
            output_count: fixture.expectedItems.count, expected_folder: fixture.expectedFolder != nil,
            output_fingerprint: fingerprint(try encoded(receipt)), record: receipt))
    }
    return Verification(count: cases.count, cases: cases)
}

// Bounded output consumption keeps every record observable without adding a
// second full playlist traversal to the measured operation. Complete fields,
// including all middle items and URL bytes, are checked before/after timing.
@inline(__always)
private func consume(_ record: PlaybackSessionRecord, fixture: Fixture) throws -> UInt64 {
    guard record.schemaVersion == PlaybackSessionRecord.currentSchemaVersion,
          record.source == fixture.checkpoint.source,
          record.collectionFolder == fixture.expectedFolder,
          record.playlistItems.count == fixture.expectedItems.count,
          record.playlistIndex == fixture.checkpoint.index,
          record.position.bitPattern == fixture.expectedPosition.bitPattern,
          record.wasPaused == fixture.checkpoint.wasPaused,
          record.unshuffledPlaylistIDs?.count == fixture.checkpoint.unshuffledPlaylistIDs?.count else {
        throw ProbeError("\(fixture.name): timed output scalar fields changed")
    }
    let first = record.playlistItems.first?.dateAdded?.timeIntervalSince1970.bitPattern ?? 0
    let last = record.playlistItems.last?.dateAdded?.timeIntervalSince1970.bitPattern ?? 0
    let index = record.playlistIndex.map { UInt64(bitPattern: Int64($0)) } ?? 0xFFFF_FFFF_FFFF_FFFF
    return UInt64(record.playlistItems.count) &* 0x9E37_79B9_7F4A_7C15
        ^ record.position.bitPattern ^ index ^ first ^ (last &* 31)
        ^ (record.collectionFolder == nil ? 0 : 127) ^ (record.source.isRemote ? 1021 : 0)
        ^ (record.wasPaused ? 65_521 : 0)
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
        throw ProbeError("clock_gettime(CLOCK_PROCESS_CPUTIME_ID) failed")
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private struct Measurement: Encodable {
    let schema = 1
    let `case`: String
    let iterations: Int
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: String
    let warmup_checksum: String
    let output_fingerprint: String
    let expected_fingerprint: String
    let input_count: Int
    let output_count: Int
    let validated = true
    let warmup_iterations = 8
}

private func bench(_ name: String, iterations: Int) throws -> Measurement {
    guard iterations > 0 else { throw ProbeError("iterations must be positive") }
    let fixture = try workload(name)
    let before = try temporaryPool { try verifiedRecord(fixture) }
    let expectedFingerprint = fingerprint(try encoded(RecordReceipt(expected: fixture)))
    let expectedPiece = try consume(produce(fixture), fixture: fixture)
    var warmup: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<8 { warmup = (warmup ^ (try consume(produce(fixture), fixture: fixture))) &* 1_099_511_628_211 }
    var checksum: UInt64 = 14_695_981_039_346_656_037
    let cpuStart = try cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        checksum = (checksum ^ (try consume(produce(fixture), fixture: fixture))) &* 1_099_511_628_211
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = try cpuNanoseconds() - cpuStart
    var expectedChecksum: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<iterations { expectedChecksum = (expectedChecksum ^ expectedPiece) &* 1_099_511_628_211 }
    let after = try temporaryPool { try verifiedRecord(fixture) }
    guard before == after, checksum == expectedChecksum else {
        throw ProbeError("\(name): timed checksum or complete post-measurement output differs")
    }
    let outputFingerprint = fingerprint(try encoded(after))
    guard outputFingerprint == expectedFingerprint else { throw ProbeError("Output fingerprint mismatch") }
    return Measurement(case: name, iterations: iterations, elapsed_ns: elapsed, cpu_ns: cpu,
        checksum: String(checksum, radix: 16), warmup_checksum: String(warmup, radix: 16),
        output_fingerprint: outputFingerprint, expected_fingerprint: expectedFingerprint,
        input_count: fixture.checkpoint.playlist.count, output_count: fixture.expectedItems.count)
}

@main
private enum Main {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let output: Data
            if args == ["cases"] || args == ["--list"] { output = try encoded(workloadNames) }
            else if args == ["verify"] { output = try encoded(verify()) }
            else if args.count == 3, args[0] == "bench", let iterations = Int(args[2]) {
                output = try encoded(bench(args[1], iterations: iterations))
            } else { throw ProbeError("Usage: driver cases | --list | verify | bench CASE ITERATIONS") }
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
