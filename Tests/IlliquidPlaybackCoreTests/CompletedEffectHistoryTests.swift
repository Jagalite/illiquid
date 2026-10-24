import Foundation
import Testing

@testable import IlliquidPlaybackCore

@Suite("Compact completed-effect history")
struct CompletedEffectHistoryTests {
  private func id(_ value: UInt64) -> PlaybackEffectID { .init(rawValue: value) }

  @Test
  func consecutiveHistoryUsesOnlyAPrefixWithoutForgettingOldIDs() {
    var history = CompletedPlaybackEffectHistory(wrappedValue: [])
    for value in UInt64(1)...100_000 { history.insert(id(value)) }

    #expect(history.prefixCount == 100_000)
    #expect(history.sparseCount == 0)
    #expect(history.sparseCapacity == 0)
    #expect(history.contains(id(1)))
    #expect(history.contains(id(50_000)))
    #expect(history.contains(id(100_000)))
    #expect(!history.contains(id(0)))
    #expect(!history.contains(id(100_001)))
    #expect(history.wrappedValue.count == 100_000)
  }

  @Test
  func outOfOrderCompletionsFillHolesAndDuplicatesDoNotChangeHistory() {
    var history = CompletedPlaybackEffectHistory(wrappedValue: [])
    for value: UInt64 in [1, 3, 5, 7, 4] { history.insert(id(value)) }
    #expect(history.prefixCount == 1)
    #expect(history.sparseCount == 4)
    #expect(!history.contains(id(2)))
    #expect(!history.contains(id(6)))

    history.insert(id(2))
    #expect(history.prefixCount == 5)
    #expect(history.sparseCount == 1)
    #expect(!history.contains(id(6)))
    history.insert(id(6))
    let settled = history
    for value in UInt64(1)...7 { history.insert(id(value)) }
    #expect(history == settled)
    #expect(history.prefixCount == 7)
    #expect(history.sparseCount == 0)
    #expect(history.sortedIDs == (UInt64(1)...7).map(id))
  }

  @Test
  func closingManyCompletionGapsReleasesTheirPeakStorage() {
    var history = CompletedPlaybackEffectHistory(wrappedValue: [])
    for value in stride(from: UInt64(1), through: 4_095, by: 2) {
      history.insert(id(value))
    }
    #expect(history.prefixCount == 1)
    #expect(history.sparseCount == 2_047)
    let sparseSnapshot = history
    for value in stride(from: UInt64(2), through: 4_094, by: 2) {
      history.insert(id(value))
    }
    #expect(history.prefixCount == 4_095)
    #expect(history.sparseCount == 0)
    #expect(history.sparseCapacity == 0)
    #expect(history.wrappedValue == Set((UInt64(1)...4_095).map(id)))
    #expect(sparseSnapshot.prefixCount == 1)
    #expect(sparseSnapshot.sparseCount == 2_047)
    #expect(!sparseSnapshot.contains(id(2)))
  }

  @Test
  func anEarlyGapKeepsLaterIDsInASetUntilItActuallyCompletes() {
    var history = CompletedPlaybackEffectHistory(wrappedValue: [id(1)])
    for value in UInt64(3)...20_000 { history.insert(id(value)) }
    #expect(history.prefixCount == 1)
    #expect(history.sparseCount == 19_998)
    #expect(!history.contains(id(2)))
    #expect(history.contains(id(20_000)))

    history.insert(id(2))
    #expect(history.prefixCount == 20_000)
    #expect(history.sparseCount == 0)
    #expect(history.sparseCapacity == 0)
    #expect(history.contains(id(2)))
  }

  @Test
  func zeroAndMaximumIDsDoNotOverflowOrBridgeMissingHistory() throws {
    var history = CompletedPlaybackEffectHistory(wrappedValue: [])
    for value: UInt64 in [0, .max, 1, .max - 1, .max - 2, 2] {
      history.insert(id(value))
    }
    let expected = Set([id(0), id(1), id(2), id(.max - 2), id(.max - 1), id(.max)])
    #expect(history.prefixCount == 2)
    #expect(history.sparseCount == 4)
    #expect(history.wrappedValue == expected)
    #expect(history.sortedIDs == expected.sorted())
    #expect(!history.contains(id(3)))
    #expect(!history.contains(id(.max - 3)))

    let encoded = try JSONEncoder().encode(history)
    #expect(try JSONDecoder().decode(Set<PlaybackEffectID>.self, from: encoded) == expected)
    #expect(try JSONDecoder().decode(CompletedPlaybackEffectHistory.self, from: encoded) == history)
  }

