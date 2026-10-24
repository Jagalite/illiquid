import Foundation
import Observation
@testable import IlliquidCore
#if !PORTABLE_STATE_TESTS
import XCTest
#endif

// These scenario bodies also run in the standalone actual-source benchmark.
@MainActor
enum TrackSelectionProjectionChecks {
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

        func requireSelection(
            audio: MediaTrack?, subtitle: MediaTrack?, using checks: Checks
        ) throws {
            try checks.require(state.selectedAudioTrack == audio, "audio selection matches authority and current catalogue")
            try checks.require(state.selectedSubtitleTrack == subtitle, "subtitle selection matches authority and current catalogue")
            try checks.require(view.selectedAudioTrack == audio && view.selectedSubtitleTrack == subtitle,
                               "observable selections agree with the state")
            try checks.require(view.snapshot == PlaybackViewSnapshot(state: state),
                               "complete view snapshot agrees with the state")
        }
    }

    static func projection(
        audio: Int64? = nil, subtitle: Int64? = nil, position: Double = 1
    ) -> PlaybackAuthorityProjection {
        .init(phase: .playing, position: position, duration: 3_600,
              isBuffering: false, selectedAudioID: audio, selectedSubtitleID: subtitle,
              subtitleDelay: 0, failureCode: nil, isPauseDesired: false)
    }

    static func steadyLateSelectionsPublishEveryPosition() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = (0..<128).map { MediaTrack(id: Int64($0), kind: .audio, title: "Audio \($0)") }
        let subtitles = (0..<128).map { MediaTrack(id: Int64($0), kind: .subtitle, title: "Subtitle \($0)") }
        f.state.updateTrackCatalog(audio + subtitles)
        f.state.applyAuthorityProjection(projection(audio: 127, subtitle: 127))
        let original = f.view.snapshot
        f.publications.removeAll()
        for position in 2...257 {
            f.state.applyAuthorityProjection(projection(audio: 127, subtitle: 127, position: Double(position)))
            try f.requireSelection(audio: audio.last, subtitle: subtitles.last, using: c)
            try c.require(f.view.position == Double(position), "every new position is visible synchronously")
        }
        try c.require(f.publications.count == 256, "one complete publication per changed position")
        try c.require(original.position == 1 && original.selectedAudioTrack == audio.last,
                      "previously published snapshots remain unchanged")
        f.publications.removeAll()
        f.state.applyAuthorityProjection(projection(audio: 127, subtitle: 127, position: 257))
        try c.require(f.publications.isEmpty, "identical projection remains silent")
        return c.count
    }

    static func nilAndSelectionChanges() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = MediaTrack(id: 5, kind: .audio)
        let subtitle = MediaTrack(id: 6, kind: .subtitle)
        f.state.updateTrackCatalog([audio, subtitle])
        for (audioID, subtitleID) in [(nil, nil), (5, 6), (nil, 6), (5, nil), (nil, nil)] as [(Int64?, Int64?)] {
            f.state.applyAuthorityProjection(projection(audio: audioID, subtitle: subtitleID))
            try f.requireSelection(audio: audioID == nil ? nil : audio,
                                   subtitle: subtitleID == nil ? nil : subtitle, using: c)
        }
        f.publications.removeAll()
        f.state.applyAuthorityProjection(projection(audio: -20, subtitle: Int64.max))
        f.state.applyAuthorityProjection(projection(audio: -20, subtitle: Int64.max))
        f.state.applyAuthorityProjection(projection())
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        try c.require(f.publications.isEmpty, "different absent IDs do not publish unchanged nil selections")
        return c.count
    }

    static func missingIDsBecomeAvailable() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = MediaTrack(id: 42, kind: .audio, title: "Arrived audio")
        let subtitle = MediaTrack(id: 43, kind: .subtitle, title: "Arrived subtitle")
        f.state.updateTrackCatalog([.init(id: 1, kind: .audio), .init(id: 2, kind: .subtitle)])
        for _ in 0..<3 {
            f.state.applyAuthorityProjection(projection(audio: 42, subtitle: 43))
        }
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        f.state.audioTracks.append(audio)
        f.state.subtitleTracks.append(subtitle)
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        f.state.applyAuthorityProjection(projection(audio: 42, subtitle: 43))
        try f.requireSelection(audio: audio, subtitle: subtitle, using: c)
        f.state.audioTracks.removeLast()
        f.state.subtitleTracks.removeLast()
        try f.requireSelection(audio: audio, subtitle: subtitle, using: c)
        f.state.applyAuthorityProjection(projection(audio: 42, subtitle: 43))
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        f.state.updateTrackCatalog([audio, subtitle])
        f.state.applyAuthorityProjection(projection(audio: 42, subtitle: 43))
        try f.requireSelection(audio: audio, subtitle: subtitle, using: c)
        return c.count
    }

    static func sameIDMetadataRefreshWaitsForAuthority() throws -> Int {
        let c = Checks(), f = Fixture()
        let original = MediaTrack(id: 7, kind: .audio, title: "Original", languageCode: "en", codec: "aac")
        let changed = MediaTrack(id: 7, kind: .audio, title: "Replacement", languageCode: "ja", codec: "flac")
        let subtitle = MediaTrack(id: 8, kind: .subtitle, title: "Original subtitle")
        let changedSubtitle = MediaTrack(id: 8, kind: .subtitle, title: "Replacement subtitle", isExternal: true)
        f.state.updateTrackCatalog([original, subtitle])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 8)) }
        f.state.updateTrackCatalog([changed, changedSubtitle])
        try f.requireSelection(audio: original, subtitle: subtitle, using: c)
        try c.require(f.view.audioTracks == [changed] && f.view.subtitleTracks == [changedSubtitle],
                      "catalogue updates publish independently of selected metadata")
        f.publications.removeAll()
        f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 8))
        try f.requireSelection(audio: changed, subtitle: changedSubtitle, using: c)
        try c.require(f.publications.count == 1, "both refreshed selections publish together")
        return c.count
    }

    static func inPlaceMutationPreservesFirstDuplicate() throws -> Int {
        let c = Checks(), f = Fixture()
        let first = MediaTrack(id: 7, kind: .audio, title: "First")
        let second = MediaTrack(id: 7, kind: .audio, title: "Second")
        let subtitle = MediaTrack(id: 7, kind: .subtitle, title: "Subtitle")
        let otherSubtitle = MediaTrack(id: 7, kind: .subtitle, title: "Earlier subtitle")
        f.state.updateTrackCatalog([first, second, subtitle])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 7)) }
        f.state.audioTracks.swapAt(0, 1)
        f.state.subtitleTracks.insert(otherSubtitle, at: 0)
        try f.requireSelection(audio: first, subtitle: subtitle, using: c)
        f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 7))
        try f.requireSelection(audio: second, subtitle: otherSubtitle, using: c)
        let edited = MediaTrack(id: 7, kind: .audio, title: "Edited in place")
        f.state.audioTracks[0] = edited
        f.state.applyAuthorityProjection(projection(audio: 7, subtitle: 7))
        try f.requireSelection(audio: edited, subtitle: otherSubtitle, using: c)
        return c.count
    }

    static func independentAudioAndSubtitleCatalogues() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = MediaTrack(id: 11, kind: .audio, title: "Audio")
        let subtitle = MediaTrack(id: 11, kind: .subtitle, title: "Subtitle")
        f.state.updateTrackCatalog([audio, subtitle])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 11, subtitle: 11)) }
        f.state.audioTracks = []
        f.state.applyAuthorityProjection(projection(audio: 11, subtitle: 11))
        try f.requireSelection(audio: nil, subtitle: subtitle, using: c)
        f.state.audioTracks = [audio]
        f.state.subtitleTracks = []
        f.state.applyAuthorityProjection(projection(audio: 11, subtitle: 11))
        try f.requireSelection(audio: audio, subtitle: nil, using: c)
        return c.count
    }

    static func metadataResetsInvalidateResolvedSelections() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = MediaTrack(id: 3, kind: .audio, title: "First source")
        let subtitle = MediaTrack(id: 4, kind: .subtitle)
        f.state.updateTrackCatalog([audio, subtitle])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 3, subtitle: 4)) }
        guard let request = MediaLoadRequest(source: .localFile(URL(fileURLWithPath: "/synthetic/new-source.mkv")),
                                            origin: .userSelected) else {
            throw Failure(description: "valid local load request")
        }
        f.state.prepareLoadMetadata(request: request, playlistIndex: 0)
        try f.requireSelection(audio: audio, subtitle: subtitle, using: c)
        f.state.applyAuthorityProjection(projection(audio: 3, subtitle: 4))
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        let replacement = MediaTrack(id: 3, kind: .audio, title: "Second source")
        f.state.updateTrackCatalog([replacement, subtitle])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 3, subtitle: 4)) }
        try f.requireSelection(audio: replacement, subtitle: subtitle, using: c)
        f.state.clearMediaMetadata()
        try f.requireSelection(audio: replacement, subtitle: subtitle, using: c)
        f.state.applyAuthorityProjection(projection(audio: 3, subtitle: 4))
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        f.state.updateTrackCatalog([audio, subtitle])
        f.state.applyAuthorityProjection(projection(audio: 3, subtitle: 4))
        try f.requireSelection(audio: audio, subtitle: subtitle, using: c)
        return c.count
    }

    static func directSelectedWritesAreReconciled() throws -> Int {
        let c = Checks(), f = Fixture()
        let audio = MediaTrack(id: 5, kind: .audio, title: "Catalogue audio")
        let subtitle = MediaTrack(id: 6, kind: .subtitle, title: "Catalogue subtitle")
        f.state.updateTrackCatalog([audio, subtitle])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 5, subtitle: 6)) }
        f.state.selectedAudioTrack = MediaTrack(id: 5, kind: .audio, title: "Outdated audio")
        f.state.selectedSubtitleTrack = MediaTrack(id: 6, kind: .subtitle, title: "Outdated subtitle")
        f.state.applyAuthorityProjection(projection(audio: 5, subtitle: 6))
        try f.requireSelection(audio: audio, subtitle: subtitle, using: c)
        f.state.applyAuthorityProjection(projection())
        f.state.applyAuthorityProjection(projection())
        f.state.selectedAudioTrack = audio
        f.state.selectedSubtitleTrack = subtitle
        f.state.applyAuthorityProjection(projection())
        try f.requireSelection(audio: nil, subtitle: nil, using: c)
        return c.count
    }

    static func synchronousObservationMutationIsNotLost() throws -> Int {
        let c = Checks(), f = Fixture()
        let old = MediaTrack(id: 1, kind: .audio, title: "Previously selected")
        let requested = MediaTrack(id: 2, kind: .audio, title: "Original requested metadata")
        let replacement = MediaTrack(id: 2, kind: .audio, title: "Metadata from synchronous callback")
        f.state.updateTrackCatalog([old, requested])
        for _ in 0..<3 { f.state.applyAuthorityProjection(projection(audio: 1)) }
        withObservationTracking {
            _ = f.state.selectedAudioTrack
        } onChange: {
            MainActor.assumeIsolated { f.state.audioTracks = [replacement] }
        }
        f.state.applyAuthorityProjection(projection(audio: 2))
        try c.require(f.state.audioTracks == [replacement], "Observation callback changed the catalogue synchronously")
        // The first projection already resolved its old catalogue before the
        // will-change callback. Its successor must see the callback's update.
        f.state.applyAuthorityProjection(projection(audio: 2))
        try f.requireSelection(audio: replacement, subtitle: nil, using: c)
        return c.count
    }

    static func catalogueMutationCallbackSeesInvalidation() throws -> Int {
        let c = Checks(), state = PlaybackState()
        let original = MediaTrack(id: 9, kind: .subtitle, title: "Original")
        let replacement = MediaTrack(id: 9, kind: .subtitle, title: "Replacement")
        state.updateTrackCatalog([original])
        for _ in 0..<3 { state.applyAuthorityProjection(projection(subtitle: 9)) }
        var didProjectFromCallback = false
        state.onMutation = {
            guard !didProjectFromCallback else { return }
            didProjectFromCallback = true
            state.applyAuthorityProjection(projection(subtitle: 9))
        }
        state.subtitleTracks = [replacement]
        state.onMutation = nil
        try c.require(didProjectFromCallback, "catalogue setter delivered its synchronous mutation callback")
        try c.require(state.selectedSubtitleTrack == replacement,
                      "resolution was invalidated before the mutation callback")
        return c.count
    }

    static var scenarios: [(String, @MainActor () throws -> Int)] {
        [
            ("steady_late_selections", steadyLateSelectionsPublishEveryPosition),
            ("nil_and_selection_changes", nilAndSelectionChanges),
            ("missing_ids_become_available", missingIDsBecomeAvailable),
            ("same_id_metadata", sameIDMetadataRefreshWaitsForAuthority),
            ("in_place_duplicate_order", inPlaceMutationPreservesFirstDuplicate),
            ("independent_catalogues", independentAudioAndSubtitleCatalogues),
            ("metadata_resets", metadataResetsInvalidateResolvedSelections),
            ("direct_selected_writes", directSelectedWritesAreReconciled),
            ("synchronous_observation_mutation", synchronousObservationMutationIsNotLost),
            ("catalogue_mutation_callback", catalogueMutationCallbackSeesInvalidation),
        ]
    }
}

