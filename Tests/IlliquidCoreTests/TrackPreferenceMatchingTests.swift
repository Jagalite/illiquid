import Foundation
import Testing
@testable import IlliquidCore

@Suite("Saved track preference matching")
struct TrackPreferenceMatchingTests {
    @Test(arguments: MediaTrackKind.allCases)
    func savedIDAndPresentationFlagsCannotCreateAnEligibleMatch(kind: MediaTrackKind) {
        let preference = MediaTrackPreference(track: MediaTrack(
            id: 7, kind: kind, isExternal: true
        ))
        let noMetadataMatch = MediaTrack(
            id: 7, kind: kind, isDefault: true, isForced: true
        )
        let wrongKind = MediaTrack(
            id: 7, kind: kind == .audio ? .subtitle : .audio, isExternal: true
        )
        #expect(preference.bestMatch(in: []) == nil)
        #expect(preference.bestMatch(in: [noMetadataMatch]) == nil)
        #expect(preference.bestMatch(in: [wrongKind, noMetadataMatch]) == nil)
        #expect(preference.bestMatch(in: [noMetadataMatch, wrongKind]) == nil)
    }

    @Test func externalFilenameOutranksAllOtherMetadataTogether() {
        let preference = MediaTrackPreference(track: MediaTrack(
            id: 7, kind: .subtitle, title: "Commentary", languageCode: "eng",
            codec: "subrip", isExternal: true, externalFilename: "/subs/show.srt"
        ))
        let filenameMatch = MediaTrack(
            id: 99, kind: .subtitle, isExternal: true,
            externalFilename: "/subs/show.srt"
        )
        let reusedID = MediaTrack(
            id: 7, kind: .subtitle, title: "Commentary", languageCode: "eng",
            codec: "subrip", isDefault: true, isForced: true, isExternal: true,
            externalFilename: "/subs/another.srt"
        )
        #expect(preference.bestMatch(in: [reusedID, filenameMatch]) == filenameMatch)
        #expect(preference.bestMatch(in: [filenameMatch, reusedID]) == filenameMatch)
    }

    @Test func titleOutranksLanguageAndCodecAtTheSameOrigin() {
        let preference = MediaTrackPreference(track: MediaTrack(
            id: 7, kind: .audio, title: "Commentary", languageCode: "eng", codec: "aac"
        ))
        let titleMatch = MediaTrack(id: 99, kind: .audio, title: "Commentary")
        let otherMetadata = MediaTrack(id: 7, kind: .audio, languageCode: "eng", codec: "aac")
        #expect(preference.bestMatch(in: [otherMetadata, titleMatch]) == titleMatch)
        #expect(preference.bestMatch(in: [titleMatch, otherMetadata]) == titleMatch)
    }

    @Test func languageOutranksCodecAtTheSameOrigin() {
        let preference = MediaTrackPreference(track: MediaTrack(
            id: 7, kind: .audio, languageCode: "eng", codec: "aac"
        ))
        let languageMatch = MediaTrack(id: 99, kind: .audio, languageCode: "eng")
        let codecMatch = MediaTrack(id: 7, kind: .audio, codec: "aac")
        #expect(preference.bestMatch(in: [codecMatch, languageMatch]) == languageMatch)
        #expect(preference.bestMatch(in: [languageMatch, codecMatch]) == languageMatch)
    }

    @Test func codecAndOriginTiesUseSavedIDThenLowestID() {
        let codecMatch = MediaTrack(id: 9, kind: .subtitle, codec: "ass")
        let originMatch = MediaTrack(id: 1, kind: .subtitle, isExternal: true)
        let saved = MediaTrackPreference(track: MediaTrack(
            id: 9, kind: .subtitle, codec: "ass", isExternal: true
        ))
        let absentID = MediaTrackPreference(track: MediaTrack(
            id: 100, kind: .subtitle, codec: "ass", isExternal: true
        ))
        for tracks in [[codecMatch, originMatch], [originMatch, codecMatch]] {
            #expect(saved.bestMatch(in: tracks) == codecMatch)
            #expect(absentID.bestMatch(in: tracks) == originMatch)
        }
    }

    @Test func completeTiesPreserveTheFirstWholeTrack() {
        let plain = MediaTrack(
            id: 7, kind: .subtitle, title: "English", languageCode: "eng", codec: "ass"
        )
        let flagged = MediaTrack(
            id: 7, kind: .subtitle, title: "English", languageCode: "eng", codec: "ass",
            isDefault: true, isForced: true
        )
        let preference = MediaTrackPreference(track: plain)
        #expect(plain != flagged)
        #expect(preference.bestMatch(in: [plain, flagged]) == plain)
        #expect(preference.bestMatch(in: [flagged, plain]) == flagged)
    }

