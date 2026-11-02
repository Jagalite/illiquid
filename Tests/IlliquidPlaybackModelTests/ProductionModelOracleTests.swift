import CryptoKit
import Foundation
import IlliquidCore
import IlliquidPlaybackModel
import Statelessness
import Testing

// Production migration differential oracle, executed against the production
// model. The generator and fixture are those recorded from the legacy core in
// P0 (see Tests/IlliquidPlaybackStateSpaceTests at that revision).
//
// Deterministic concrete event streams are generated from a seed and from the
// effects each transition emits, never from engine internals. The fixture was
// recorded from the legacy `PlaybackCore` before the production model existed;
// every later engine must reproduce each step's envelope, transition and
// post-state bytes. Do not re-record it from a new engine to hide a difference.

/// One production transition function under test.
typealias ProductionOracleStep = (PlaybackDomainState, PlaybackEventEnvelope) -> (
  PlaybackDomainState, PlaybackTransition
)

enum ProductionOracleEngine {
  /// The model's step callback, without a session.
  static func step(_ state: PlaybackDomainState, _ envelope: PlaybackEventEnvelope) -> (
    PlaybackDomainState, PlaybackTransition
  ) {
    let transition = PlaybackProductionModel.step(state, envelope)
    return (transition.state, transition.outputs[0])
  }
}

/// Streams executed by a persistent Statelessness session, as in production.
final class ProductionOracleSessionEngine {
  private var session: PlaybackSession?

  func step(_ state: PlaybackDomainState, _ envelope: PlaybackEventEnvelope) -> (
    PlaybackDomainState, PlaybackTransition
  ) {
    do {
      if session == nil { session = try PlaybackProductionModel.session(state: state) }
      let turn = try session!.submit(envelope)
      return (try session!.snapshot(), turn.outputs[0])
    } catch {
      fatalError("session fault: \(error)")
    }
  }
}

/// Generates envelopes from a seed and observed effects only.
struct ProductionOracleStream {
  private var rng: UInt64
  private(set) var sequence: UInt64
  private(set) var time: UInt64
  private var outstanding: [PlaybackEffect] = []
  private var phase: [PlaybackEffectID: Int] = [:]
  private var completed: [PlaybackEffectResult] = []
  private var history: [PlaybackEffect] = []

  init(seed: UInt64, state: PlaybackDomainState) {
    rng = seed
    sequence = 1
    time = state.lastVirtualTime.ticks
    outstanding = state.outstandingEffects.values.map(\.effect)
      .sorted { $0.context.effectID < $1.context.effectID }
    history = outstanding
  }