  @Test
  func randomizedHistoryMatchesSetIncludingSparseAndRepeatedIDs() {
    for seed in UInt64(1)...12 {
      var random = seed
      var history = CompletedPlaybackEffectHistory(wrappedValue: [])
      var expected: Set<PlaybackEffectID> = []
      for step in 0..<2_000 {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value: UInt64
        let mixed = random >> 16
        switch random >> 56 {
        case 0..<85: value = mixed % 1_024
        case 85..<170: value = UInt64.max - mixed % 128
        default: value = (1 << 40) + mixed % 2_048 * 3
        }
        history.insert(id(value))
        expected.insert(id(value))
        for probe in [value, value == 0 ? 0 : value - 1,
                      value == UInt64.max ? UInt64.max : value + 1, random] {
          #expect(history.contains(id(probe)) == expected.contains(id(probe)))
        }
        if step % 100 == 0 {
          #expect(history.wrappedValue == expected)
          #expect(history.sortedIDs == expected.sorted())
        }
      }
      #expect(history.wrappedValue == expected)
    }
  }

  @Test
  func shuffledCompleteHistoriesDrainToTheSameCanonicalPrefix() {
    for seed in UInt64(1)...8 {
      var random = seed
      var values = Array(UInt64(1)...1_024)
      for index in stride(from: values.count - 1, through: 1, by: -1) {
        random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        values.swapAt(index, Int((random >> 32) % UInt64(index + 1)))
      }
      var history = CompletedPlaybackEffectHistory(wrappedValue: [])
      var expected: Set<PlaybackEffectID> = []
      for value in values {
        history.insert(id(value))
        expected.insert(id(value))
        #expect(history.contains(id(value)))
        #expect(history.wrappedValue == expected)
      }
      #expect(history.prefixCount == 1_024)
      #expect(history.sparseCount == 0)
      #expect(history.sparseCapacity == 0)
    }
  }

  @Test
  func publicSetMutationsAndValueCopiesKeepTheirOriginalSemantics() {
    let original = PlaybackCoreState(completedEffectIDs: [id(1), id(3)])
    var changed = original
    changed.completedEffectIDs.insert(id(2))
    #expect(changed.completedEffectIDs == Set([id(1), id(2), id(3)]))
    #expect(changed.completedEffectHistoryPrefixCount == 3)
    #expect(changed.completedEffectHistorySparseCount == 0)
    #expect(original.completedEffectIDs == Set([id(1), id(3)]))

    func editThroughInout(_ values: inout Set<PlaybackEffectID>) {
      values.remove(id(2))
      values.insert(id(100))
    }
    editThroughInout(&changed.completedEffectIDs)
    #expect(changed.completedEffectIDs == Set([id(1), id(3), id(100)]))
    #expect(original.completedEffectIDs == Set([id(1), id(3)]))

    var compactCopy = changed
    compactCopy.recordCompletedEffect(id(2))
    #expect(changed.completedEffectIDs == Set([id(1), id(3), id(100)]))
    #expect(compactCopy.completedEffectIDs == Set([id(1), id(2), id(3), id(100)]))
    changed.completedEffectIDs = []
    #expect(changed.completedEffectHistoryPrefixCount == 0)
    #expect(changed.completedEffectHistorySparseCount == 0)
    #expect(!changed.containsCompletedEffect(id(1)))
  }

