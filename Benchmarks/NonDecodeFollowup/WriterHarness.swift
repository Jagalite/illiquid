// Measures the exact production writer with the store's locking/mutation pattern.
// This kernel is NOT the complete PlaybackPersistenceStore or a macOS app test.
import Foundation
#if ALLOCATION_METER
@_silgen_name("meter_begin") func meterBegin()
@_silgen_name("meter_end") func meterEnd()
@_silgen_name("meter_requests") func meterRequests() -> UInt64
@_silgen_name("meter_bytes") func meterBytes() -> UInt64
#endif

final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var revisions: [Int] = []
    var encodedBytes = 0
    var encodeNS: UInt64 = 0
    var snapshots = 0
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var block = false
    func record(_ history: History) throws {
        lock.lock(); let shouldBlock = block; block = false; lock.unlock()
        if shouldBlock {
            started.signal()
            precondition(release.wait(timeout: .now() + 30) == .success, "blocked writer timeout")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let data = try JSONEncoder().encode(history)
        let ns = DispatchTime.now().uptimeNanoseconds - start
        lock.lock(); defer { lock.unlock() }
        revisions.append(history.revision); encodedBytes += data.count; encodeNS += ns
    }
    func captured() { lock.lock(); snapshots += 1; lock.unlock() }
}
struct History: Codable, Sendable {
    var positions: [String: Double] = [:]
    var durations: [String: Double] = [:]
    var revision = 0
}
final class Owner: @unchecked Sendable {
    let lock = NSLock()
    var state = History()
    let writer: CoalescingPersistenceWriter<History>
    let recorder: Recorder
    init(count: Int, delay: Double, recorder: Recorder) {
        self.recorder = recorder
        writer = CoalescingPersistenceWriter(label: "benchmark.history", delay: delay) { try recorder.record($0) }
        for n in 0..<count {
            let key = "/synthetic/library/show/episode-\(n).mkv"
            state.positions[key] = Double(n % 400)
            state.durations[key] = 3_600
        }
    }
    func update(_ revision: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = "/synthetic/library/show/episode-0.mkv"
        state.positions[key] = Double(revision)
        state.durations[key] = 3_600 // Same duration assignment, as in production.
        state.revision = revision
        #if CANDIDATE
        writer.submitSnapshot { [self] in
            lock.lock(); defer { lock.unlock() }
            recorder.captured()
            return state
        }
        #else
        recorder.captured()
        writer.submit(state)
        #endif
    }
}
@main struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        let count = Int(args[1])!, updates = Int(args[2])!, mode = args[3]
        let recorder = Recorder()
        recorder.block = mode == "blocked"
        let owner = Owner(count: count, delay: mode == "blocked" ? 0 : 60, recorder: recorder)
        owner.update(0)
        if mode == "blocked" {
            precondition(recorder.started.wait(timeout: .now() + 30) == .success)
        }
        var elapsed: [UInt64] = []; elapsed.reserveCapacity(updates)
        #if ALLOCATION_METER
        meterBegin()
        #endif
        for i in 1...updates {
            let start = DispatchTime.now().uptimeNanoseconds
            owner.update(i)
            elapsed.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        #if ALLOCATION_METER
        meterEnd()
        let requests = meterRequests(), bytes = meterBytes()
        #endif
        let flushStart = DispatchTime.now().uptimeNanoseconds
        if mode == "blocked" { recorder.release.signal() }
        try owner.writer.flushSynchronously().get()
        let flushNS = DispatchTime.now().uptimeNanoseconds - flushStart
        precondition(recorder.revisions.last == updates)
        var out: [String: Any] = [
            "count": count, "updates": updates, "mode": mode,
            "mutation_ns": elapsed, "mutation_total_ns": elapsed.reduce(0,+),
            "flush_ns": flushNS, "encode_ns": recorder.encodeNS,
            "writes": recorder.revisions.count, "revisions": recorder.revisions,
            "snapshot_captures": recorder.snapshots, "encoded_bytes": recorder.encodedBytes
        ]
        #if ALLOCATION_METER
        out["allocation_requests"] = requests; out["allocation_request_bytes"] = bytes
        #else
        out["allocation_instrumented"] = false
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}