    @Test func duplicateIDsStillConsiderEachTracksMetadata() {
        let saved = MediaTrack(id: 7, kind: .audio, title: "Commentary", languageCode: "eng")
        let reused = MediaTrack(id: 7, kind: .audio, title: "Main", languageCode: "eng")
        let renumbered = MediaTrack(id: 99, kind: .audio, title: "Commentary", languageCode: "eng")
        let preference = MediaTrackPreference(track: saved)
        #expect(preference.bestMatch(in: [reused, renumbered, saved]) == saved)
        #expect(preference.bestMatch(in: [saved, renumbered, reused]) == saved)
        #expect(preference.bestMatch(in: [reused, renumbered]) == renumbered)
    }

    @Test(arguments: MediaTrackKind.allCases)
    func extremeSignedIDsPreserveSavedAndLegacyTieBreaks(kind: MediaTrackKind) throws {
        let low = MediaTrack(id: .min, kind: kind)
        let zero = MediaTrack(id: 0, kind: kind)
        let high = MediaTrack(id: .max, kind: kind)
        let saved = MediaTrackPreference(track: high)
        let legacyJSON = Data("{\"kind\":\"\(kind.rawValue)\",\"isExternal\":false}".utf8)
        let legacy = try JSONDecoder().decode(MediaTrackPreference.self, from: legacyJSON)
        #expect(legacy.trackID == nil)
        for tracks in [[low, zero, high], [high, zero, low]] {
            #expect(saved.bestMatch(in: tracks) == high)
            #expect(legacy.bestMatch(in: tracks) == low)
        }
        #expect(saved.bestMatch(in: [zero, low]) == low)
    }

    @Test func decodedEmptyMetadataRemainsDistinctFromMissingMetadata() throws {
        // Synthesized decoding preserves legacy empty strings. Matching must not
        // silently replace them with nil, trim them, or normalize language codes.
        let preference = try JSONDecoder().decode(MediaTrackPreference.self, from: Data(
            #"{"kind":"subtitle","title":"","languageCode":"","codec":"","isExternal":true,"externalFilename":""}"#.utf8
        ))
        let absent = MediaTrack(id: 1, kind: .subtitle)
        let trimmed = MediaTrack(
            id: 2, kind: .subtitle, title: " ", languageCode: "\n",
            codec: "", externalFilename: " "
        )
        let empty = try JSONDecoder().decode(MediaTrack.self, from: Data(
            #"{"id":3,"kind":"subtitle","title":"","languageCode":"","codec":"","isDefault":false,"isForced":false,"isExternal":false,"externalFilename":""}"#.utf8
        ))
        #expect(preference.trackID == nil)
        #expect(trimmed.title == nil)
        #expect(empty.title == "")
        #expect(preference.bestMatch(in: [absent, trimmed]) == nil)
        #expect(preference.bestMatch(in: [absent, empty, trimmed]) == empty)
        #expect(preference.bestMatch(in: [trimmed, empty, absent]) == empty)
    }

    @Test func matchingRetainsUnicodeEqualityAndCaseSensitiveMetadata() {
        let preference = MediaTrackPreference(track: MediaTrack(
            id: 7, kind: .subtitle, title: "Caf\u{00E9}", languageCode: "eng",
            codec: "ASS", isExternal: true, externalFilename: "/subs/Caf\u{00E9}.ass"
        ))
        let equivalent = MediaTrack(
            id: 99, kind: .subtitle, title: "Cafe\u{0301}", languageCode: "eng",
            codec: "ASS", isExternal: true, externalFilename: "/subs/Cafe\u{0301}.ass"
        )
        let differentCase = MediaTrack(
            id: 7, kind: .subtitle, title: "CAF\u{00C9}", languageCode: "ENG",
            codec: "ass", isExternal: true, externalFilename: "/subs/CAF\u{00C9}.ass"
        )
        #expect(preference.bestMatch(in: [differentCase, equivalent]) == equivalent)
        #expect(preference.bestMatch(in: [equivalent, differentCase]) == equivalent)
    }

    @Test func languageAliasesAreNotNormalizedDuringRestoration() {
        let preference = MediaTrackPreference(track: MediaTrack(
            id: 7, kind: .audio, languageCode: "eng"
        ))
        let alias = MediaTrack(id: 7, kind: .audio, languageCode: "en")
        let exact = MediaTrack(id: 99, kind: .audio, languageCode: "eng")
        #expect(preference.bestMatch(in: [alias, exact]) == exact)
        #expect(preference.bestMatch(in: [exact, alias]) == exact)
    }
}
