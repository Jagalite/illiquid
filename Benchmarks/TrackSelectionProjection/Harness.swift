import Foundation
import Observation
@testable import IlliquidCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@MainActor
private final class Fixture {
    let state = PlaybackState()
    let view: PlaybackViewStore
    let audioCount: Int
    let subtitleCount: Int
    let tracks: [MediaTrack]
    let alternateTracks: [MediaTrack]
    let connected: Bool
    var callbacks = 0

    init(audioCount: Int, subtitleCount: Int, connected: Bool) {
        self.audioCount = audioCount
        self.subtitleCount = subtitleCount
        self.connected = connected
        tracks = Self.catalog(audioCount: audioCount, subtitleCount: subtitleCount, revision: 0)
        alternateTracks = Self.catalog(audioCount: audioCount, subtitleCount: subtitleCount, revision: 1)
        state.updateTrackCatalog(tracks)
        state.configurePlaylist(folder: nil, items: (0..<24).map {
            FolderPlaylistItem(url: URL(fileURLWithPath: "/synthetic/episode-\($0).mkv"))
        }, selectedIndex: 0)
        view = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: state))
        if connected {
            state.onMutation = { [weak self] in
                guard let self else { return }
                callbacks += 1
                view.publish(PlaybackViewSnapshot(state: state))
            }
        }
    }

    static func catalog(audioCount: Int, subtitleCount: Int, revision: Int) -> [MediaTrack] {
        let audio = (0..<audioCount).map {
            MediaTrack(id: Int64($0 + 1), kind: .audio, title: "Audio \($0) revision \(revision)",
                       languageCode: $0.isMultiple(of: 2) ? "en" : "ja", codec: "aac")
        }
        let subtitles = (0..<subtitleCount).map {
            MediaTrack(id: Int64($0 + 10_000), kind: .subtitle, title: "Subtitle \($0) revision \(revision)",
                       languageCode: $0.isMultiple(of: 2) ? "en" : "ja", codec: "ass")
        }
        return audio + subtitles
    }

    @inline(never)
    func event(_ workload: String, index: Int) {
        let firstAudio: Int64? = audioCount == 0 ? nil : 1
        let lastAudio: Int64? = audioCount == 0 ? nil : Int64(audioCount)
        let firstSubtitle: Int64? = subtitleCount == 0 ? nil : 10_000
        let lastSubtitle: Int64? = subtitleCount == 0 ? nil : Int64(9_999 + subtitleCount)
        var audio = lastAudio
        var subtitle = lastSubtitle
        switch workload {
        case "first": audio = firstAudio; subtitle = firstSubtitle
        case "last": break
        case "subtitles_off": subtitle = nil
        case "missing": audio = -1; subtitle = -2
        case "switch":
            if index.isMultiple(of: 2) { audio = firstAudio; subtitle = firstSubtitle }
        case "catalog_refresh":
            state.updateTrackCatalog(index.isMultiple(of: 2) ? tracks : alternateTracks)
        default: preconditionFailure("Unknown workload: \(workload)")
        }
        state.applyAuthorityProjection(.init(
            phase: .playing, position: Double(index + 1) / 4, duration: 100_000,
            isBuffering: false, selectedAudioID: audio, selectedSubtitleID: subtitle,
            subtitleDelay: 0, failureCode: nil, isPauseDesired: false
        ))
    }

    func receipt() -> [String: Any] {
        let snapshot = PlaybackViewSnapshot(state: state)
        precondition(!connected || view.snapshot == snapshot, "View publication lost state")
        return [
            "position": snapshot.position,
            "audio": trackReceipt(snapshot.selectedAudioTrack),
            "subtitle": trackReceipt(snapshot.selectedSubtitleTrack),
            "audio_count": snapshot.audioTracks.count,
            "subtitle_count": snapshot.subtitleTracks.count,
            "callbacks": callbacks,
        ]
    }
}

private func trackReceipt(_ track: MediaTrack?) -> Any {
    guard let track else { return NSNull() }
    // JSONEncoder uses the complete production Codable track, including metadata.
    return try! JSONSerialization.jsonObject(with: JSONEncoder().encode(track))
}

@main
private struct Harness {
    @MainActor
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "tests":
            var rows: [[String: Any]] = []
            let scenarios = PlaybackStatePublicationChecks.scenarios + TrackSelectionProjectionChecks.scenarios
            for (name, body) in scenarios {
                rows.append(["name": name, "assertions": try body()])
            }
            try emit(["tests": rows, "passed": rows.count])
        case "verify":
            try verify()
        case "bench":
            precondition(args.count == 6)
            let workload = args[1]
            let audioCount = Int(args[2])!
            let subtitleCount = Int(args[3])!
            let iterations = Int(args[4])!
            let connected = args[5] == "connected"
            precondition((0...1_024).contains(audioCount) && (0...1_024).contains(subtitleCount))
            precondition((1...1_000_000).contains(iterations))
            let fixture = Fixture(audioCount: audioCount, subtitleCount: subtitleCount, connected: connected)
            for index in 0..<200 { fixture.event(workload, index: index) }
            fixture.callbacks = 0
            let cpuStart = cpuTime()
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<iterations { fixture.event(workload, index: index) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let cpu = cpuTime() - cpuStart
            precondition(!NonDecodePerformance.isEnabled)
            try emit([
                "workload": workload, "audio_count": audioCount, "subtitle_count": subtitleCount,
                "iterations": iterations, "connected": connected, "elapsed_ns": elapsed,
                "cpu_ns": cpu, "final": fixture.receipt(),
            ])
        default: preconditionFailure("Use tests, verify, or bench WORKLOAD AUDIO SUBTITLES ITERATIONS connected|disconnected")
        }
    }

    @MainActor
    private static func verify() throws {
        let fixture = Fixture(audioCount: 8, subtitleCount: 32, connected: true)
        var seed: UInt64 = 0xC0FFEE_1234
        var trace: [[String: Any]] = []
        let workloads = ["first", "last", "subtitles_off", "missing", "switch", "catalog_refresh"]
        for index in 0..<4_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            switch seed % 13 {
            case 0:
                fixture.state.audioTracks.reverse()
                fixture.state.subtitleTracks.reverse()
            case 1:
                // Duplicate IDs retain first-match semantics after order changes.
                fixture.state.audioTracks.insert(MediaTrack(id: 8, kind: .audio, title: "First duplicate \(index)"), at: 0)
                fixture.state.subtitleTracks.insert(MediaTrack(id: 10_031, kind: .subtitle, title: "First duplicate \(index)"), at: 0)
            case 2:
                fixture.state.updateTrackCatalog([])
            case 3:
                fixture.state.updateTrackCatalog(index.isMultiple(of: 2) ? fixture.tracks : fixture.alternateTracks)
            case 4:
                fixture.state.selectedAudioTrack = .init(id: 8, kind: .audio, title: "Internal replacement")
                fixture.state.selectedSubtitleTrack = nil
            case 5:
                fixture.state.clearMediaMetadata()
            default: break
            }
            fixture.event(workloads[Int((seed >> 16) % UInt64(workloads.count))], index: index)
            var receipt = fixture.receipt()
            receipt["step"] = index
            receipt["audio_catalog"] = fixture.state.audioTracks.map { trackReceipt($0) }
            receipt["subtitle_catalog"] = fixture.state.subtitleTracks.map { trackReceipt($0) }
            trace.append(receipt)
        }
        try emit(["steps": trace])
    }

    private static func cpuTime() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
