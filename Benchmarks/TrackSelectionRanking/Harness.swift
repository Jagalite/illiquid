import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Each driver links a separately optimized production module. Inputs and
// warm-up are outside timing; every selection contributes to emitted results.
private let workloadNames = [
    "audio-0-none", "audio-0-languages", "audio-1-none", "audio-1-languages",
    "audio-2-none", "audio-2-languages", "audio-8-none", "audio-8-languages",
    "audio-32-none", "audio-32-languages", "subtitle-automatic", "subtitle-off",
    "subtitle-always", "subtitle-forced-languages", "subtitle-forced-audio-fallback",
    "mutable-preferences", "subtitle-automatic-first", "subtitle-automatic-last",
    "single-audio-in-subtitles",
]

private struct Input {
    let preferences: TrackSelectionPreferences
    let tracks: [TrackSelectionCandidate]
    let kind: MediaTrackKind
    let fallbackID: Int64?
    let audioLanguage: String?
}

private struct BatchResult {
    var checksum: UInt64 = 0
    var selectedCount = 0

    mutating func consume(_ selected: Int64?) {
        if let selected {
            checksum &+= UInt64(bitPattern: selected)
            selectedCount += 1
        }
    }
}

private func candidate(_ id: Int64, kind: MediaTrackKind, language: String?, flags: Int)
    -> TrackSelectionCandidate {
    .init(track: .init(id: id, kind: kind, languageCode: language,
                      isDefault: flags & 1 != 0, isForced: flags & 2 != 0),
          isCommentary: flags & 4 != 0, isAccessible: flags & 8 != 0,
          canFilterForcedEvents: flags & 16 != 0)
}

private func tracks(_ count: Int, kind: MediaTrackKind) -> [TrackSelectionCandidate] {
    let languages: [String?] = ["en", "jpn", "fra", "de", "pt-BR", nil]
    return (0..<count).map { index in
        candidate(Int64(index + (kind == .audio ? 1 : 101)), kind: kind,
                  language: languages[index % languages.count], flags: (index * 13 + 1) % 32)
    }
}

private func inputs(for name: String) -> [Input] {
    if name == "single-audio-in-subtitles" {
        let other = tracks(32, kind: .subtitle)
        let audio = tracks(1, kind: .audio)
        return [
            Input(preferences: .init(), tracks: other + audio, kind: .audio,
                  fallbackID: nil, audioLanguage: nil),
            Input(preferences: .init(), tracks: audio + other, kind: .audio,
                  fallbackID: nil, audioLanguage: nil),
        ]
    }
    if name.hasPrefix("audio-") {
        let pieces = name.split(separator: "-")
        let count = Int(pieces[1])!
        let preferences = TrackSelectionPreferences(
            audioLanguages: pieces[2] == "languages" ? ["ja", "en", "fr"] : [])
        let audio = tracks(count, kind: .audio)
        return [
            Input(preferences: preferences, tracks: audio, kind: .audio,
                  fallbackID: audio.first?.track.id, audioLanguage: nil),
            Input(preferences: preferences, tracks: tracks(2, kind: .subtitle) + audio.reversed(),
                  kind: .audio, fallbackID: audio.last?.track.id, audioLanguage: nil),
        ]
    }
    let subtitles = tracks(8, kind: .subtitle)
    let mixed = tracks(2, kind: .audio) + subtitles
    if name == "subtitle-automatic-first" || name == "subtitle-automatic-last" {
        return [
            Input(preferences: .init(), tracks: mixed, kind: .subtitle,
                  fallbackID: name.hasSuffix("first") ? subtitles.first!.track.id : subtitles.last!.track.id,
                  audioLanguage: nil),
        ]
    }
    if name == "mutable-preferences" {
        return (0..<4).map { index in
            var preferences = TrackSelectionPreferences()
            // Assign raw values after initialization, as decoded or publicly
            // mutated preferences can contain aliases, duplicates, and invalids.
            preferences.audioLanguages = index % 2 == 0 ? [" JA-jp ", "eng", "und"] : [" FR-ca ", "fra"]
            preferences.subtitleLanguages = index < 2 ? [" ENG ", "en-US"] : ["jpn", "invalid"]
            preferences.subtitles = index < 2 ? .always : .forcedOnly
            preferences.prefersAccessibleTracks = index & 1 != 0
            preferences.avoidsCommentary = index & 2 == 0
            return Input(preferences: preferences, tracks: tracks(8, kind: .audio) + subtitles,
                         kind: index % 2 == 0 ? .audio : .subtitle,
                         fallbackID: index % 2 == 0 ? 2 : 102, audioLanguage: "eng")
        }
    }
    let preferences: TrackSelectionPreferences
    switch name {
    case "subtitle-automatic": preferences = .init()
    case "subtitle-off": preferences = .init(subtitleLanguages: ["en"], subtitles: .off)
    case "subtitle-always": preferences = .init(subtitles: .always)
    case "subtitle-forced-languages":
        preferences = .init(subtitleLanguages: ["en", "ja"], subtitles: .forcedOnly)
    case "subtitle-forced-audio-fallback": preferences = .init(subtitles: .forcedOnly)
    default: preconditionFailure("Unknown workload: \(name)")
    }
    return [
        Input(preferences: preferences, tracks: mixed, kind: .subtitle,
              fallbackID: 108, audioLanguage: "eng"),
        Input(preferences: preferences, tracks: Array(mixed.reversed()), kind: .subtitle,
              fallbackID: nil, audioLanguage: "ja-JP"),
    ]
}