  @Test
  func stateCodablePreservesLegacySetFieldAndCanonicalReplay() throws {
    struct LegacyHistory: Decodable { let completedEffectIDs: Set<PlaybackEffectID> }
    let expected = Set([id(1), id(2), id(3), id(7), id(9)])
    let state = PlaybackCoreState(completedEffectIDs: expected)
    let encoded = try JSONEncoder().encode(state)
    let legacy = try JSONDecoder().decode(LegacyHistory.self, from: encoded)
    #expect(legacy.completedEffectIDs == expected)

    // Prior Set output may use any order. Duplicate JSON elements have always
    // decoded with Set semantics as well, even though the encoder emits none.
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let unordered = try JSONEncoder().encode([id(9), id(3), id(7), id(1), id(2), id(3)])
    object["completedEffectIDs"] = try JSONSerialization.jsonObject(with: unordered)
    let legacyBytes = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(PlaybackCoreState.self, from: legacyBytes)
    #expect(decoded == state)
    #expect(decoded.completedEffectHistoryPrefixCount == 3)
    #expect(decoded.completedEffectHistorySparseCount == 2)
    #expect(PlaybackCanonicalState(state: decoded).completedEffectIDs == expected.sorted())
    #expect(PlaybackReplayCodec.digest(PlaybackCanonicalState(state: decoded))
      == PlaybackReplayCodec.digest(PlaybackCanonicalState(state: state)))
  }

  @Test
  func productionCoreRetainsDuplicateClassificationAfterLongHistory() throws {
    var runtime = PlaybackModelRuntime(recordsReplaySteps: false)
    let load = runtime.send(.command(.load(
      source: .init(rawValue: "fixture/history.mkv"), autoplay: false
    )))
    let first = try #require(load.effects.first)
    _ = runtime.completeNext()
    _ = runtime.completeNext()

    for _ in 0..<10_000 {
      let checkpoint = runtime.send(.command(.checkpoint))
      #expect(checkpoint.disposition == .accepted)
      let completion = runtime.completeNext()
      #expect(completion?.disposition == .accepted)
      #expect(completion?.invariantViolations.isEmpty == true)
    }
    #expect(runtime.core.state.completedEffectIDs.count == 10_002)
    #expect(runtime.core.state.completedEffectHistoryPrefixCount == 10_002)
    #expect(runtime.core.state.completedEffectHistorySparseCount == 0)
    #expect(runtime.pendingEffects.isEmpty)
    let before = PlaybackUISnapshot(state: runtime.core.state)
    let duplicate = runtime.send(.effectResult(.init(
      context: first.context, token: .init(kind: .succeeded)
    )))
    #expect(duplicate.disposition == .duplicate(effectID: first.context.effectID))
    #expect(duplicate.effects.isEmpty)
    #expect(duplicate.invariantViolations.isEmpty)
    #expect(duplicate.snapshot == before)
  }

  @Test
  func outstandingHolesRemainLiveUntilTheirOwnResultsArrive() throws {
    var runtime = PlaybackModelRuntime(recordsReplaySteps: false)
    _ = runtime.send(.command(.load(source: .init(rawValue: "fixture/holes.mkv"), autoplay: false)))
    _ = runtime.completeNext()
    _ = runtime.completeNext()
    var effects: [PlaybackEffect] = []
    for _ in 0..<32 {
      let checkpoint = runtime.send(.command(.checkpoint))
      effects.append(try #require(checkpoint.effects.first))
    }
    for index in stride(from: 1, to: effects.count, by: 2) {
      let completion = runtime.complete(effectID: effects[index].context.effectID)
      #expect(completion?.disposition == .accepted)
    }
    for index in stride(from: 0, to: effects.count, by: 2) {
      let effect = effects[index]
      #expect(!runtime.core.state.containsCompletedEffect(effect.context.effectID))
      #expect(runtime.core.state.outstandingEffects[effect.context.effectID] != nil)
      let completion = runtime.complete(effectID: effect.context.effectID)
      #expect(completion?.disposition == .accepted)
      #expect(completion?.invariantViolations.isEmpty == true)
    }
    #expect(runtime.core.state.completedEffectHistoryPrefixCount == 34)
    #expect(runtime.core.state.completedEffectHistorySparseCount == 0)
    #expect(runtime.core.state.outstandingEffects.isEmpty)
  }

  @Test
  func arbitraryInitialIDsDoNotTurnUnknownIDsIntoDuplicates() {
    var runtime = PlaybackModelRuntime(
      state: PlaybackCoreState(completedEffectIDs: [id(0), id(7), id(.max)]),
      recordsReplaySteps: false
    )
    for value: UInt64 in [0, 1, 6, 7, 8, .max - 1, .max] {
      let context = PlaybackEffectContext(
        authority: .application(.init(rawValue: 1)), operationID: .init(rawValue: 1),
        effectID: id(value)
      )
      let result = runtime.send(.effectResult(.init(context: context, token: .init(kind: .succeeded))))
      let expected: EventDisposition = [UInt64(0), 7, .max].contains(value)
        ? .duplicate(effectID: id(value)) : .stale(reason: .unknownEffect)
      #expect(result.disposition == expected)
      #expect(result.effects.isEmpty)
      #expect(result.invariantViolations.isEmpty)
    }
  }
}
