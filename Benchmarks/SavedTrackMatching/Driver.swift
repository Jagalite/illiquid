import Foundation
import IlliquidCore

enum DriverError: Error { case usage }

struct TimedTrackWorkload {
    let name: String
    let preference: MediaTrackPreference
    let orders: [[MediaTrack]]
}

@main
enum SavedTrackMatchingBenchmark {
    static let names = [
        "rich-0", "rich-1", "rich-2", "rich-8", "rich-32", "rich-128",
        "sparse-2", "sparse-8", "sparse-32",
        "mixed-audio-8", "mixed-audio-32", "external-8", "external-32",
        "zero-score-1", "zero-score-8", "wrong-kind-8", "saved-id-tie-8", "legacy-tie-8",
    ]

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["verify"] {
            try verify()
            return
        }
        guard arguments.count == 3, arguments[0] == "measure",
              let iterations = Int(arguments[2]), iterations > 0 else { throw DriverError.usage }
        let value = try workload(arguments[1])
        let warmup = consume(value, iterations: 64)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = consume(value, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try emit([
            "workload": value.name, "iterations": iterations, "elapsed_ns": elapsed,
            "checksum": result.checksum, "selected_count": result.selected,
            "warmup_checksum": warmup.checksum, "warmup_selected_count": warmup.selected,
        ])
    }

    @inline(never)
    private static func consume(_ value: TimedTrackWorkload, iterations: Int)
        -> (checksum: UInt64, selected: Int) {
        var checksum: UInt64 = 0
        var selected = 0
        for index in 0..<iterations {
            if let track = value.preference.bestMatch(in: value.orders[index % value.orders.count]) {
                checksum &+= UInt64(bitPattern: track.id)
                selected += 1
            }
        }
        return (checksum, selected)
    }

    private static func verify() throws {
        var rows: [[String: Any]] = []
        var mismatches = 0
        let cases = try SavedTrackMatchCorpus.make()
        for value in cases {
            let actual = try SavedTrackMatchCorpus.receipt(
                value.preference.bestMatch(in: value.tracks))
            let expected = try SavedTrackMatchCorpus.receipt(SavedTrackMatchCorpus.expected(value))
            if actual != expected { mismatches += 1 }
            rows.append([
                "label": value.label,
                "actual_base64": actual.base64EncodedString(),
                "expected_base64": expected.base64EncodedString(),
            ])
        }
        var timed: [[String: Any]] = []
        for name in names {
            let value = try workload(name)
            for (order, tracks) in value.orders.enumerated() {
                let fixture = SavedTrackMatchCase(label: name, preference: value.preference, tracks: tracks)
                let actual = try SavedTrackMatchCorpus.receipt(value.preference.bestMatch(in: tracks))
                let expected = try SavedTrackMatchCorpus.receipt(SavedTrackMatchCorpus.expected(fixture))
                if actual != expected { mismatches += 1 }
                timed.append([
                    "workload": name, "order": order, "track_count": tracks.count,
                    "actual_base64": actual.base64EncodedString(),
                    "expected_base64": expected.base64EncodedString(),
                ])
            }
        }
        try emit(["cases": cases.count, "oracle_mismatches": mismatches, "rows": rows,
                  "timed_fixture_count": timed.count, "timed_fixtures": timed])
    }

    private static func workload(_ name: String) throws -> TimedTrackWorkload {
        guard names.contains(name), let count = Int(name.split(separator: "-").last!) else {
            throw DriverError.usage
        }
        var preference = MediaTrackPreference(track: MediaTrack(
            id: 777, kind: .audio, title: "Commentary", languageCode: "eng", codec: "aac"))
        let tracks: [MediaTrack]
        if name.hasPrefix("rich-") {
            tracks = (0..<count).map { index in
                let best = index == count - 1
                return MediaTrack(id: index == 0 ? 777 : Int64(index + 1), kind: .audio,
                                  title: best ? "Commentary" : "Main \(index)",
                                  languageCode: best || index % 3 == 0 ? "eng" : "jpn", codec: "aac")
            }
        } else if name.hasPrefix("sparse-") {
            preference = MediaTrackPreference(track: MediaTrack(id: 777, kind: .audio))
            tracks = (0..<count).map { MediaTrack(id: Int64(1000 + count - $0), kind: .audio) }
        } else if name.hasPrefix("mixed-audio-") {
            tracks = (0..<count).map { index in
                let audio = index % 2 == 0
                let best = index == count - 2
                return MediaTrack(id: audio ? Int64(index + 1) : 777,
                                  kind: audio ? .audio : .subtitle,
                                  title: best || !audio ? "Commentary" : "Main",
                                  languageCode: "eng", codec: "aac")
            }
        } else if name.hasPrefix("external-") {
            preference = MediaTrackPreference(track: MediaTrack(
                id: 777, kind: .subtitle, title: "English captions", languageCode: "eng",
                codec: "subrip", isExternal: true, externalFilename: "/Media/Movie.en.srt"))
            tracks = (0..<count).map { index in
                let subtitle = index % 2 == 0
                let best = index == count - 2
                return MediaTrack(
                    id: subtitle ? Int64(index + 1) : 777, kind: subtitle ? .subtitle : .audio,
                    title: "English captions", languageCode: "eng", codec: "subrip",
                    isExternal: best || !subtitle || index % 4 != 0,
                    externalFilename: best || !subtitle ? "/Media/Movie.en.srt" : "/Media/Other.srt")
            }
        } else if name.hasPrefix("zero-score-") {
            tracks = (0..<count).map {
                MediaTrack(id: $0 == 0 ? 777 : Int64($0), kind: .audio,
                           title: "Other", languageCode: "jpn", codec: "opus", isExternal: true)
            }
        } else if name == "wrong-kind-8" {
            tracks = (0..<count).map {
                MediaTrack(id: Int64($0), kind: .subtitle,
                           title: "Commentary", languageCode: "eng", codec: "aac")
            }
        } else {
            tracks = (0..<count).map {
                MediaTrack(id: $0 == 5 ? 777 : Int64($0 + 1), kind: .audio,
                           title: "Commentary", languageCode: "eng", codec: "aac")
            }
            if name == "legacy-tie-8" {
                preference = try JSONDecoder().decode(MediaTrackPreference.self, from: Data(
                    #"{"kind":"audio","title":"Commentary","languageCode":"eng","codec":"aac","isExternal":false}"#.utf8))
            }
        }
        var shuffled = tracks
        var state: UInt64 = 0x1_11_1A
        if shuffled.count > 1 {
            for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                shuffled.swapAt(index, Int(state % UInt64(index + 1)))
            }
        }
        let middle = tracks.count / 2
        let rotated = Array(tracks.dropFirst(middle)) + Array(tracks.prefix(middle))
        return TimedTrackWorkload(name: name, preference: preference,
                                  orders: [tracks, Array(tracks.reversed()), rotated, shuffled])
    }

    private static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
