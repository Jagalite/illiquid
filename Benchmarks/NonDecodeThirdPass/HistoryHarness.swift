// Production store/writer/types; only UserDefaults.set observation/blocking is injected.
import Foundation
#if ALLOCATION_METER
@_silgen_name("meter_begin") func meterBegin()
@_silgen_name("meter_end") func meterEnd()
@_silgen_name("meter_requests") func meterRequests() -> UInt64
@_silgen_name("meter_bytes") func meterBytes() -> UInt64
#endif
final class AuditedDefaults: UserDefaults {
    private let gate = NSLock()
    private var sizes: [Int] = []
    private var recording = false
    private var blockNext = false
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func arm(block: Bool) { gate.lock(); recording = true; blockNext = block; sizes = []; gate.unlock() }
    override func set(_ value: Any?, forKey key: String) {
        gate.lock()
        let observe = recording && key.hasSuffix("playback-state.v1")
        let block = observe && blockNext
        if block { blockNext = false }
        gate.unlock()
        if block { started.signal(); precondition(release.wait(timeout: .now() + 60) == .success) }
        super.set(value, forKey: key)
        if observe { gate.lock(); sizes.append((value as? Data)?.count ?? 0); gate.unlock() }
    }
    func receipt() -> [Int] { gate.lock(); defer { gate.unlock() }; return sizes }
}
@main struct Main {
    static func main() throws {
        let a = CommandLine.arguments
        guard a.count == 4, let count = Int(a[1]), count > 0, let updates = Int(a[2]), updates > 0 else {
            fatalError("usage: history COUNT UPDATES MODE")
        }
        let mode = a[3], repeated = mode.hasPrefix("repeat"), blocked = mode.hasSuffix("blocked"), flushed = mode.hasSuffix("flushed")
        let suite = "com.example.IlliquidHistoryV3.\(UUID().uuidString)"
        let defaults = AuditedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "Illiquid.playback-state.v1"
        do {
            struct Seed: Encodable { let playbackPositions: [String: Double]; let playbackDurations: [String: Double] }
            var p: [String: Double] = [:], d: [String: Double] = [:]
            for i in 0..<count { let path = "/synthetic/library/episode-\(i).mkv"; p[path] = Double(i % 400); d[path] = 3600 }
            defaults.set(try JSONEncoder().encode(Seed(playbackPositions: p, playbackDurations: d)), forKey: key)
        }
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        let url = URL(fileURLWithPath: "/synthetic/library/episode-0.mkv")
        store.setPlaybackProgress(position: 10, duration: 3600, for: url)
        store.flushSynchronously() // identical canonical starting state and warmed code path
        defaults.arm(block: blocked)
        if blocked {
            store.setPlaybackProgress(position: 11, duration: 3600, for: url)
            precondition(defaults.started.wait(timeout: .now() + 60) == .success)
        }
        var elapsed: [UInt64] = []; elapsed.reserveCapacity(updates)
        let start = DispatchTime.now().uptimeNanoseconds
        #if ALLOCATION_METER
        meterBegin()
        #endif
        for i in 0..<updates {
            let t = DispatchTime.now().uptimeNanoseconds
            let position = repeated ? (blocked ? 11.0 : 10.0) : Double(i + 12)
            store.setPlaybackProgress(position: position, duration: 3600, for: url)
            elapsed.append(DispatchTime.now().uptimeNanoseconds - t)
            if flushed { store.flushSynchronously() }
        }
        #if ALLOCATION_METER
        meterEnd()
        #endif
        let mutationWall = DispatchTime.now().uptimeNanoseconds - start
        let flushStart = DispatchTime.now().uptimeNanoseconds
        if blocked { defaults.release.signal() }
        store.flushSynchronously()
        let flushNS = DispatchTime.now().uptimeNanoseconds - flushStart
        let operationNS = DispatchTime.now().uptimeNanoseconds - start
        let loaded = PlaybackPersistenceStore(userDefaults: defaults)
        let expected = repeated ? (blocked ? 11.0 : 10.0) : Double(updates + 11)
        precondition(loaded.playbackPosition(for: url) == expected)
        struct Saved: Decodable { let playbackPositions: [String: Double]; let playbackDurations: [String: Double] }
        let data = defaults.data(forKey: key)!
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        precondition(saved.playbackPositions.count == count && saved.playbackDurations.count == count)
        let writes = defaults.receipt()
        var row: [String: Any] = ["count": count, "updates": updates, "mode": mode,
            "mutation_ns": elapsed, "mutation_total_ns": elapsed.reduce(0,+),
            "loop_wall_ns": mutationWall, "operation_ns": operationNS, "flush_ns": flushNS,
            "writes": writes.count, "set_payload_bytes": writes.reduce(0,+), "final_payload_bytes": data.count,
            "restored_position": expected]
        #if ALLOCATION_METER
        row["allocation_requests"] = meterRequests(); row["allocation_request_bytes"] = meterBytes()
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
    }
}
