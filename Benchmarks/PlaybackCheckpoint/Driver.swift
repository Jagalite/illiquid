import Dispatch
import Foundation
import IlliquidCore
@testable import IlliquidPlayer

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The production record still reads Date(). Only its output timestamp is fixed
// for exact cross-process receipts. In the encoding scope this assignment is
// included in timing, equally for baseline and candidate.
private let receiptDate = Date(timeIntervalSince1970: 1_700_000_000)

private enum Scope: String, Sendable {
    case record
    case encode
}

private enum Selection: String, Sendable {
    case empty
    case singleton
    case front
    case middle
    case last
    case nilIndex = "nil-index"
    case staleIndex = "stale-index"
    case outOfRange = "out-of-range"
    case absent
    case remote
    case noFolder = "no-folder"
}

private struct Workload: Sendable {
    let scope: Scope
    let selection: Selection
    let count: Int

    var id: String { "\(scope.rawValue)-\(selection.rawValue)-\(count)" }

    static let all: [Workload] = [Scope.record, .encode].flatMap { scope in
        let fixtures: [(Selection, Int)] = [
            (.empty, 0), (.singleton, 1), (.front, 32),
            (.middle, 1_000), (.last, 1_000), (.last, 10_000),
            (.nilIndex, 1_000), (.staleIndex, 1_000), (.outOfRange, 1_000),
            (.absent, 1_000), (.remote, 1_000), (.noFolder, 1_000),
            (.front, 10_000),
        ]
        return fixtures.map { Workload(scope: scope, selection: $0.0, count: $0.1) }
    }
}

private struct PreparedFixture {
    let workload: Workload
    let checkpoint: PlaybackCheckpoint
    let expectedRecord: PlaybackSessionRecord
    let expectedBytes: Data
    let token: UInt64
}

private struct Receipt: Encodable {
    let `case`: String
    let scope: String
    let count: Int
    let selection: String
    let iterations: Int
    let warmup_iterations: Int
    let elapsed_ns: UInt64
    let cpu_ns: UInt64
    let checksum: String
    let token: String
    let output_bytes: Int
    let output_fnv1a: String
    let output_base64: String?
}

private enum DriverError: Error {
    case invalidArguments
    case clockFailure
    case recordMismatch(String)
    case encodingMismatch(String)
    case checksumMismatch(String)
}

@main
private enum CheckpointBenchmark {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments.first {
            case "verify" where arguments.count == 1:
                let receipts = try Workload.all.map { workload in
                    let fixture = try prepare(workload)
                    return receipt(
                        fixture, iterations: 0, warmup: 0, elapsed: 0, cpu: 0,
                        checksum: 0, bytes: fixture.expectedBytes, includeBytes: true
                    )
                }
                try emit(receipts)
            case "measure" where arguments.count == 3:
                guard let workload = Workload.all.first(where: { $0.id == arguments[1] }),
                      let iterations = Int(arguments[2]), iterations > 0,
                      iterations <= 1_000_000 else { throw DriverError.invalidArguments }
                try emit(measure(prepare(workload), iterations: iterations))
            default:
                throw DriverError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("checkpoint benchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func prepare(_ workload: Workload) throws -> PreparedFixture {
        let folder = URL(fileURLWithPath: "/CheckpointBenchmark/Series", isDirectory: true)
        let items = (0..<workload.count).map { index in
            let name = "Episode \(index).mkv"
            let subtitles = index % 16 == 0
                ? [folder.appendingPathComponent("Episode \(index).en.srt"),
                   folder.appendingPathComponent("Episode \(index).fr.srt")]
                : []
            return FolderPlaylistItem(
                url: folder.appendingPathComponent(name),
                externalSubtitleURLs: subtitles,
                dateAdded: Date(timeIntervalSince1970: 1_690_000_000 + Double(index))
            )
        }
        let selected: Int?
        let source: MediaSource
        switch workload.selection {
        case .empty:
            selected = nil
            source = .localFile(folder.appendingPathComponent("Absent.mkv"))
        case .singleton, .front:
            selected = 0
            source = .localFile(items[0].url)
        case .middle:
            selected = items.count / 2
            source = .localFile(items[items.count / 2].url)
        case .last, .noFolder:
            selected = items.count - 1
            source = .localFile(items[items.count - 1].url)
        case .nilIndex:
            selected = nil
            source = .localFile(items[items.count - 1].url)
        case .staleIndex:
            selected = 0
            source = .localFile(items[items.count - 1].url)
        case .outOfRange:
            selected = items.count
            source = .localFile(items[items.count - 1].url)
        case .absent:
            selected = items.count - 1
            source = .localFile(folder.appendingPathComponent("Absent.mkv"))
        case .remote:
            selected = items.count - 1
            source = .remoteStream(URL(string: "https://example.invalid/stream.m3u8")!)
        }
        let checkpoint = PlaybackCheckpoint(
            source: source,
            folder: workload.selection == .noFolder ? nil : folder,
            playlist: items,
            index: selected,
            position: 1_234.5,
            wasPaused: false,
            unshuffledPlaylistIDs: workload.count == 32 ? items.reversed().map(\.id) : nil
        )
        // The oracle uses the original membership predicate and the actual
        // production record initializer. It never changes the measured module.
        let belongs = checkpoint.source.url.isFileURL && checkpoint.playlist.contains {
            NormalizedFileURL.representsSameFile($0.url, checkpoint.source.url)
        }
        let expected = PlaybackSessionRecord(
            source: checkpoint.source,
            collectionFolder: belongs ? checkpoint.folder : nil,
            playlistItems: checkpoint.playlist,
            playlistIndex: checkpoint.index,
            position: checkpoint.position,
            wasPaused: checkpoint.wasPaused,
            unshuffledPlaylistIDs: checkpoint.unshuffledPlaylistIDs,
            updatedAt: receiptDate
        )
        let expectedBytes = try encode(expected)
        var actual = checkpoint.record()
        actual.updatedAt = receiptDate
        guard actual == expected else { throw DriverError.recordMismatch(workload.id) }
        guard try encode(actual) == expectedBytes else {
            throw DriverError.encodingMismatch(workload.id)
        }
        return PreparedFixture(
            workload: workload, checkpoint: checkpoint, expectedRecord: expected,
            expectedBytes: expectedBytes,
            token: workload.scope == .record ? recordToken(expected) : encodedToken(expectedBytes)
        )
    }

