import Foundation

enum NativeSynchronizationStream: Hashable, Sendable {
    case video
    case audio
}

/// High-frequency native measurement only. Playback policy (rates, buffering
/// transitions, drift escalation) belongs to `SynchronizationMachineState` in
/// the deterministic core.
final class NativeSynchronizationController: @unchecked Sendable {
    private let lock = NSLock()
    private var required: Set<NativeSynchronizationStream>
    private var generation = -1
    private var ready: Set<NativeSynchronizationStream> = []
    private var started = false
    private var buffering = false

    init(hasVideo: Bool, hasAudio: Bool) {
        var required: Set<NativeSynchronizationStream> = []
        if hasVideo { required.insert(.video) }
        if hasAudio { required.insert(.audio) }
        self.required = required
    }

    func beginGeneration(_ generation: Int, videoOnly: Bool = false) {
        lock.withLock {
            self.generation = generation
            ready.removeAll()
            started = false
            buffering = false
            if videoOnly, required.contains(.audio) { ready.insert(.audio) }
        }
    }

    func observePreroll(
        _ stream: NativeSynchronizationStream,
        generation candidate: Int
    ) -> Bool {
        lock.withLock {
            guard candidate == generation, !started else { return false }
            ready.insert(stream)
            guard ready.isSuperset(of: required) else { return false }
            started = true
            return true
        }
    }

    func disable(_ stream: NativeSynchronizationStream) {
        lock.withLock {
            required.remove(stream)
            ready.remove(stream)
        }
    }

    func observeSupply(starved: Bool, cacheSeconds: Double) {
        lock.withLock {
            _ = cacheSeconds
            buffering = starved
        }
    }

    var isBuffering: Bool { lock.withLock { buffering } }
}
