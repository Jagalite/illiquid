// Exact production persistence store, writer and supporting values, with real
// Foundation JSONEncoder/UserDefaults. Subclass only counts/blocks set calls.
import Foundation

final class ObservedDefaults: UserDefaults {
    private let auditLock = NSLock()
    private var recording = false
    private var blockNext = false
    private var sizes: [Int] = []
    let writeStarted = DispatchSemaphore(value: 0)
    let releaseWrite = DispatchSemaphore(value: 0)
    func arm(block: Bool) { auditLock.lock(); recording = true; blockNext = block; sizes = []; auditLock.unlock() }
    override func set(_ value: Any?, forKey key: String) {
        auditLock.lock()
        let observe = recording && key.hasSuffix("playback-state.v1")
        let block = observe && blockNext
        if block { blockNext = false }
        auditLock.unlock()
        if block {
            writeStarted.signal()
            precondition(releaseWrite.wait(timeout: .now() + 60) == .success, "write gate timed out")
        }
        super.set(value, forKey: key)
        if observe { auditLock.lock(); sizes.append((value as? Data)?.count ?? 0); auditLock.unlock() }
    }
    func receipt() -> [Int] { auditLock.lock(); defer { auditLock.unlock() }; return sizes }
}
@main struct Main {
    static func main() throws {
        let args = CommandLine.arguments
        let count = Int(args[1])!, updates = Int(args[2])!, mode = args[3]
        let suite = "com.example.IlliquidResearch.\(UUID().uuidString)"
        let defaults = ObservedDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "Illiquid.playback-state.v1"
        // Seeding is deliberately outside timing and does not submit N writes.
        do {
            var positions: [String: Double] = [:], durations: [String: Double] = [:]
            for i in 0..<count {
                let key = "/synthetic/library/episode-\(i).mkv"
                positions[key] = Double(i % 400); durations[key] = 3_600
            }
            struct Seed: Encodable {
                let playbackPositions: [String: Double]
                let playbackDurations: [String: Double]
            }
            let data = try JSONEncoder().encode(Seed(playbackPositions: positions, playbackDurations: durations))
            defaults.set(data, forKey: storageKey)
        }
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let store = PlaybackPersistenceStore(userDefaults: defaults)
        let loadNS = DispatchTime.now().uptimeNanoseconds - loadStart
        precondition(!store.hasUnreadableHistory)
        let url = URL(fileURLWithPath: "/synthetic/library/episode-0.mkv")
        // Warm path normalization before timing, without retaining a state copy.
        _ = store.playbackProgress(for: url)
        defaults.arm(block: mode == "blocked")
        if mode == "blocked" {
            store.setPlaybackProgress(position: 1, duration: 3_600, for: url)
            precondition(defaults.writeStarted.wait(timeout: .now() + 60) == .success)
        }
        var elapsed: [UInt64] = []; elapsed.reserveCapacity(updates)
        var intermediateFlushNS: [UInt64] = []
        let operationStart = DispatchTime.now().uptimeNanoseconds
        for i in 1...updates {
            let start = DispatchTime.now().uptimeNanoseconds
            store.setPlaybackProgress(position: Double(i + 10), duration: 3_600, for: url)
            elapsed.append(DispatchTime.now().uptimeNanoseconds - start)
            if mode == "flushed" {
                let start = DispatchTime.now().uptimeNanoseconds
                store.flushSynchronously()
                intermediateFlushNS.append(DispatchTime.now().uptimeNanoseconds - start)
            }
        }
        let flushStart = DispatchTime.now().uptimeNanoseconds
        if mode == "blocked" { defaults.releaseWrite.signal() }
        store.flushSynchronously()
        let flushNS = DispatchTime.now().uptimeNanoseconds - flushStart
        let operationNS = DispatchTime.now().uptimeNanoseconds - operationStart
        let restored = PlaybackPersistenceStore(userDefaults: defaults)
        precondition(restored.playbackPosition(for: url) == Double(updates + 10))
        let data = defaults.data(forKey: storageKey)!
        struct Saved: Decodable { let playbackPositions: [String: Double] }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        precondition(saved.playbackPositions.count == count)
        let writes = defaults.receipt()
        let out: [String: Any] = [
            "count": count, "updates": updates, "mode": mode, "load_ns": loadNS,
            "mutation_ns": elapsed, "mutation_total_ns": elapsed.reduce(0,+),
            "flush_ns": flushNS, "operation_ns": operationNS,
            "intermediate_flush_ns": intermediateFlushNS, "writes": writes.count, "set_payload_bytes": writes.reduce(0,+),
            "final_payload_bytes": data.count, "restored_position": Double(updates + 10)
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), as: UTF8.self))
    }
}
