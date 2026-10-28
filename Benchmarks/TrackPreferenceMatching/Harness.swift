import Foundation
import IlliquidCore

// Production bestMatch is linked from a separately optimized module. Construct
// and check complete outputs before timing; timed consumption uses IDs/flags.
private let workloadNames = MediaTrackKind.allCases.flatMap { kind in
    [0, 1, 2, 8, 32, 128, 1024].flatMap { count in
        ["metadata", "legacy"].map { "\(kind.rawValue)-\(count)-\($0)" }
    } + ["\(kind.rawValue)-wrong-kind", "\(kind.rawValue)-zero-score"]
}

private struct Input {
    let preference: MediaTrackPreference
    let tracks: [MediaTrack]
    let expected: MediaTrack?
}

private func legacy(_ preference: MediaTrackPreference) -> MediaTrackPreference {
    var object = try! JSONSerialization.jsonObject(
        with: JSONEncoder().encode(preference)) as! [String: Any]
    object.removeValue(forKey: "trackID")
    return try! JSONDecoder().decode(MediaTrackPreference.self,
        from: JSONSerialization.data(withJSONObject: object))
}

private func track(_ id: Int64, kind: MediaTrackKind, index: Int, rich: Bool) -> MediaTrack {
    MediaTrack(id: id, kind: kind, title: rich ? "Program \(index)" : nil,
        languageCode: rich ? ["en", "ja", "fr", "de"][index % 4] : nil,
        codec: rich ? (kind == .audio ? "aac" : "ass") : nil,
        isDefault: index % 3 == 0, isForced: index % 5 == 0,
        isExternal: rich && index % 7 == 0,
        externalFilename: rich && index % 7 == 0 ? "/subtitles/\(index).ass" : nil)
}

private func inputs(for name: String) -> [Input] {
    let parts = name.split(separator: "-")
    let kind = MediaTrackKind(rawValue: String(parts[0]))!
    let other: MediaTrackKind = kind == .audio ? .subtitle : .audio
    if parts[1] == "wrong" || parts[1] == "zero" {
        let preference = MediaTrackPreference(track:
            MediaTrack(id: 1, kind: kind, isExternal: true))
        let values = (0..<8).map { index in
            MediaTrack(id: Int64(index + 1),
                kind: parts[1] == "wrong" ? other : kind)
        }
        return [values, Array(values.reversed())].map {
            Input(preference: preference, tracks: $0, expected: nil)
        }
    }
    let count = Int(parts[1])!
    let rich = parts[2] == "metadata"
    let values = (0..<count).map {
        track(Int64(count - $0), kind: kind, index: $0, rich: rich)
    }
    let selected = rich ? values.dropFirst(count / 2).first : values.last
    let seed = selected ?? MediaTrack(id: 99, kind: kind)
    let preference = rich ? MediaTrackPreference(track: seed)
                          : legacy(MediaTrackPreference(track: seed))
    return [values, Array(values.reversed())].map {
        Input(preference: preference, tracks: $0, expected: selected)
    }
}

private struct BatchResult {
    var checksum: UInt64 = 0
    var selectedCount = 0

    mutating func consume(_ selected: MediaTrack?) {
        guard let selected else { checksum &+= 0x9e37_79b9; return }
        let flags: UInt64 = (selected.isDefault ? 1 : 0)
            | (selected.isForced ? 2 : 0) | (selected.isExternal ? 4 : 0)
            | (selected.kind == .subtitle ? 8 : 0)
        checksum &+= (UInt64(bitPattern: selected.id) &* 31) &+ flags
        selectedCount += 1
    }
}

@inline(never)
private func selectBatch(_ inputs: [Input], iterations: Int) -> BatchResult {
    var result = BatchResult()
    for _ in 0..<iterations {
        for input in inputs {
            result.consume(input.preference.bestMatch(in: input.tracks))
        }
    }
    return result
}

private func jsonOptional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

private func record(_ track: MediaTrack?) -> Any {
    guard let track else { return NSNull() }
    return ["id": String(track.id), "kind": track.kind.rawValue,
        "title": jsonOptional(track.title), "language": jsonOptional(track.languageCode),
        "codec": jsonOptional(track.codec), "default": track.isDefault,
        "forced": track.isForced, "external": track.isExternal,
        "external_filename": jsonOptional(track.externalFilename)] as [String: Any]
}

