import Foundation
import Observation
import Synchronization
import Testing
@testable import SuperplayrCore

@MainActor
@Suite("Player state transitions")
struct PlaybackStateTests {
    @Test func recoveryTextExplainsFailuresAndKeepsCodesInCopyableDetails() throws {
        for code in ["nativeSubtitleReadFailed", "videoDecodeFailed", "futureNativeFailure"] {
            let state = PlaybackState()
            state.applyAuthorityProjection(projection(.failed, failureCode: code))
            let issue = try #require(state.recoveryIssue)
            #expect(!issue.message.contains(code))
            #expect(issue.diagnosticText.contains("Code: \(code)"))
            #expect(state.coreFailureCode == code)
        }
    }

    @Test func coreProjectionOwnsLifecycleAndTiming() throws {
        let state = PlaybackState()
        let file = URL(fileURLWithPath: "/Media/Episode 1.mkv")
        let request = try #require(MediaLoadRequest(
            source: .localFile(file), origin: .userSelected
        ))
        state.prepareLoadMetadata(request: request, playlistIndex: 0)
        #expect(state.currentSource == .localFile(file))
        state.applyAuthorityProjection(projection(.loading))
        #expect(state.phase == .loading)
        #expect(state.isLoading)
        #expect(!state.isPaused)

        state.applyAuthorityProjection(projection(.playing, position: 42, duration: 1_200))
        #expect(state.phase == .playing)
        state.updateVideoAspectRatio(16.0 / 9.0)
        #expect(!state.isLoading)
        #expect(state.duration == 1_200)
        #expect(state.position == 42)
        #expect(state.videoAspectRatio == 16.0 / 9.0)

        state.applyAuthorityProjection(projection(.idle))
        #expect(state.phase == .idle)
        #expect(state.isPaused)
        #expect(state.position == 0)
        #expect(state.videoAspectRatio == 16.0 / 9.0)
    }

    @Test func failureProjectionKeepsStableCode() {
        let state = PlaybackState()
        state.applyAuthorityProjection(projection(.failed, failureCode: "videoDecodeFailed"))

        #expect(state.phase == .failed)
        #expect(!state.isLoading)
        #expect(state.isPaused)
        #expect(state.lastError == "videoDecodeFailed")
    }

    @Test func coreAndShellFailuresRemainExplicitlyComposed() {
        let state = PlaybackState()
        state.applyAuthorityProjection(projection(.failed, failureCode: "videoDecodeFailed"))
        state.setShellError("Choose a supported file.")

        #expect(state.coreFailureCode == "videoDecodeFailed")
        #expect(state.shellError == "Choose a supported file.")
        #expect(state.lastError == "Choose a supported file.")

        state.setShellError(nil)
        #expect(state.lastError == "videoDecodeFailed")
    }

    @Test func lifecycleDerivesCompatibilityFlagsFromOnePhase() {
        let state = PlaybackState()

        state.applyAuthorityProjection(projection(.preparing))
        #expect(state.phase == .preparing)
        #expect(state.isLoading)
        #expect(!state.isPaused)

        state.applyAuthorityProjection(projection(.buffering, isBuffering: true))
        #expect(state.phase == .buffering)
        #expect(state.isLoading)
        #expect(!state.isPaused)

        state.applyAuthorityProjection(projection(.paused))
        #expect(state.phase == .paused)
        #expect(state.isPaused)
        #expect(!state.isLoading)

        state.applyAuthorityProjection(projection(.shuttingDown))
        #expect(state.phase == .shuttingDown)
    }

    @Test func desiredTransportRemainsStableDuringTransientSeekPhase() {
        let state = PlaybackState()

        state.applyAuthorityProjection(projection(.playing, isPauseDesired: false))
        #expect(!state.isPauseDesired)

        state.applyAuthorityProjection(projection(.preparing, isPauseDesired: false))
        #expect(!state.isPauseDesired)
        #expect(!state.isPaused)

        state.applyAuthorityProjection(projection(.preparing, isPauseDesired: true))
        #expect(state.isPauseDesired)
        #expect(!state.isPaused)
    }

    @Test func decoderStatusUsesTypedFactsInsteadOfInferringFromName() {
        let state = PlaybackState()
        state.updateActiveDecoder(
            "Software fallback after VideoToolbox failure",
            isHardwareDecoded: false,
            didFallbackToSoftware: true
        )
        #expect(!state.hardwareDecodingStatus.isHardwareDecoded)
        #expect(state.hardwareDecodingStatus.didFallbackToSoftware)
        #expect(!state.videoOutputStatus.isHardwareDecoded)
    }

    @Test func authorityProjectionPublishesOneSnapshotOnlyWhenValuesChange() {
        let state = PlaybackState()
        var mutationCount = 0
        state.onMutation = { mutationCount += 1 }

        let playing = projection(
            .playing,
            position: 42,
            duration: 1_200,
            isBuffering: true,
            isPauseDesired: false
        )
        state.applyAuthorityProjection(playing)
        #expect(mutationCount == 1)

        state.applyAuthorityProjection(playing)
        #expect(mutationCount == 1)
    }

    @Test func positionPublicationDoesNotInvalidateStableViewFields() {
        let state = PlaybackState()
        state.applyAuthorityProjection(projection(.playing, position: 1, duration: 100))
        let store = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: state))
        let stableFieldInvalidated = Mutex(false)

        withObservationTracking {
            _ = store.volume
        } onChange: {
            stableFieldInvalidated.withLock { $0 = true }
        }

        state.applyAuthorityProjection(projection(.playing, position: 2, duration: 100))
        store.publish(PlaybackViewSnapshot(state: state))

        #expect(!stableFieldInvalidated.withLock { $0 })
        #expect(store.position == 2)
        #expect(store.snapshot.position == 2)

        let positionInvalidated = Mutex(false)
        withObservationTracking {
            _ = store.position
        } onChange: {
            positionInvalidated.withLock { $0 = true }
        }

        state.applyAuthorityProjection(projection(.playing, position: 3, duration: 100))
        store.publish(PlaybackViewSnapshot(state: state))
        #expect(positionInvalidated.withLock { $0 })
    }

    private func projection(
        _ phase: PlaybackPhase,
        position: TimeInterval = 0,
        duration: TimeInterval = 0,
        isBuffering: Bool = false,
        failureCode: String? = nil,
        isPauseDesired: Bool = true
    ) -> PlaybackAuthorityProjection {
        PlaybackAuthorityProjection(
            phase: phase,
            position: position,
            duration: duration,
            isBuffering: isBuffering,
            selectedAudioID: nil,
            selectedSubtitleID: nil,
            subtitleDelay: 0,
            failureCode: failureCode,
            isPauseDesired: isPauseDesired
        )
    }
}
