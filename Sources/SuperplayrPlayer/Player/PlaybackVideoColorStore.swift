import Observation
import SuperplayrCore

@MainActor
@Observable
public final class PlaybackVideoColorStore {
    public private(set) var sample: VideoColorSample?
    public private(set) var revision: UInt64
    public private(set) var generation: UInt64 = 0

    public init(sample: VideoColorSample? = nil) {
        self.sample = sample
        revision = sample == nil ? 0 : 1
    }

    func publish(_ sample: VideoColorSample) {
        guard self.sample != sample else { return }
        self.sample = sample
        revision &+= 1
    }

    func reset() {
        generation &+= 1
        sample = nil
        revision &+= 1
    }
}