private func expectedFixtures() -> [Input] {
    let saved = MediaTrack(id: 42, kind: .audio, title: "Main", languageCode: "en", codec: "aac")
    let renumbered = MediaTrack(id: 7, kind: .audio, title: "Main", languageCode: "en", codec: "aac")
    let weakID = MediaTrack(id: 42, kind: .audio, title: "Commentary", languageCode: "ja", codec: "ac3")
    let low = MediaTrack(id: -1, kind: .audio)
    let high = MediaTrack(id: 42, kind: .audio)
    let first = MediaTrack(id: 9, kind: .audio, isDefault: true)
    let second = MediaTrack(id: 9, kind: .audio, isForced: true)
    let plain = MediaTrackPreference(track: high)
    let external = MediaTrack(id: 3, kind: .subtitle, title: "Main", languageCode: "en",
        codec: "ass", isExternal: true, externalFilename: "/a.srt")
    let filename = MediaTrack(id: 8, kind: .subtitle, isExternal: true, externalFilename: "/a.srt")
    let metadata = MediaTrack(id: 3, kind: .subtitle, title: "Main",
        languageCode: "en", codec: "ass", isExternal: true, externalFilename: "/b.srt")
    return [
        Input(preference: plain, tracks: [], expected: nil),
        Input(preference: plain, tracks: [external], expected: nil),
        Input(preference: MediaTrackPreference(track: MediaTrack(id: 42, kind: .audio,
            isExternal: true)), tracks: [high], expected: nil),
        Input(preference: MediaTrackPreference(track: saved),
            tracks: [weakID, renumbered], expected: renumbered),
        Input(preference: plain, tracks: [low, high], expected: high),
        Input(preference: legacy(plain), tracks: [high, low], expected: low),
        Input(preference: legacy(plain), tracks: [first, second], expected: first),
        Input(preference: legacy(plain), tracks: [second, first], expected: second),
        Input(preference: MediaTrackPreference(track: external),
            tracks: [metadata, filename], expected: filename),
    ]
}

private func verify() -> [String: Any] {
    var comparisons = 0
    var explicit: [Any] = []
    for input in expectedFixtures() + workloadNames.flatMap({ inputs(for: $0) }) {
        let selected = input.preference.bestMatch(in: input.tracks)
        precondition(selected == input.expected, "Independent expected fixture failed")
        explicit.append(record(selected))
        comparisons += 1
    }
    let titles: [String?] = [nil, "Main", "Commentary", "Caf\u{e9}", "Cafe\u{301}", "主音声"]
    let languages: [String?] = [nil, "en", "EN", "eng", "ja", "fr"]
    var catalogs: [[MediaTrack]] = [[]]
    for kind in MediaTrackKind.allCases {
        let values = (0..<48).map { index -> MediaTrack in
            let id: Int64 = index == 0 ? .min : index == 47 ? .max : Int64(index / 2)
            return MediaTrack(id: id, kind: kind, title: titles[index % titles.count],
                languageCode: languages[(index / 2) % languages.count],
                codec: [nil, "aac", "ass", "AAC"][index % 4],
                isDefault: index & 1 != 0, isForced: index & 2 != 0,
                isExternal: index & 4 != 0,
                externalFilename: [nil, "/a.srt", "/b.srt"][(index / 3) % 3])
        }
        catalogs.append(values)
        catalogs.append(Array(values.reversed()))
        var shuffled = values
        var state: UInt64 = 0x193a_670b_814f_d259
        for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            shuffled.swapAt(index, Int(state % UInt64(index + 1)))
        }
        catalogs.append(shuffled)
    }
    catalogs.append(catalogs[1] + catalogs[4])
    catalogs.append(Array(catalogs.last!.reversed()))
    let seeds = catalogs[1] + catalogs[4]
    var results: [[String: Any]] = []
    for (index, seed) in seeds.enumerated() {
        for usesLegacy in [false, true] {
            let preference = usesLegacy ? legacy(MediaTrackPreference(track: seed))
                                        : MediaTrackPreference(track: seed)
            let selected = catalogs.map { record(preference.bestMatch(in: $0)) }
            comparisons += selected.count
            results.append(["source": index, "legacy": usesLegacy, "selected": selected])
        }
    }
    return ["schema_version": 1, "mode": "verify", "comparisons": comparisons,
        "explicit_expected_results": explicit,
        "catalogs": catalogs.map { $0.map { record($0) } }, "results": results,
        "output_order": "source catalog audio then subtitle; saved then legacy; catalog order",
        "result_fields": "Every MediaTrack field; IDs encoded as decimal strings"]
}

@main
private struct TrackPreferenceMatchingHarness {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["list"] {
            emit(["schema_version": 1, "workloads": workloadNames]); return
        }
        if arguments == ["verify"] { emit(verify()); return }
        guard arguments.count == 3, arguments[0] == "benchmark",
              workloadNames.contains(arguments[1]), let iterations = Int(arguments[2]),
              iterations > 0, iterations <= Int.max / 4 else {
            FileHandle.standardError.write(Data(
                "Expected list, verify, or benchmark <workload> <iterations>\n".utf8))
            exit(2)
        }
        let name = arguments[1]
        let values = inputs(for: name)
        for input in values {
            precondition(input.preference.bestMatch(in: input.tracks) == input.expected,
                "Workload expected selection failed")
        }
        let warmupIterations = min(iterations, 1_000)
        let warmup = selectBatch(values, iterations: warmupIterations)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = selectBatch(values, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        emit(["schema_version": 1, "workload": name, "iterations": iterations,
            "operations": iterations * values.count, "checksum": String(result.checksum),
            "selected_count": result.selectedCount, "warmup_iterations": warmupIterations,
            "warmup_checksum": String(warmup.checksum),
            "warmup_selected_count": warmup.selectedCount, "elapsed_ns": elapsed])
    }

    private static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
    }
}