@inline(never)
private func selectBatch(_ inputs: [Input], iterations: Int) -> BatchResult {
    var result = BatchResult()
    for _ in 0..<iterations {
        for input in inputs {
            result.consume(input.preferences.select(in: input.tracks, kind: input.kind,
                fallbackID: input.fallbackID, audioLanguage: input.audioLanguage))
        }
    }
    return result
}

@inline(never)
private func mutableBatch(_ inputs: [Input], iterations: Int) -> BatchResult {
    var preferences = TrackSelectionPreferences()
    var result = BatchResult()
    for _ in 0..<iterations {
        for input in inputs {
            preferences.audioLanguages = input.preferences.audioLanguages
            preferences.subtitleLanguages = input.preferences.subtitleLanguages
            preferences.subtitles = input.preferences.subtitles
            preferences.prefersAccessibleTracks = input.preferences.prefersAccessibleTracks
            preferences.avoidsCommentary = input.preferences.avoidsCommentary
            result.consume(preferences.select(in: input.tracks, kind: input.kind,
                fallbackID: input.fallbackID, audioLanguage: input.audioLanguage))
        }
    }
    return result
}

private func catalogs() -> [(String, [TrackSelectionCandidate])] {
    let languages: [String?] = [nil, "en", "eng", "EN_us", "ja", "jpn", "fr", "fra",
        "pt-BR", "de", "und", "mul", "zxx", "invalid", "", String(repeating: "x", count: 36)]
    func exhaustive(_ kind: MediaTrackKind, sameLanguage: Bool) -> [TrackSelectionCandidate] {
        (0..<32).map { flags in
            let id: Int64 = flags == 0 ? .min : flags == 31 ? .max : Int64(flags * 7)
            return candidate(id, kind: kind,
                language: sameLanguage ? "en" : languages[flags % languages.count], flags: flags)
        }
    }
    let base: [(String, [TrackSelectionCandidate])] = [
        ("empty", []),
        ("single-audio", [candidate(.min, kind: .audio, language: nil, flags: 31)]),
        ("single-subtitle", [candidate(.max, kind: .subtitle, language: "invalid", flags: 0)]),
        ("tied-extreme-ids", [candidate(.max, kind: .audio, language: nil, flags: 0),
                              candidate(.min, kind: .audio, language: nil, flags: 0)]),
        ("audio-flags", exhaustive(.audio, sameLanguage: false)),
        ("subtitle-flags", exhaustive(.subtitle, sameLanguage: false)),
        ("audio-same-language", exhaustive(.audio, sameLanguage: true)),
        ("subtitle-same-language", exhaustive(.subtitle, sameLanguage: true)),
        ("mixed", exhaustive(.audio, sameLanguage: false) + exhaustive(.subtitle, sameLanguage: false)),
    ]
    var result: [(String, [TrackSelectionCandidate])] = []
    for (name, values) in base {
        result.append((name, values))
        guard values.count > 1 else { continue }
        result.append((name + "-reversed", Array(values.reversed())))
        result.append((name + "-rotated", Array(values.dropFirst()) + values.prefix(1)))
        // Fixed Fisher-Yates permutation; independent of Swift's randomized hash seed.
        var shuffled = values
        var state: UInt64 = 0x193a_670b_814f_d259
        for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            shuffled.swapAt(index, Int(state % UInt64(index + 1)))
        }
        result.append((name + "-shuffled", shuffled))
    }
    return result
}

private func jsonOptional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

