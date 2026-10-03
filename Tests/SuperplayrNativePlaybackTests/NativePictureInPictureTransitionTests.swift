import Testing
@testable import SuperplayrNativePlayback

@Suite("Native Picture in Picture transitions")
struct NativePictureInPictureTransitionTests {
    @Test func reentryRequestedWhileStoppingStartsAfterStopCompletes() {
        var transitions = NativePictureInPictureTransitionModel()

        #expect(transitions.request(active: true, isPossible: true) == .start)
        #expect(transitions.didStart() == nil)
        #expect(transitions.request(active: false, isPossible: true) == .stop)
        #expect(transitions.presentsAsActive)
        #expect(transitions.request(active: true, isPossible: true) == nil)
        #expect(transitions.didStop(isPossible: true) == .start)
        #expect(transitions.phase == .starting)
        #expect(transitions.desiredActive)
    }

    @Test func missingStopCallbackUsesLocalStopAndPreservesReentry() {
        var transitions = NativePictureInPictureTransitionModel()

        #expect(transitions.request(active: true, isPossible: true) == .start)
        #expect(transitions.didStart() == nil)
        #expect(transitions.request(active: false, isPossible: true) == .stop)
        #expect(transitions.request(active: true, isPossible: true) == nil)
        #expect(transitions.stopDeadlineElapsed(isPossible: true) == .start)
        #expect(transitions.phase == .starting)
        #expect(transitions.desiredActive)
    }

    @Test func systemInitiatedStopDoesNotImmediatelyRestart() {
        var transitions = NativePictureInPictureTransitionModel()

        #expect(transitions.request(active: true, isPossible: true) == .start)
        #expect(transitions.didStart() == nil)
        transitions.prepareForStopCompletion()

        #expect(transitions.didStop(isPossible: true) == nil)
        #expect(transitions.phase == .stopped)
        #expect(!transitions.desiredActive)
    }
}
