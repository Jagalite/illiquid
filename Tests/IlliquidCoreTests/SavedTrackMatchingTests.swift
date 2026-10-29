import Foundation
import Testing
@testable import IlliquidCore

@Suite("Saved track matching single-pass compatibility")
struct SavedTrackMatchingTests {
    @Test("Full results match an independent ordered-rank model")
    func exhaustiveScoreAndPreferenceCorpus() throws {
        let cases = try SavedTrackMatchCorpus.make()
        #expect(cases.count == 8_464)
        for value in cases {
            let actual = value.preference.bestMatch(in: value.tracks)
            let expected = SavedTrackMatchCorpus.expected(value)
            #expect(try SavedTrackMatchCorpus.receipt(actual) == SavedTrackMatchCorpus.receipt(expected),
                    "Case: \(value.label)")
        }
    }

    @Test("A saved ID does not make a zero-score track eligible")
    func zeroScoreSavedID() {
        let saved = MediaTrackPreference(track: MediaTrack(id: 7, kind: .audio, isExternal: false))
        let candidate = MediaTrack(id: 7, kind: .audio, isExternal: true)
        #expect(saved.bestMatch(in: [candidate]) == nil)
    }

    @Test("An early maximum score cannot bypass the saved ID tie-break")
    func maximumScoreStillUsesSavedID() {
        let saved = SavedTrackMatchCorpus.richPreference(kind: .subtitle, external: true)
        let first = SavedTrackMatchCorpus.maskedTrack(mask: 31, id: 1, kind: .subtitle,
                                                    external: true, marker: false)
        let savedID = SavedTrackMatchCorpus.maskedTrack(mask: 31, id: 7, kind: .subtitle,
                                                      external: true, marker: true)
        #expect(saved.bestMatch(in: [first, savedID]) == savedID)
        #expect(saved.bestMatch(in: [savedID, first]) == savedID)
    }

    @Test("A filename match ties the sum of all other match fields")
    func additiveScoresMustNotBecomeLexicographic() {
        let saved = SavedTrackMatchCorpus.richPreference(kind: .subtitle, external: true)
        let filenameOnly = SavedTrackMatchCorpus.maskedTrack(mask: 16, id: 1, kind: .subtitle,
                                                           external: true, marker: false)
        let otherFields = SavedTrackMatchCorpus.maskedTrack(mask: 15, id: 7, kind: .subtitle,
                                                          external: true, marker: true)
        #expect(saved.bestMatch(in: [filenameOnly, otherFields]) == otherFields)
        #expect(saved.bestMatch(in: [otherFields, filenameOnly]) == otherFields)
    }

    @Test("Equal score and duplicate IDs preserve the first complete track")
    func duplicateIDsKeepFirstValue() throws {
        let saved = MediaTrackPreference(track: MediaTrack(id: 7, kind: .audio, title: "Café"))
        let first = MediaTrack(id: 3, kind: .audio, title: "Cafe\u{0301}", isForced: true)
        let second = MediaTrack(id: 3, kind: .audio, title: "Caf\u{00E9}", isDefault: true)
        for tracks in [[first, second], [second, first]] {
            let actual = saved.bestMatch(in: tracks)
            #expect(try SavedTrackMatchCorpus.receipt(actual)
                    == SavedTrackMatchCorpus.receipt(tracks[0]))
        }
    }

    @Test("Lowest signed ID wins a legacy tie without arithmetic overflow")
    func signedIDExtremes() throws {
        let saved = try JSONDecoder().decode(MediaTrackPreference.self,
            from: Data(#"{"kind":"audio","isExternal":false}"#.utf8))
        let tracks = [Int64.max, 0, Int64.min].map { MediaTrack(id: $0, kind: .audio) }
        #expect(saved.bestMatch(in: tracks)?.id == .min)
        #expect(saved.bestMatch(in: Array(tracks.reversed()))?.id == .min)
    }
}
