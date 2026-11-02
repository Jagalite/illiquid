import Foundation
import IlliquidCore

struct SavedTrackMatchCase {
    let label: String
    let preference: MediaTrackPreference
    let tracks: [MediaTrack]
}

enum SavedTrackMatchCorpus {
    static func make() throws -> [SavedTrackMatchCase] {
        var result: [SavedTrackMatchCase] = []
        let ids: [(Int64, Int64)] = [
            (3, 7), (7, 3), (7, 7), (3, 3), (0, -1),
            (.min, .max), (.max, .min),
        ]
        for kind in MediaTrackKind.allCases {
            for external in [false, true] {
                let saved = richPreference(kind: kind, external: external)
                for left in 0..<32 {
                    for right in 0..<32 {
                        let pair = ids[(left * 32 + right) % ids.count]
                        let first = maskedTrack(mask: left, id: pair.0, kind: kind,
                                                external: external, marker: false)
                        let second = maskedTrack(mask: right, id: pair.1, kind: kind,
                                                 external: external, marker: true)
                        for (order, tracks) in [[first, second], [second, first]].enumerated() {
                            result.append(SavedTrackMatchCase(
                                label: "scores-\(kind)-\(external)-\(left)-\(right)-\(order)",
                                preference: saved, tracks: tracks))
                        }
                    }
                }

                // Every nil/non-nil preference-field combination, including
                // old JSON payloads without a saved track ID.
                for mask in 0..<16 {
                    let preference = MediaTrackPreference(track: MediaTrack(
                        id: 7, kind: kind,
                        title: mask & 1 != 0 ? "Commentary" : nil,
                        languageCode: mask & 2 != 0 ? "eng" : nil,
                        codec: mask & 4 != 0 ? "aac" : nil,
                        isExternal: external,
                        externalFilename: mask & 8 != 0 ? "/media/commentary.srt" : nil))
                    var object = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(preference)) as! [String: Any]
                    object.removeValue(forKey: "trackID")
                    let legacy = try JSONDecoder().decode(MediaTrackPreference.self,
                        from: JSONSerialization.data(withJSONObject: object))
                    let tracks = (0..<32).map {
                        maskedTrack(mask: $0, id: Int64($0 - 8), kind: kind,
                                    external: external, marker: $0 % 2 == 0)
                    }
                    for (version, saved) in [preference, legacy].enumerated() {
                        for (order, values) in [tracks, Array(tracks.reversed())].enumerated() {
                            result.append(SavedTrackMatchCase(
                                label: "optional-\(kind)-\(external)-\(mask)-\(version)-\(order)",
                                preference: saved, tracks: values))
                        }
                    }
                }
                result.append(SavedTrackMatchCase(label: "empty-\(kind)-\(external)",
                                                  preference: saved, tracks: []))
                let otherKind: MediaTrackKind = kind == .audio ? .subtitle : .audio
                result.append(SavedTrackMatchCase(
                    label: "wrong-kind-\(kind)-\(external)", preference: saved,
                    tracks: [maskedTrack(mask: 31, id: 7, kind: otherKind,
                                         external: external, marker: true)]))
                let zero = maskedTrack(mask: 0, id: 7, kind: kind,
                                       external: external, marker: false)
                result.append(SavedTrackMatchCase(
                    label: "zero-score-saved-id-\(kind)-\(external)", preference: saved,
                    tracks: [zero]))
            }
        }

        // Decoding bypasses MediaTrack.init's whitespace/empty-string trimming.
        let rawPreference = try JSONDecoder().decode(MediaTrackPreference.self, from: Data(
            #"{"kind":"audio","trackID":5,"title":"","languageCode":" ","codec":"","isExternal":false,"externalFilename":""}"#.utf8))
        let rawTracks = try JSONDecoder().decode([MediaTrack].self, from: Data(
            #"[{"id":5,"kind":"audio","title":null,"languageCode":null,"codec":null,"isDefault":false,"isForced":false,"isExternal":false,"externalFilename":null},{"id":9,"kind":"audio","title":"","languageCode":" ","codec":"","isDefault":true,"isForced":true,"isExternal":false,"externalFilename":""}]"#.utf8))
        result.append(SavedTrackMatchCase(label: "decoded-raw-empty-metadata",
                                          preference: rawPreference, tracks: rawTracks))
        result.append(SavedTrackMatchCase(label: "decoded-raw-empty-metadata-reversed",
                                          preference: rawPreference, tracks: Array(rawTracks.reversed())))

        let unicode = MediaTrackPreference(track: MediaTrack(id: 7, kind: .audio, title: "Café"))
        let decomposed = MediaTrack(id: 3, kind: .audio, title: "Cafe\u{0301}", isForced: true)
        let composed = MediaTrack(id: 3, kind: .audio, title: "Caf\u{00E9}", isDefault: true)
        result.append(SavedTrackMatchCase(label: "unicode-first-decomposed",
                                          preference: unicode, tracks: [decomposed, composed]))
        result.append(SavedTrackMatchCase(label: "unicode-first-composed",
                                          preference: unicode, tracks: [composed, decomposed]))
        return result
    }

    static func richPreference(kind: MediaTrackKind, external: Bool) -> MediaTrackPreference {
        MediaTrackPreference(track: MediaTrack(
            id: 7, kind: kind, title: "Commentary", languageCode: "eng", codec: "aac",
            isExternal: external, externalFilename: "/media/commentary.srt"))
    }

    static func maskedTrack(mask: Int, id: Int64, kind: MediaTrackKind,
                            external: Bool, marker: Bool) -> MediaTrack {
        MediaTrack(
            id: id, kind: kind,
            title: mask & 1 != 0 ? "Commentary" : "Other",
            languageCode: mask & 2 != 0 ? "eng" : "jpn",
            codec: mask & 4 != 0 ? "aac" : "other",
            isDefault: marker, isForced: !marker,
            isExternal: mask & 8 != 0 ? external : !external,
            externalFilename: mask & 16 != 0 ? "/media/commentary.srt" : "/media/other.srt")
    }

    /// Independent ordered-rank model: score, saved-ID membership, signed ID,
    /// then original offset. It deliberately uses sorting rather than a winner loop.
    static func expected(_ value: SavedTrackMatchCase) -> MediaTrack? {
        let preference = value.preference
        var ranked: [(index: Int, score: Int, savedID: Bool, id: Int64)] = []
        for (index, track) in value.tracks.enumerated() where track.kind == preference.kind {
            let fields: [(String?, String?, Int)] = [
                (preference.externalFilename, track.externalFilename, 16),
                (preference.title, track.title, 8),
                (preference.languageCode, track.languageCode, 4),
                (preference.codec, track.codec, 2),
            ]
            let score = fields.reduce(preference.isExternal == track.isExternal ? 2 : 0) {
                total, field in
                total + (field.0 != nil && field.0 == field.1 ? field.2 : 0)
            }
            if score > 0 {
                ranked.append((index, score, preference.trackID == track.id, track.id))
            }
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.savedID != $1.savedID { return $0.savedID }
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.index < $1.index
        }
        return ranked.first.map { value.tracks[$0.index] }
    }

    static func receipt(_ track: MediaTrack?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(track)
    }
}
