import Testing
@testable import IlliquidPlaybackCore

@Suite("Playback parity transport policies")
struct PlaybackParityCoreTests {
    private func time(_ milliseconds: Int64) -> MediaTimestamp {
        .valid(ValidMediaTime(value: milliseconds, timescale: 1000)!)
    }
    private func settle(_ runtime: inout PlaybackModelRuntime) {
        for _ in 0..<40 {
            guard let result = runtime.completeNext() else { return }
            #expect(result.invariantViolations.isEmpty)
        }
        Issue.record("The transaction did not settle within its expected bounds")
    }
    @Test func speedSurvivesPauseSeekWakeAndSourceReplacement() {
        var runtime = PlaybackModelRuntime()
        _ = runtime.send(.command(.setPlaybackSpeed(milliRate: 1500)))
        _ = runtime.send(.command(.load(source: .init(rawValue: "movie"), autoplay: true)))
        settle(&runtime)
        #expect(runtime.core.state.activeSession?.synchronization.desiredMilliRate == 1500)
        _ = runtime.send(.command(.pause)); settle(&runtime)
        _ = runtime.send(.command(.setPlaybackSpeed(milliRate: 2000)))
        #expect(runtime.core.state.activeSession?.desiredTransport == .paused)
        _ = runtime.send(.command(.play)); settle(&runtime)
        _ = runtime.send(.command(.seek(target: time(2000), mode: .exact))); settle(&runtime)
        #expect(runtime.core.state.activeSession?.synchronization.desiredMilliRate == 2000)
        _ = runtime.send(.lifecycle(.systemWillSleep)); settle(&runtime)
        _ = runtime.send(.lifecycle(.systemDidWake)); settle(&runtime)
        #expect(runtime.core.state.activeSession?.synchronization.desiredMilliRate == 2000)
        _ = runtime.send(.command(.load(source: .init(rawValue: "next"), autoplay: true))); settle(&runtime)
        #expect(runtime.core.state.activeSession?.synchronization.desiredMilliRate == 2000)
        let invalid = runtime.send(.command(.setPlaybackSpeed(milliRate: -1)))
        #expect(invalid.disposition == .invalid(reason: "unsupportedPlaybackSpeed"))
    }
    @Test func loopUsesOneExactSeekAndDoesNotLeakToAnotherFile() {
        var runtime = PlaybackModelRuntime()
        _ = runtime.send(.command(.load(source: .init(rawValue: "loop"), autoplay: true))); settle(&runtime)
        _ = runtime.send(.durationObserved(time(10000)))
        _ = runtime.send(.command(.setLoop(start: time(1000), end: time(2000))))
        let boundary = runtime.send(.acceptedClockSample(time(2050)))
        #expect(boundary.snapshot.phase == .seeking)
        #expect(runtime.core.state.activeSession?.seek?.target == time(1000))
        let repeated = runtime.send(.acceptedClockSample(time(2060)))
        #expect(repeated.effects.isEmpty)
        settle(&runtime)
        _ = runtime.send(.command(.pause)); settle(&runtime)
        #expect(runtime.send(.acceptedClockSample(time(2050))).effects.isEmpty)
        _ = runtime.send(.command(.load(source: .init(rawValue: "other"), autoplay: true))); settle(&runtime)
        #expect(runtime.send(.acceptedClockSample(time(2050))).effects.isEmpty)
    }
}
