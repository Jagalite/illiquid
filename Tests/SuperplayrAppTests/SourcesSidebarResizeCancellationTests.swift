import Testing
@testable import SuperplayrApp

@Suite("Sources sidebar resize cancellation")
@MainActor
struct SourcesSidebarResizeCancellationTests {
    @Test func interruptedDragRestoresSavedWidthAndAllowsAnotherDrag() {
        let state = SourcesSidebarResizeState()
        state.setLiveWidth(360)
        #expect(state.beginGesture())
        state.setLiveWidth(520)
        #expect(state.cancelGesture(restoring: 360))
        #expect(state.liveWidth == 360)
        #expect(state.beginGesture())
    }

    @Test func gestureResetAfterMouseUpDoesNotUndoCommittedWidth() {
        let state = SourcesSidebarResizeState()
        #expect(state.beginGesture())
        state.setLiveWidth(520)
        state.endGesture()
        #expect(!state.cancelGesture(restoring: 360))
        #expect(state.liveWidth == 520)
    }
}
