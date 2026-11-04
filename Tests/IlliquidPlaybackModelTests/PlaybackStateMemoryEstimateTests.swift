import Testing
@testable import IlliquidPlaybackModel

@Suite("Playback state memory estimate")
struct PlaybackStateMemoryEstimateTests {
  @Test func modelProvidesEstimateAndAccountsForDynamicStorage() throws {
    let estimate = try #require(PlaybackProductionModel.make().estimatedStateBytes)
    let empty = PlaybackDomainState()
    let baseline = try #require(try estimate(empty))
    #expect(baseline >= UInt64(MemoryLayout<PlaybackDomainState>.stride))

    var expanded = empty
    expanded.lastPersistenceFailureCode = String(repeating: "x", count: 512)
    expanded.recordCompletedEffect(PlaybackEffectID(rawValue: 10_000))
    let larger = try #require(try estimate(expanded))
    #expect(larger >= baseline + 512)
  }

  @Test func compactHistoryIsNotExpandedForEstimation() throws {
    var state = PlaybackDomainState()
    for id in 1...1_000 { state.recordCompletedEffect(PlaybackEffectID(rawValue: UInt64(id))) }
    let estimate = try #require(PlaybackProductionModel.make().estimatedStateBytes)
    let compact = try #require(try estimate(state))
    let empty = try #require(try estimate(PlaybackDomainState()))
    #expect(compact == empty)
  }

  @Test func estimateRepresentativeSession() throws {
    let estimate = try #require(PlaybackProductionModel.make().estimatedStateBytes)
    let host = PlaybackSessionHost()
    let empty = try #require(try estimate(host.state))
    _ = host.send(.command(.load(source: MediaSourceIdentity(rawValue: "fixture/movie.mkv"), autoplay: false)))
    let opening = try #require(try estimate(host.state))
    print("playback-state-estimate empty_bytes=\(empty) opening_bytes=\(opening)")
    #expect(opening > empty)
  }
}