  private mutating func next() -> UInt64 {
    rng &+= 0x9E37_79B9_7F4A_7C15
    var z = rng
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  private mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  private mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
  private mutating func chance(_ percent: Int) -> Bool { below(100) < percent }

  mutating func observe(_ transition: PlaybackTransition) {
    for effect in transition.effects {
      history.append(effect)
      if effect.completion != .bestEffortMirror { outstanding.append(effect) }
    }
    if history.count > 64 { history.removeFirst(history.count - 64) }
  }

  mutating func nextEnvelope() -> PlaybackEventEnvelope {
    let event = nextEvent()
    if chance(2), time > 0 {
      time -= 1  // virtual time regression
    } else {
      time += UInt64(1 + below(3))
    }
    let envelope = PlaybackEventEnvelope(
      sequence: sequence, virtualTime: PlaybackInstant(ticks: time), event: event)
    sequence += 1
    return envelope
  }

  private mutating func nextEvent() -> PlaybackEvent {
    let roll = below(100)
    if roll < 42, !outstanding.isEmpty { return result() }
    if roll < 47, !completed.isEmpty { return .effectResult(pick(completed)) }
    if roll < 51, !history.isEmpty { return staleResult() }
    if roll < 72 { return .command(command()) }
    if roll < 75 {
      let operation = outstanding.isEmpty || chance(25)
        ? PlaybackOperationID(rawValue: UInt64(below(12)))
        : pick(outstanding).context.operationID
      return .deadlineReached(operationID: operation)
    }
    return observation()
  }

  private static func sorted(_ tokens: Set<EffectResultToken>) -> [EffectResultToken] {
    tokens.sorted { $0.canonicalKey < $1.canonicalKey }
  }

  private mutating func token(for requirement: EffectResultRequirement) -> EffectResultToken {
    switch requirement {
    case .exactly(let token): token
    case .oneOf(let tokens): pick(Self.sorted(tokens))
    }
  }

  private mutating func result() -> PlaybackEvent {
    let index = below(outstanding.count)
    let effect = outstanding[index]
    let id = effect.context.effectID
    let token: EffectResultToken
    var terminal = true
    switch effect.completion {
    case .oneShot(let terminals):
      token = chance(80)
        ? EffectResultToken(kind: .succeeded) : pick(Self.sorted(terminals))
    case .phased(let phases, let terminals):
      let current = phase[id, default: 0]
      if current < phases.count, !phases[current].isEmpty, chance(85) {
        token = self.token(for: pick(phases[current]))
        phase[id] = current + 1
        terminal = false
      } else {
        token = pick(Self.sorted(terminals))
      }
    case .subscription(_, let callbacks, let terminals):
      if !callbacks.isEmpty, chance(70) {
        token = pick(Self.sorted(callbacks))
        terminal = false
      } else {
        token = pick(Self.sorted(terminals))
      }
    case .bestEffortMirror:
      token = EffectResultToken(kind: .succeeded)
    }
    let failure = token.kind == .failed || chance(4) ? failureValue() : nil
    let value = PlaybackEffectResult(context: effect.context, token: token, failure: failure)
    if terminal {
      outstanding.remove(at: index)
      phase[id] = nil
    }
    completed.append(value)
    if completed.count > 32 { completed.removeFirst() }
    return .effectResult(value)
  }

  private mutating func staleResult() -> PlaybackEvent {
    let effect = pick(history)
    let context: PlaybackEffectContext
    switch below(3) {
    case 0:
      context = PlaybackEffectContext(
        authority: effect.context.authority,
        operationID: effect.context.operationID,
        effectID: PlaybackEffectID(rawValue: effect.context.effectID.rawValue &+ 997),
        streamID: effect.context.streamID, trackID: effect.context.trackID)
    case 1:
      context = PlaybackEffectContext(
        authority: authority(shifting: effect.context.authority),
        operationID: effect.context.operationID,
        effectID: effect.context.effectID,
        streamID: effect.context.streamID, trackID: effect.context.trackID)
    default:
      context = PlaybackEffectContext(
        authority: effect.context.authority,
        operationID: PlaybackOperationID(rawValue: effect.context.operationID.rawValue &+ 1),
        effectID: effect.context.effectID,
        streamID: effect.context.streamID, trackID: effect.context.trackID)
    }
    return .effectResult(
      PlaybackEffectResult(context: context, token: EffectResultToken(kind: .succeeded)))
  }

  private func authority(shifting authority: PlaybackAuthority) -> PlaybackAuthority {
    switch authority {
    case .application(let epoch):
      .application(ApplicationEpochID(rawValue: epoch.rawValue &+ 1))
    case .playback(let session, let generation, let revisions):
      .playback(
        sessionID: session,
        generation: PlaybackGenerationID(rawValue: generation.rawValue &+ 1),
        revisions: revisions)
    }
  }

  private mutating func timestamp() -> MediaTimestamp {
    switch below(10) {
    case 0: .unknown
    case 1: .invalid(pick([.zeroTimescale, .nonFiniteSource, .overflow, .discontinuity]))
    default:
      ValidMediaTime(value: Int64(below(300_000)), timescale: 1_000).map(MediaTimestamp.valid)
        ?? .unknown
    }
  }

  private mutating func track(_ kind: MediaTrackKind) -> PlaybackTrackID {
    PlaybackTrackID(kind: kind, mediaTrackID: Int64(1 + below(3)))
  }

  private mutating func source() -> MediaSourceIdentity {
    MediaSourceIdentity(rawValue: "oracle-\(below(4))")
  }

  private mutating func command() -> IlliquidPlaybackModel.PlaybackCommand {
    switch below(100) {
    case ..<14: return .load(source: source(), autoplay: chance(60))
    case ..<28: return .play
    case ..<38: return .pause
    case ..<44: return .setPlaybackSpeed(milliRate: pick([0, 250, 500, 1_000, 1_500, 2_000, -1_000]))
    case ..<48:
      return chance(50) ? .setLoop(start: nil, end: nil) : .setLoop(start: timestamp(), end: timestamp())
    case ..<66: return .seek(target: timestamp(), mode: pick([.relative, .keyframe, .exact, .preview]))
    case ..<73:
      return .selectAudio(pick([.off, .automatic, .stream(track(.audio))]))
    case ..<80:
      return .selectSubtitle(pick([
        .off, .automatic, .embedded(track(.subtitle)), .external(source()),
      ]))
    case ..<85: return .setSubtitleDelay(microseconds: Int64(below(4_000_001)) - 2_000_000)
    case ..<89: return .checkpoint
    case ..<99: return .stop
    default: return .shutdown
    }
  }

  private mutating func stream(_ kind: PlaybackStreamKind? = nil) -> PlaybackStreamID {
    PlaybackStreamID(kind: kind ?? pick([.video, .audio, .subtitle]), demuxIndex: Int32(below(3)))
  }

  private mutating func failureValue() -> PlaybackFailure {
    if chance(65) { return recoveryFailure() }
    return PlaybackFailure(
      domain: pick([.input, .demux, .videoDecode, .audioDecode, .presentation, .subtitle,
                    .persistence, .platform, .resource]),
      stage: pick([.open, .probe, .configure, .read, .seek, .receiveFrame, .render, .persist,
                   .flush, .drain]),
      stableCode: pick(["oracle.timeout", "oracle.decode", "oracle.io", "oracle.device"]),
      nativeCode: chance(50) ? Int64(below(200)) - 100 : nil,
      recoverability: pick([.retryable, .fallbackAvailable, .fatal, .cancelled]),
      streamID: chance(70) ? stream() : nil,
      formatRevision: chance(20) ? MediaFormatRevisionID(rawValue: UInt64(below(4))) : nil,
      codecName: chance(40) ? pick(["h264", "hevc", "aac"]) : nil,
      codecProfile: nil,
      hardwareWasConfigured: chance(50),
      hardwareOutputWasObserved: chance(50),
      consecutiveCount: 1 + below(4))
  }

  /// Failures shaped like the native classifier's recovery inputs.
  private mutating func recoveryFailure() -> PlaybackFailure {
    let video = PlaybackStreamID(kind: .video, demuxIndex: Int32(below(2)))
    let audio = PlaybackStreamID(kind: .audio, demuxIndex: Int32(1 + below(2)))
    switch below(8) {
    case 0, 1:
      return PlaybackFailure(
        domain: .videoDecode, stage: .receiveFrame, stableCode: "oracle.hardware",
        recoverability: .fallbackAvailable, streamID: video, codecName: "hevc",
        hardwareWasConfigured: true, hardwareOutputWasObserved: chance(50),
        consecutiveCount: 1 + below(4))
    case 2:
      return PlaybackFailure(
        domain: .videoDecode, stage: .receiveFrame, stableCode: "softwareVideoDecoderNoProgress",
        recoverability: .fallbackAvailable, streamID: video)
    case 3:
      return PlaybackFailure(
        domain: .audioDecode, stage: .enqueue, stableCode: "oracle.audio-enqueue",
        recoverability: .fallbackAvailable, streamID: audio)
    case 4:
      return PlaybackFailure(
        domain: .audioDecode, stage: .configure, stableCode: "oracle.audio",
        recoverability: .fallbackAvailable, streamID: audio)
    case 5:
      return PlaybackFailure(
        domain: .subtitle, stage: .read, stableCode: pick(["oracle.subtitle", "nativeSubtitleReadFailed"]),
        recoverability: .fallbackAvailable,
        streamID: chance(70) ? PlaybackStreamID(kind: .subtitle, demuxIndex: Int32(2 + below(2))) : nil)
    case 6:
      return PlaybackFailure(
        domain: .presentation, stage: pick([.flush, .enqueue, .render]), stableCode: "oracle.present",
        recoverability: pick([.retryable, .fallbackAvailable]))
    default:
      return PlaybackFailure(
        domain: pick([.demux, .input, .platform]), stage: .read, stableCode: "oracle.fatal",
        recoverability: .fatal)
    }
  }

  private mutating func catalog() -> PlaybackCatalog {
    let audioCount = below(3)
    let subtitleCount = below(3)
    return PlaybackCatalog(
      hasVideo: chance(80),
      audio: (0..<audioCount).map {
        PlaybackTrackCandidate(
          id: PlaybackTrackID(kind: .audio, mediaTrackID: Int64($0 + 1)), isDefault: $0 == 0)
      },
      subtitles: (0..<subtitleCount).map {
        PlaybackTrackCandidate(
          id: PlaybackTrackID(kind: .subtitle, mediaTrackID: Int64($0 + 1)),
          isDefault: false, isForced: $0 == 1)
      })
  }

  private mutating func observation() -> PlaybackEvent {
    switch below(13) {
    case 0: return .diagnosticObserved(code: pick(["oracle.a", "native.runtime"]))
    case 1:
      switch below(4) {
      case 0: return .subtitle(.invalidate(reason: pick([.seek, .replacement, .trackChange, .stop])))
      case 1:
        let authority = history.isEmpty
          ? PlaybackAuthority.application(ApplicationEpochID(rawValue: 1))
          : pick(history).context.authority
        return .subtitle(.overlayCommitCandidate(
          authority: authority, revision: OverlayRevisionID(rawValue: UInt64(below(4)))))
      case 2: return .subtitle(.sourceInstalled(source(), external: chance(50)))
      default: return .subtitle(.appliedDelay(microseconds: Int64(below(1_000_000))))
      }
    case 2: return .acceptedClockSample(timestamp())
    case 3: return .audioOutputChanged(timestamp())
    case 4: return .durationObserved(timestamp())
    case 5: return .catalogObserved(catalog())
    case 6:
      var required: Set<PlaybackDrainComponent> = []
      for component in [PlaybackDrainComponent.videoDecoder, .videoPresenter, .audioDecoder, .audioPresenter] where chance(40) {
        required.insert(component)
      }
      return .demuxEndOfFile(requiredDrain: required)
    case 7: return .drainObserved(pick([.videoDecoder, .videoSubmission, .videoPresenter, .audioDecoder, .audioConverter, .audioSubmission, .audioPresenter]))
    case 8: return .failureObserved(failureValue())
    case 9, 10:
      switch below(7) {
      case 0: return .synchronization(.require(chance(70) ? [.video, .audio] : [pick([.video, .audio])]))
      case 1: return .synchronization(.prerolled(pick([.video, .audio])))
      case 2: return .synchronization(.rateAcknowledged(milliRate: pick([0, 1_000, 2_000])))
      case 3:
        return .synchronization(.supplyObserved(
          starved: chance(40), cacheMicroseconds: UInt64(below(5_000_000))))
      case 4: return .synchronization(.clockObserved(timestamp()))
      case 5: return .synchronization(.presentationObserved(video: timestamp(), audio: timestamp()))
      default:
        return .synchronization(.formatChanged(
          stream: pick([.video, .audio]), revision: MediaFormatRevisionID(rawValue: UInt64(below(4)))))
      }
    default: return .lifecycle(pick([.systemWillSleep, .systemDidWake]))
    }
  }
}

struct ProductionOracleStart {
  let name: String
  let state: PlaybackDomainState
}

enum ProductionOracle {
  static let fixtureName = "production-migration-oracle-v1.json"
  static let streamsPerStart = 6
  static let freshStreams = 120
  static let steps = 96