#if !PORTABLE_STATE_TESTS
final class TrackSelectionProjectionTests: XCTestCase {
    func testSteadyLateSelections() async throws { _ = try await TrackSelectionProjectionChecks.steadyLateSelectionsPublishEveryPosition() }
    func testNilAndSelectionChanges() async throws { _ = try await TrackSelectionProjectionChecks.nilAndSelectionChanges() }
    func testMissingIDsBecomeAvailable() async throws { _ = try await TrackSelectionProjectionChecks.missingIDsBecomeAvailable() }
    func testSameIDMetadata() async throws { _ = try await TrackSelectionProjectionChecks.sameIDMetadataRefreshWaitsForAuthority() }
    func testInPlaceDuplicateOrder() async throws { _ = try await TrackSelectionProjectionChecks.inPlaceMutationPreservesFirstDuplicate() }
    func testIndependentCatalogues() async throws { _ = try await TrackSelectionProjectionChecks.independentAudioAndSubtitleCatalogues() }
    func testMetadataResets() async throws { _ = try await TrackSelectionProjectionChecks.metadataResetsInvalidateResolvedSelections() }
    func testDirectSelectedWrites() async throws { _ = try await TrackSelectionProjectionChecks.directSelectedWritesAreReconciled() }
    func testSynchronousObservationMutation() async throws { _ = try await TrackSelectionProjectionChecks.synchronousObservationMutationIsNotLost() }
    func testCatalogueMutationCallback() async throws { _ = try await TrackSelectionProjectionChecks.catalogueMutationCallbackSeesInvalidation() }
}
#endif