    private static func measure(_ fixture: PreparedFixture, iterations: Int) throws -> Receipt {
        let warmup = 2
        var lastRecord = fixture.expectedRecord
        var lastBytes = fixture.expectedBytes
        for _ in 0..<warmup {
            lastRecord = fixture.checkpoint.record()
            if fixture.workload.scope == .encode {
                lastRecord.updatedAt = receiptDate
                lastBytes = try encode(lastRecord)
            }
        }
        var checksum: UInt64 = 0
        let cpuStart = try cpuNanoseconds()
        let start = DispatchTime.now().uptimeNanoseconds
        switch fixture.workload.scope {
        case .record:
            for index in 0..<iterations {
                lastRecord = fixture.checkpoint.record()
                checksum &+= recordToken(lastRecord) &+ UInt64(index) &* 131
            }
        case .encode:
            for index in 0..<iterations {
                lastRecord = fixture.checkpoint.record()
                lastRecord.updatedAt = receiptDate
                // AtomicPlaybackSessionStore creates a new sorted-key encoder
                // for every save. This scope includes that same encoding work,
                // without filesystem writes or the store's lock/directory work.
                lastBytes = try encode(lastRecord)
                checksum &+= encodedToken(lastBytes) &+ UInt64(index) &* 131
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpu = try cpuNanoseconds() - cpuStart

        // Full field and byte checks and hashing happen after both clocks stop.
        // Every timed result was consumed; the final complete value is retained
        // for differential verification, including playlist metadata and order.
        lastRecord.updatedAt = receiptDate
        guard lastRecord == fixture.expectedRecord else {
            throw DriverError.recordMismatch(fixture.workload.id)
        }
        if fixture.workload.scope == .record { lastBytes = try encode(lastRecord) }
        guard lastBytes == fixture.expectedBytes else {
            throw DriverError.encodingMismatch(fixture.workload.id)
        }
        let count = UInt64(iterations)
        let expectedChecksum = fixture.token &* count &+ (count * (count - 1) / 2) &* 131
        guard checksum == expectedChecksum else {
            throw DriverError.checksumMismatch(fixture.workload.id)
        }
        return receipt(
            fixture, iterations: iterations, warmup: warmup,
            elapsed: elapsed, cpu: cpu, checksum: checksum,
            bytes: lastBytes, includeBytes: false
        )
    }

    private static func receipt(
        _ fixture: PreparedFixture, iterations: Int, warmup: Int,
        elapsed: UInt64, cpu: UInt64, checksum: UInt64,
        bytes: Data, includeBytes: Bool
    ) -> Receipt {
        Receipt(
            case: fixture.workload.id, scope: fixture.workload.scope.rawValue,
            count: fixture.workload.count, selection: fixture.workload.selection.rawValue,
            iterations: iterations, warmup_iterations: warmup,
            elapsed_ns: elapsed, cpu_ns: cpu, checksum: String(checksum),
            token: String(fixture.token), output_bytes: bytes.count,
            output_fnv1a: String(fnv1a(bytes)),
            output_base64: includeBytes ? bytes.base64EncodedString() : nil
        )
    }

    private static func encode(_ record: PlaybackSessionRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private static func emit<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

// Keep result consumption observable across the separately compiled module
// boundary without adding an O(n) traversal to each timed record operation.
@inline(never)
private func recordToken(_ record: PlaybackSessionRecord) -> UInt64 {
    var token = UInt64(record.playlistItems.count)
    token = token &* 31 &+ UInt64(bitPattern: Int64(record.playlistIndex ?? -1))
    token = token &* 31 &+ (record.collectionFolder == nil ? 0 : 1)
    token = token &* 31 &+ (record.wasPaused ? 1 : 0)
    return token &* 31 &+ record.position.bitPattern
}

@inline(never)
private func encodedToken(_ bytes: Data) -> UInt64 {
    UInt64(bytes.count) &* 31 &+ UInt64(bytes.first ?? 0) &+ UInt64(bytes.last ?? 0)
}

private func fnv1a(_ bytes: Data) -> UInt64 {
    var result: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes { result = (result ^ UInt64(byte)) &* 1_099_511_628_211 }
    return result
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
        throw DriverError.clockFailure
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}
