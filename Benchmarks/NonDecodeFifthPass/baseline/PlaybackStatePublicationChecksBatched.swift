import Foundation
import Observation
@testable import IlliquidCore
#if !PORTABLE_STATE_TESTS
import XCTest
#endif

// The standalone runner executes these SAME scenario bodies with the real core
// and Observation runtime. Only XCTest discovery/wrappers are excluded there.
@MainActor
enum PlaybackStatePublicationChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    final class Checks {
        var count = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            count += 1
            if !condition() { throw Failure(description: message) }
        }
    }
    @MainActor final class Fixture {
        let state = PlaybackState()
        let view: PlaybackViewStore
        var publications: [PlaybackViewSnapshot] = []
        init() {
            view = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: state))
            state.onMutation = { [weak self] in
                guard let self else { return }
                let snapshot = PlaybackViewSnapshot(state: state)
                publications.append(snapshot)
                view.publish(snapshot)
            }
        }
        func reset() { publications.removeAll() }
    }
    final class ObservationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func increment() { lock.lock(); stored += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    }
    static func projection(position: Double = 1, duration: Double = 100,
                           audio: Int64? = nil, subtitle: Int64? = nil,
                           phase: PlaybackPhase = .playing, delay: Double = 0,
                           failure: String? = nil) -> PlaybackAuthorityProjection {
        .init(phase: phase, position: position, duration: duration, isBuffering: false,
              selectedAudioID: audio, selectedSubtitleID: subtitle,
              subtitleDelay: delay, failureCode: failure, isPauseDesired: phase != .playing)
    }

    static func scalarNoOps() throws -> Int {
        let c = Checks(), f = Fixture()
        f.state.setVolume(100); f.state.setMuted(false); f.state.setPlaybackSpeed(1)
        f.state.setFullscreen(false); f.state.setSidebarVisible(true)
        f.state.setRepeatMode(.off); f.state.setShuffleEnabled(false)
        f.state.updatePictureInPicture(.unavailable); f.state.setRecoveryIssue(nil)
        f.state.setShellError(nil); f.state.setTrackSelectionPreferences(.init())
        f.state.setSubtitleFallbackEncoding(.unicodeOnly); f.state.updateVideoAspectRatio(nil)
        f.state.updateDisplayOutput(.empty); f.state.setAudioDelay(0)
        f.state.setHardwareDecodingPolicy(.automatic)
        try c.require(f.publications.isEmpty, "unchanged scalar setters should not publish")
        f.state.setVolume(25); f.state.setMuted(true); f.state.setPlaybackSpeed(2)
        f.state.setFullscreen(true); f.state.setSidebarVisible(false)
        f.state.setRepeatMode(.all); f.state.setShuffleEnabled(true)
        f.state.updatePictureInPicture(.init(isPossible: true, isActive: true))
        f.state.setSubtitleFallbackEncoding(.shiftJIS); f.state.updateVideoAspectRatio(2)
        f.state.updateDisplayOutput(.init(name: "Display")); f.state.setAudioDelay(1)
        f.state.setHardwareDecodingPolicy(.off)
        try c.require(f.publications.count == 13, "changed controls must remain synchronous")
        try c.require(f.view.snapshot == PlaybackViewSnapshot(state: f.state), "view must be current")
        return c.count
    }
    static func chapterTransaction() throws -> Int {
        let c = Checks(), f = Fixture()
        let chapters = (0..<40).map { Chapter(id: Int64($0), title: "Chapter \($0)", startTime: Double($0)) }
        f.state.updateChapters(chapters, currentID: 3)
        try c.require(f.publications.count == 1, "chapter catalogue and ID must publish once")
        try c.require(f.publications[0].chapters == chapters && f.publications[0].currentChapterID == 3,
                      "no mixed chapter catalogue/ID snapshot")
        f.reset(); f.state.updateChapters(chapters, currentID: 3)
        try c.require(f.publications.count <= 1, "repeated catalogues must not publish twice")
        f.reset()
        f.state.updateChapters(chapters, currentID: 4)
        try c.require(f.publications.count == 1 && f.view.currentChapterID == 4, "ID-only change must publish")
        f.reset(); f.state.updateChapters([], currentID: 999)
        try c.require(f.publications.count == 1 && f.view.currentChapterID == 999,
                      "retain existing unvalidated chapter-ID semantics")
        return c.count
    }
    static func deviceTransaction() throws -> Int {
        let c = Checks(), f = Fixture()
        let devices = [AudioOutputDevice(id: "a", name: "A", isDefault: true, isSelected: false),
                       AudioOutputDevice(id: "b", name: "B", isDefault: false, isSelected: true)]
        f.state.updateAudioOutputDevices(devices)
        try c.require(f.publications.count == 1, "device update must publish once")
        try c.require(f.publications[0].audioOutputDevices == devices && f.publications[0].audioOutputDevice == devices[1],
                      "device selection belongs to the new catalogue")
        f.reset(); f.state.updateAudioOutputDevices(devices)
        try c.require(f.publications.count <= 1, "identical device list must not publish twice")
        f.reset()
        f.state.updateAudioOutputDevices([])
        try c.require(f.publications.count == 1 && f.view.audioOutputDevice == nil, "selection clears with catalogue")
        return c.count
    }
    static func trackTransaction() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = MediaTrack(id: 7, kind: .audio, title: "Original")
        let subtitle = MediaTrack(id: 4, kind: .subtitle, title: "Captions")
        f.state.updateTrackCatalog([subtitle, audio])
        try c.require(f.publications.count == 1, "both track kinds publish together")
        try c.require(f.publications[0].audioTracks == [audio] && f.publications[0].subtitleTracks == [subtitle], "track partition")
        f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 4)); f.reset()
        f.state.updateTrackCatalog([subtitle, audio])
        try c.require(f.publications.count <= 1, "equal metadata must not publish twice")
        f.reset()
        let changed = MediaTrack(id: 7, kind: .audio, title: "Changed")
        f.state.updateTrackCatalog([changed, subtitle])
        try c.require(f.publications.count == 1 && f.view.audioTracks == [changed], "same ID/new metadata is NOT equal")
        try c.require(f.view.selectedAudioTrack == audio, "catalogue does not assume authority over selection")
        f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 4))
        try c.require(f.view.selectedAudioTrack == changed, "authority projection refreshes selected metadata")
        f.state.updateTrackCatalog([changed, audio, subtitle])
        f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 4))
        try c.require(f.view.selectedAudioTrack == changed, "first duplicate-ID match remains selected")
        return c.count
    }
    static func diagnosticTransaction() throws -> Int {
        let c = Checks(), f = Fixture()
        for n in 0..<400 {
            f.reset(); f.state.recordDiagnostic("message-\(n)")
            try c.require(f.publications.count == 1, "one publication per nonempty diagnostic")
            let expected = (max(0,n-99)...n).map { "message-\($0)" }
            try c.require(f.publications[0].recentDiagnosticMessages == expected, "publish capped chronological messages, never 101")
        }
        f.reset(); f.state.recordDiagnostic("")
        try c.require(f.publications.isEmpty, "empty diagnostic remains ignored")
        f.state.recordDiagnostic("repeat"); f.state.recordDiagnostic("repeat")
        try c.require(Array(f.view.recentDiagnosticMessages.suffix(2)) == ["repeat", "repeat"], "do not deduplicate real diagnostic events")
        return c.count
    }
    static func filterTransaction() throws -> Int {
        let c = Checks(), f = Fixture()
        for filter in [VideoFilterPreset.sharpen, .denoise, .deband] {
            f.reset(); f.state.setVideoFilter(filter, enabled: true)
            try c.require(f.publications.count == 1, "filter enable publishes once after sorting")
            let expected = VideoFilterPreset.allCases.filter { f.state.activeVideoFilters.contains($0) }
            try c.require(f.publications[0].activeVideoFilters == expected, "no unsorted transient filter snapshot")
            f.reset(); f.state.setVideoFilter(filter, enabled: true)
            try c.require(f.publications.isEmpty, "already enabled filter remains silent")
        }
        f.reset(); f.state.setVideoFilter(.denoise, enabled: false)
        try c.require(f.publications.count == 1 && f.view.activeVideoFilters == [.deband,.sharpen], "disable/order")
        return c.count
    }
    static func shellErrorRecovery() throws -> Int {
        let c = Checks(), f = Fixture()
        f.state.setShellError("problem")
        try c.require(f.publications.count == 1 && f.publications[0].recoveryIssue?.message == "problem", "error context publishes together")
        f.reset(); f.state.setShellError("problem")
        try c.require(f.publications.isEmpty, "identical error plus context is silent")
        f.state.setRecoveryIssue(nil); f.reset(); f.state.setShellError("problem")
        try c.require(f.publications.count == 1 && f.view.recoveryIssue != nil, "equal text must restore dismissed context")
        f.state.setRecoveryIssue(.init(kind: .failedSource(canSkip: true), message: "other")); f.reset()
        f.state.setShellError("problem")
        try c.require(f.publications.count == 1 && f.view.recoveryIssue?.kind == .message, "equal text replaces different context")
        f.reset(); f.state.setShellError(nil)
        try c.require(f.publications.count == 1 && f.view.shellError == nil && f.view.recoveryIssue != nil,
                      "clearing shell text must not silently clear persistent recovery")
        return c.count
    }
    static func noOpAdjustmentObservation() throws -> Int {
        let c = Checks(), f = Fixture(), sourceChanges = ObservationCounter(), viewChanges = ObservationCounter()
        withObservationTracking { _ = f.state.videoAdjustments } onChange: { sourceChanges.increment() }
        withObservationTracking { _ = f.view.videoAdjustments } onChange: { viewChanges.increment() }
        var invocations = 0
        f.state.updateVideoAdjustments { value in invocations += 1; value.brightness = 0 }
        try c.require(invocations == 1, "mutation closure still executes exactly once")
        try c.require(f.publications.isEmpty && sourceChanges.value == 0 && viewChanges.value == 0,
                      "no-op inout closure must not emit Observation invalidations")
        f.state.updateVideoAdjustments { $0.brightness = 0.5 }
        try c.require(sourceChanges.value == 1 && viewChanges.value == 1 && f.publications.count == 1, "real adjustment observed")
        return c.count
    }
    static func authorityAndObservationControl() throws -> Int {
        let c = Checks(), f = Fixture(), trackChanges = ObservationCounter(), positionChanges = ObservationCounter()
        f.state.updateTrackCatalog([MediaTrack(id: 1, kind: .audio)])
        f.state.applyAuthorityProjection(projection(audio: 1)); f.reset()
        withObservationTracking { _ = f.view.audioTracks } onChange: { trackChanges.increment() }
        withObservationTracking { _ = f.view.position } onChange: { positionChanges.increment() }
        for n in 2...1001 { f.state.applyAuthorityProjection(projection(position: Double(n), audio: 1)) }
        try c.require(f.publications.count == 1000, "no position samples dropped or delayed")
        try c.require(f.view.position == 1001 && positionChanges.value == 1, "Observation tracks one-shot position subscription")
        try c.require(trackChanges.value == 0, "position does not invalidate track-only observers")
        f.reset(); f.state.applyAuthorityProjection(projection(position: 1001, audio: 1))
        try c.require(f.publications.isEmpty, "existing projection equality guard retained")
        return c.count
    }
    static func invalidValueSemantics() throws -> Int {
        let c = Checks(), f = Fixture()
        f.state.applyAuthorityProjection(projection(position: 10, duration: 50, delay: 2))
        f.state.applyAuthorityProjection(projection(position: .nan, duration: -.infinity, delay: .nan))
        try c.require(f.view.position == 10 && f.view.duration == 50 && f.view.subtitleDelay == 0, "invalid projection normalization retained")
        f.state.updateVideoAspectRatio(2); f.state.updateVideoAspectRatio(.infinity)
        try c.require(f.view.videoAspectRatio == nil, "invalid ratio clears")
        f.state.setAudioDelay(4); f.state.setAudioDelay(.nan)
        try c.require(f.view.audioDelay == 0, "invalid delay becomes zero")
        // These setters never sanitized their input. Avoid adding new policy.
        f.state.setVolume(.nan); try c.require(f.state.volume.isNaN && f.view.volume.isNaN, "volume NaN semantics unchanged")
        f.state.setPlaybackSpeed(.infinity); try c.require(f.view.playbackSpeed == .infinity, "speed infinity semantics unchanged")
        f.state.setVolume(50); f.state.setPlaybackSpeed(1)
        try c.require(f.view.snapshot == PlaybackViewSnapshot(state: f.state), "finite values recover")
        return c.count
    }
    static func reentrantCallback() throws -> Int {
        let c = Checks(), state = PlaybackState()
        var calls = 0
        state.onMutation = {
            calls += 1
            if !state.isMuted { state.setMuted(true) }
        }
        state.updateChapters([.init(id: 1, title: nil, startTime: 0)], currentID: 1)
        try c.require(calls == 2 && state.isMuted, "callback mutation is delivered without losing nesting state")
        state.setMuted(true); try c.require(calls == 2, "no pending batch flag leaks")
        state.setVolume(20); try c.require(calls == 3, "later independent update is delivered")
        state.onMutation = nil // intentionally break this test's strong capture
        return c.count
    }
    static func snapshotIsolation() throws -> Int {
        let c = Checks(), f = Fixture()
        f.state.recordDiagnostic("old"); let old = f.view.snapshot
        f.state.recordDiagnostic("new")
        try c.require(old.recentDiagnosticMessages == ["old"], "published value snapshot remains immutable")
        f.state.updateChapters([.init(id: 1,title: "A",startTime: 0)],currentID: 1)
        let chapterSnapshot = f.view.snapshot
        f.state.updateChapters([.init(id: 2,title: "B",startTime: 2)],currentID: 2)
        try c.require(chapterSnapshot.chapters.first?.title == "A" && chapterSnapshot.currentChapterID == 1, "catalogue/ID snapshot isolation")
        return c.count
    }
    static func metadataLifecycle() throws -> Int {
        let c = Checks(), f = Fixture()
        let urls = [URL(fileURLWithPath: "/synthetic/a.mkv"), URL(fileURLWithPath: "/synthetic/b.mkv")]
        f.state.configurePlaylist(folder: urls[0].deletingLastPathComponent(), items: urls.map { FolderPlaylistItem(url: $0) }, selectedIndex: 9)
        try c.require(f.view.currentPlaylistIndex == nil, "out-of-range playlist index remains nil")
        f.state.applyAuthorityProjection(projection(position: 30, duration: 100))
        f.state.prepareLoadMetadata(request: MediaLoadRequest(source: .localFile(urls[0]),origin: .userSelected)!,playlistIndex: 0)
        try c.require(f.view.currentSource == .localFile(urls[0]) && f.view.position == 30 && f.view.phase == .playing,
                      "shell reset does not take over authority fields")
        f.state.updateTrackCatalog([.init(id: 1, kind: .audio)])
        f.state.recordDiagnostic("retained across source close"); f.reset()
        f.state.clearMediaMetadata()
        try c.require(f.publications.count == 1 && f.view.currentSource == nil && f.view.playlist.isEmpty, "existing metadata batch retained")
        try c.require(f.view.position == 30 && f.view.phase == .playing && f.view.recentDiagnosticMessages.count == 1, "existing close retention contract")
        return c.count
    }
    static func weakConnectionLifetime() throws -> Int {
        let c = Checks()
        weak var state: PlaybackState?
        weak var view: PlaybackViewStore?
        do { let f = Fixture(); state = f.state; view = f.view; f.state.setMuted(true) }
        try c.require(state == nil && view == nil, "publication connection does not retain its graph")
        return c.count
    }
    static var scenarios: [(String, @MainActor () throws -> Int)] {
        [("scalar_noops", scalarNoOps), ("chapters", chapterTransaction),
         ("devices", deviceTransaction), ("tracks", trackTransaction),
         ("diagnostics", diagnosticTransaction), ("filters", filterTransaction),
         ("shell_error", shellErrorRecovery), ("adjustment_observation", noOpAdjustmentObservation),
         ("authority_control", authorityAndObservationControl), ("invalid_values", invalidValueSemantics),
         ("reentrant_callback", reentrantCallback), ("snapshot_isolation", snapshotIsolation),
         ("metadata_lifecycle", metadataLifecycle), ("weak_lifetime", weakConnectionLifetime)]
    }
}