private func verify() -> [String: Any] {
    let allCatalogs = catalogs()
    let audioContexts: [String?] = [nil, " ENG ", "ja-JP", "invalid"]
    let rawLanguages: [([String], [String])] = [
        ([], []),
        ([" ENG ", "eng", "ja-JP", "invalid", "fr"], ["FR-ca", "en_US", "fra", "zxx"]),
        (["pt_BR", "de", "", "und"], ["jpn", " EN ", "nonsense"]),
        (Array(repeating: "und", count: 31) + ["eng", "ja"], Array(repeating: "und", count: 32) + ["en"]),
    ]
    var states: [[String: Any]] = []
    var comparisons = 0
    for mode in AutomaticSubtitleSelection.allCases {
        for (languageIndex, languages) in rawLanguages.enumerated() {
            for flags in 0..<4 {
                var preferences = TrackSelectionPreferences()
                preferences.audioLanguages = languages.0
                preferences.subtitleLanguages = languages.1
                preferences.subtitles = mode
                preferences.prefersAccessibleTracks = flags & 1 != 0
                preferences.avoidsCommentary = flags & 2 == 0
                var selectedIDs: [Any] = []
                for (_, candidates) in allCatalogs {
                    let fallbacks: [Int64?] = [nil, candidates.first?.track.id, candidates.last?.track.id, 123_456]
                    for kind in MediaTrackKind.allCases {
                        for fallback in fallbacks {
                            for audioLanguage in audioContexts {
                                let id = preferences.select(in: candidates, kind: kind,
                                    fallbackID: fallback, audioLanguage: audioLanguage)
                                selectedIDs.append(jsonOptional(id.map(String.init)))
                            }
                        }
                    }
                }
                comparisons += selectedIDs.count
                states.append([
                    "name": "\(mode.rawValue)-languages\(languageIndex)-flags\(flags)",
                    "audio_languages": preferences.audioLanguages,
                    "subtitle_languages": preferences.subtitleLanguages,
                    "subtitles": mode.rawValue,
                    "prefers_accessible_tracks": preferences.prefersAccessibleTracks,
                    "avoids_commentary": preferences.avoidsCommentary,
                    "selected_ids": selectedIDs,
                ])
            }
        }
    }
    let descriptions: [[String: Any]] = allCatalogs.map { name, candidates in
        ["name": name, "tracks": candidates.map { candidate -> [String: Any] in
            ["id": String(candidate.track.id), "kind": candidate.track.kind.rawValue,
             "language": jsonOptional(candidate.track.languageCode),
             "default": candidate.track.isDefault, "forced": candidate.track.isForced,
             "commentary": candidate.isCommentary, "accessible": candidate.isAccessible,
             "filter_forced_events": candidate.canFilterForcedEvents]
        }, "fallback_ids": [nil, candidates.first?.track.id, candidates.last?.track.id, 123_456]
            .map { jsonOptional($0.map(String.init)) }]
    }
    return ["schema_version": 1, "mode": "verify", "comparisons": comparisons,
            "catalogs": descriptions, "kinds": MediaTrackKind.allCases.map(\.rawValue),
            "audio_languages": audioContexts.map(jsonOptional), "states": states,
            "output_order": "catalog, kind, fallback_id, audio_language; selected IDs are decimal strings or null"]
}

@main
private struct TrackSelectionRankingHarness {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["list"] {
            emit(["schema_version": 1, "workloads": workloadNames])
            return
        }
        if arguments == ["verify"] {
            emit(verify())
            return
        }
        guard arguments.count == 3, arguments[0] == "benchmark",
              workloadNames.contains(arguments[1]), let iterations = Int(arguments[2]),
              iterations > 0, iterations <= Int.max / 4 else {
            FileHandle.standardError.write(Data("Expected list, verify, or benchmark <workload> <iterations>\n".utf8))
            exit(2)
        }
        let name = arguments[1]
        let values = inputs(for: name)
        let batch = name == "mutable-preferences" ? mutableBatch : selectBatch
        let warmupIterations = min(iterations, 1_000)
        let warmup = batch(values, warmupIterations)
        let cpuStart = clock()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = batch(values, iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let cpuTicks = clock() - cpuStart
        emit(["schema_version": 1, "mode": "benchmark", "workload": name,
              "iterations": iterations, "operations": iterations * values.count,
              "elapsed_ns": elapsed,
              "cpu_ns": Double(cpuTicks) * 1_000_000_000 / Double(CLOCKS_PER_SEC),
              "checksum": String(result.checksum),
              "selected_count": result.selectedCount, "warmup_iterations": warmupIterations,
              "warmup_checksum": String(warmup.checksum), "warmup_selected_count": warmup.selectedCount])
    }

    private static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
    }
}
