import IlliquidCore
import IlliquidPlaybackModel
import Statelessness

/// Applies the production model's step directly, for tests that address
/// envelopes explicitly (sequence and virtual time chosen by the test).
struct ModelStepper {
  var state: PlaybackDomainState

  init(state: PlaybackDomainState = PlaybackDomainState()) { self.state = state }

  mutating func update(_ envelope: PlaybackEventEnvelope) -> PlaybackTransition {
    let transition = PlaybackProductionModel.step(state, envelope)
    state = transition.state
    return transition.outputs[0]
  }
}


/// Application command policy for seeded sequences; randomness comes from the
/// Statelessness SplitMix64 `Rng`.
struct SeededPlaybackGenerator {
  private var rng: Rng

  init(seed: UInt64) { rng = Rng(seed: seed) }

  mutating func next() -> UInt64 { rng.nextU64() }

  mutating func nextCommand(for state: PlaybackDomainState) -> IlliquidPlaybackModel.PlaybackCommand {
    guard state.lifecycle == .running else { return .shutdown }
    guard state.activeSession != nil else {
      return .load(
        source: MediaSourceIdentity(rawValue: "fixture-\(next() % 8)"),
        autoplay: next() % 2 == 0
      )
    }

    switch next() % 7 {
    case 0: return .play
    case 1: return .pause
    case 2:
      let validTime = ValidMediaTime(value: Int64(next() % 300_000), timescale: 1_000)
      return .seek(
        target: validTime.map(MediaTimestamp.valid) ?? .invalid(.zeroTimescale),
        mode: [.relative, .keyframe, .exact, .preview][Int(next() % 4)]
      )
    case 3: return .stop
    case 4:
      return .load(
        source: MediaSourceIdentity(rawValue: "fixture-\(next() % 8)"),
        autoplay: true
      )
    case 5: return .shutdown
    default: return .play
    }
  }

  mutating func shouldMutateResult(percent: UInt64 = 10) -> Bool {
    next() % 100 < percent
  }
}