  struct Stream: Codable, Equatable {
    var start: String
    var seed: UInt64
    var steps: Int
    var chain: String
    var stepDigests: [String]
  }

  struct Coverage: Codable, Equatable {
    var dispositions: [String: Int] = [:]
    var events: [String: Int] = [:]
    var effects: [String: Int] = [:]
    var lifecycles: [String: Int] = [:]
    var invariantViolations: [String: Int] = [:]
  }

  struct Start: Codable, Equatable {
    var name: String
    /// Canonical JSON of the start state, base64.
    var state: String
  }

  struct Fixture: Codable, Equatable {
    var schema = "illiquid.production-migration-oracle"
    var version = 1
    var recordedFrom: String
    var starts: [Start]
    var streams: [Stream]
    var coverage: Coverage
  }

  static func label(_ value: some Encodable) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return "?" }
    if let dictionary = object as? [String: Any], let key = dictionary.keys.sorted().first {
      return key
    }
    return "\(object)"
  }

  static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func run(
    _ step: ProductionOracleStep, start: ProductionOracleStart, seed: UInt64,
    coverage: inout Coverage
  ) throws -> Stream {
    var state = start.state
    var stream = ProductionOracleStream(seed: seed, state: state)
    var chain = SHA256()
    var digests: [String] = []
    for _ in 0..<steps {
      let envelope = stream.nextEnvelope()
      let (next, transition) = step(state, envelope)
      state = next
      stream.observe(transition)
      var hasher = SHA256()
      hasher.update(data: try CanonicalJSON.encode(envelope))
      hasher.update(data: try CanonicalJSON.encode(transition))
      hasher.update(data: try CanonicalJSON.encode(state))
      let digest = hex(hasher.finalize())
      chain.update(data: Data(digest.utf8))
      digests.append(String(digest.prefix(12)))
      coverage.events[label(envelope.event), default: 0] += 1
      coverage.dispositions[label(transition.disposition), default: 0] += 1
      coverage.lifecycles[state.lifecycle.rawValue, default: 0] += 1
      for effect in transition.effects { coverage.effects[label(effect.kind), default: 0] += 1 }
      for violation in transition.invariantViolations {
        coverage.invariantViolations[violation.name, default: 0] += 1
      }
    }
    return Stream(
      start: start.name, seed: seed, steps: steps, chain: hex(chain.finalize()),
      stepDigests: digests)
  }

  static func encodedStarts(_ starts: [ProductionOracleStart]) throws -> [Start] {
    try starts.map { Start(name: $0.name, state: Data(try CanonicalJSON.encode($0.state)).base64EncodedString()) }
  }

  static func decodedStarts(_ starts: [Start]) throws -> [ProductionOracleStart] {
    try starts.map {
      ProductionOracleStart(
        name: $0.name,
        state: try CanonicalJSON.decode(
          PlaybackDomainState.self, from: Array(try #require(Data(base64Encoded: $0.state)))))
    }
  }

  static func record(
    _ engine: () -> ProductionOracleStep, starts: [ProductionOracleStart], recordedFrom: String
  ) throws -> Fixture {
    var coverage = Coverage()
    var streams: [Stream] = []
    for (index, start) in starts.enumerated() {
      let count = start.name == "fresh" ? freshStreams : streamsPerStart
      for offset in 0..<count {
        let seed = UInt64(index) << 32 | UInt64(offset + 1)
        streams.append(try run(engine(), start: start, seed: seed, coverage: &coverage))
      }
    }
    return Fixture(
      recordedFrom: recordedFrom, starts: try encodedStarts(starts), streams: streams,
      coverage: coverage)
  }

  static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(fixtureName)
  }
}

@Suite("Production model oracle")
struct ProductionModelOracleTests {
  static func fixture() throws -> ProductionOracle.Fixture {
    try JSONDecoder().decode(
      ProductionOracle.Fixture.self, from: Data(contentsOf: ProductionOracle.fixtureURL))
  }

  static func check(_ engine: () -> ProductionOracleStep) throws {
    let expected = try fixture()
    let actual = try ProductionOracle.record(
      engine, starts: try ProductionOracle.decodedStarts(expected.starts),
      recordedFrom: expected.recordedFrom)
    #expect(actual.streams.count == expected.streams.count)
    for (lhs, rhs) in zip(actual.streams, expected.streams) where lhs != rhs {
      let step = Array(zip(lhs.stepDigests, rhs.stepDigests)).firstIndex { $0 != $1 } ?? -1
      Issue.record("\(rhs.start) seed \(rhs.seed): first differing step \(step)")
    }
    #expect(actual.coverage == expected.coverage)
  }

  /// Every frozen legacy step is reproduced by the model executed in a
  /// persistent Statelessness session.
  @Test func sessionReproducesTheFrozenLegacyCore() throws {
    try Self.check { ProductionOracleSessionEngine().step }
  }

  /// The bare step callback agrees too, so the session adds no behavior.
  @Test func stepCallbackReproducesTheFrozenLegacyCore() throws {
    try Self.check { ProductionOracleEngine.step }
  }
}

/// Opt-in turn-latency measurement (ILLIQUID_PRODUCTION_TURN_BENCHMARK=1).
/// Replays every oracle stream's envelopes through the engine without digests
/// and prints per-turn latency. Used for the paired P0/P4 cost comparison.
@Suite("Production model turn cost")
struct ProductionModelTurnCostTests {
  @Test func turnLatency() throws {
    guard ProcessInfo.processInfo.environment["ILLIQUID_PRODUCTION_TURN_BENCHMARK"] == "1" else { return }
    let fixture = try JSONDecoder().decode(
      ProductionOracle.Fixture.self, from: Data(contentsOf: ProductionOracle.fixtureURL))
    let starts = Dictionary(
      uniqueKeysWithValues: try ProductionOracle.decodedStarts(fixture.starts).map { ($0.name, $0.state) })
    // Pre-generate the envelopes so only the engine is timed.
    var workloads: [(PlaybackDomainState, [PlaybackEventEnvelope])] = []
    for stream in fixture.streams {
      var state = try #require(starts[stream.start])
      let initial = state
      var generator = ProductionOracleStream(seed: stream.seed, state: state)
      var envelopes: [PlaybackEventEnvelope] = []
      for _ in 0..<stream.steps {
        let envelope = generator.nextEnvelope()
        let (next, transition) = ProductionOracleEngine.step(state, envelope)
        state = next
        generator.observe(transition)
        envelopes.append(envelope)
      }
      workloads.append((initial, envelopes))
    }
    var samples: [Double] = []
    for round in 0..<5 {
      let clock = ContinuousClock()
      var turns = 0
      let elapsed = clock.measure {
        for (initial, envelopes) in workloads {
          let session = try! PlaybackProductionModel.session(state: initial)
          for envelope in envelopes {
            _ = try! session.submit(envelope)
            turns += 1
          }
        }
      }
      let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      if round > 0 { samples.append(seconds / Double(turns) * 1e9) }
    }
    samples.sort()
    print("production-turn-latency engine=statelessness-session ns-per-turn median=\(samples[samples.count / 2]) min=\(samples[0]) max=\(samples[samples.count - 1])")
  }
}