#if !PORTABLE_STATE_TESTS
final class PlaybackStatePublicationTests: XCTestCase {
    func testScalarNoOps() async throws { _ = try await PlaybackStatePublicationChecks.scalarNoOps() }
    func testChapterTransaction() async throws { _ = try await PlaybackStatePublicationChecks.chapterTransaction() }
    func testDeviceTransaction() async throws { _ = try await PlaybackStatePublicationChecks.deviceTransaction() }
    func testTrackTransaction() async throws { _ = try await PlaybackStatePublicationChecks.trackTransaction() }
    func testDiagnosticTransaction() async throws { _ = try await PlaybackStatePublicationChecks.diagnosticTransaction() }
    func testFilterTransaction() async throws { _ = try await PlaybackStatePublicationChecks.filterTransaction() }
    func testShellErrorRecovery() async throws { _ = try await PlaybackStatePublicationChecks.shellErrorRecovery() }
    func testAdjustmentObservation() async throws { _ = try await PlaybackStatePublicationChecks.noOpAdjustmentObservation() }
    func testAuthorityControl() async throws { _ = try await PlaybackStatePublicationChecks.authorityAndObservationControl() }
    func testInvalidValueSemantics() async throws { _ = try await PlaybackStatePublicationChecks.invalidValueSemantics() }
    func testReentrantCallback() async throws { _ = try await PlaybackStatePublicationChecks.reentrantCallback() }
    func testSnapshotIsolation() async throws { _ = try await PlaybackStatePublicationChecks.snapshotIsolation() }
    func testMetadataLifecycle() async throws { _ = try await PlaybackStatePublicationChecks.metadataLifecycle() }
    func testWeakConnectionLifetime() async throws { _ = try await PlaybackStatePublicationChecks.weakConnectionLifetime() }
}
#endif
