import Foundation
import Observation
import IlliquidCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
#if ALLOC_METER
@_silgen_name("meter_begin") func meterBegin()
@_silgen_name("meter_end") func meterEnd()
@_silgen_name("meter_requests") func meterRequests() -> UInt64
@_silgen_name("meter_bytes") func meterBytes() -> UInt64
#endif

@MainActor
final class BenchContext {
    let state = PlaybackState()
    let view: PlaybackViewStore
    var callbacks = 0
    let chapters: [Chapter]
    let alternateChapters: [Chapter]
    let tracks: [MediaTrack]
    let alternateTracks: [MediaTrack]
    let devices: [AudioOutputDevice]
    let alternateDevices: [AudioOutputDevice]
    let messages = (0..<257).map { "diagnostic-\($0)-\(String(repeating: "text", count: 8))" }
    init(size: Int, connected: Bool) {
        let count = max(2, size)
        chapters = (0..<count).map { .init(id: Int64($0), title: "Chapter \($0)", startTime: Double($0 * 30)) }
        alternateChapters = (0..<count).map { index -> Chapter in
            let title: String = index == count - 1 ? "Alternate title" : "Chapter \(index)"
            return Chapter(id: Int64(index), title: title, startTime: Double(index * 30))
        }
        tracks = (0..<max(8,min(count,128))).map { .init(id: Int64($0),kind: $0.isMultiple(of: 2) ? .audio : .subtitle, title: "Track \($0)") }
        alternateTracks = tracks.map { .init(id: $0.id,kind: $0.kind,title: "Alternate \($0.id)") }
        devices = (0..<8).map { .init(id: "device-\($0)", name: "Device \($0)", isDefault: $0 == 0, isSelected: $0 == 0) }
        alternateDevices = (0..<8).map { .init(id: "device-\($0)", name: "Device \($0)", isDefault: $0 == 0, isSelected: $0 == 7) }
        state.setVolume(50)
        state.updateTrackCatalog(tracks)
        state.updateChapters(chapters,currentID: 0)
        state.updateAudioOutputDevices(devices)
        state.configurePlaylist(folder: URL(fileURLWithPath: "/synthetic",isDirectory: true),
            items: (0..<100).map { FolderPlaylistItem(url: URL(fileURLWithPath: "/synthetic/episode-\($0).mkv")) }, selectedIndex: 0)
        state.applyAuthorityProjection(Self.projection(0))
        view = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: state))
        if connected {
            state.onMutation = { [weak self] in
                guard let self else { return }
                callbacks += 1
                view.publish(PlaybackViewSnapshot(state: state))
            }
        }
    }
    static func projection(_ n: Int) -> PlaybackAuthorityProjection {
        .init(phase: .playing, position: Double(n + 1) / 60, duration: 3600,
              isBuffering: false, selectedAudioID: 0, selectedSubtitleID: 1,
              subtitleDelay: 0, failureCode: nil, isPauseDesired: false)
    }
    @inline(never)
    func event(_ name: String, _ index: Int) {
        switch name {
        case "position": state.applyAuthorityProjection(Self.projection(index))
        case "scalar_same": state.setVolume(50)
        case "scalar_changed": state.setVolume(index.isMultiple(of: 2) ? 33 : 66)
        case "chapters_same": state.updateChapters(chapters, currentID: 0)
        case "chapter_index": state.updateChapters(chapters,currentID: Int64(index % chapters.count))
        case "chapters_changed": state.updateChapters(index.isMultiple(of: 2) ? alternateChapters : chapters,currentID: 0)
        case "tracks_same": state.updateTrackCatalog(tracks)
        case "tracks_changed": state.updateTrackCatalog(index.isMultiple(of: 2) ? alternateTracks : tracks)
        case "devices_changed": state.updateAudioOutputDevices(index.isMultiple(of: 2) ? alternateDevices : devices)
        case "adjustment_same": state.updateVideoAdjustments { $0.gamma = 0 }
        case "adjustment_changed": state.updateVideoAdjustments { $0.gamma = index.isMultiple(of: 2) ? -1 : 1 }
        case "diagnostic", "diagnostic_disconnected": state.recordDiagnostic(messages[index % messages.count])
        default: preconditionFailure("unknown workload")
        }
    }
}

@main
struct StateHarness {
    @MainActor static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let mode = args.first else { throw PlaybackStatePublicationChecks.Failure(description: "mode: tests, diagnose, bench, differential") }
            switch mode {
            case "tests":
                var rows: [[String: Any]] = []; var failures = 0
                for (name, body) in PlaybackStatePublicationChecks.scenarios {
                    do { rows.append(["name": name,"assertions": try body(),"passed": true]) }
                    catch { failures += 1; rows.append(["name":name,"passed":false,"error":String(describing:error)]) }
                }
                try emit(["kind":"tests","scenarios":rows,"failures":failures])
                if failures > 0 { exit(1) }
            case "diagnose":
                let f = PlaybackStatePublicationChecks.Fixture()
                f.state.updateChapters([.init(id: 1,title: "A",startTime: 0)],currentID: 1)
                let chapters = f.publications.count
                let mixedChapter = f.publications.contains { !$0.chapters.isEmpty && $0.currentChapterID == nil }
                for n in 0..<100 { f.state.recordDiagnostic("message-\(n)") }
                f.reset(); f.state.recordDiagnostic("overflow")
                let diagnostic = f.publications.count, maximum = f.publications.map { $0.recentDiagnosticMessages.count }.max() ?? 0
                f.reset(); f.state.setVolume(f.state.volume)
                let noOp = f.publications.count
                let source = PlaybackStatePublicationChecks.ObservationCounter()
                withObservationTracking { _ = f.state.videoAdjustments } onChange: { source.increment() }
                f.state.updateVideoAdjustments { $0.gamma = 0 }
                try emit(["kind":"diagnosis","chapter_publications":chapters,"mixed_chapter_snapshot":mixedChapter,
                          "diagnostic_publications":diagnostic,"maximum_published_messages":maximum,"equal_volume_publications":noOp,
                          "noop_adjustment_source_observations":source.value])
            case "bench":
                guard args.count == 4, let size = Int(args[2]), let iterations = Int(args[3]),
                      (2...100_000).contains(size), (1...1_000_000).contains(iterations) else {
                    throw PlaybackStatePublicationChecks.Failure(description: "bench WORKLOAD SIZE ITERATIONS")
                }
                let name = args[1], connected = name != "diagnostic_disconnected"
                let context = BenchContext(size: size,connected: connected)
                for n in 0..<200 { context.event(name,n) }
                context.callbacks = 0
                #if ALLOC_METER
                meterBegin()
                #endif
                let cpuStart = cpuTime()
                let start = DispatchTime.now().uptimeNanoseconds
                for n in 0..<iterations { context.event(name,n) }
                let end = DispatchTime.now().uptimeNanoseconds
                let cpuEnd = cpuTime()
                #if ALLOC_METER
                meterEnd()
                #endif
                let snapshot = PlaybackViewSnapshot(state: context.state)
                precondition(!connected || context.view.snapshot == snapshot, "lost final publication")
                let lastChapter: String = snapshot.chapters.last?.title ?? ""
                let lastTrack: String = snapshot.subtitleTracks.last?.title ?? ""
                let selectedDevice: String = snapshot.audioOutputDevice?.id ?? ""
                let final: [String:Any] = ["volume":snapshot.volume,"position":snapshot.position,
                    "chapterID":snapshot.currentChapterID ?? -1,"chapters":snapshot.chapters.count,
                    "lastChapter":lastChapter,"lastTrack":lastTrack,"selectedDevice":selectedDevice,
                    "gamma":snapshot.videoAdjustments.gamma,"messages":snapshot.recentDiagnosticMessages]
                var row: [String:Any] = ["kind":"benchmark","workload":name,"size":size,"iterations":iterations,
                    "elapsed_ns":end-start,"cpu_ns":cpuEnd-cpuStart,"callbacks":context.callbacks,"connected":connected,"final":final]
                row["instrumentation_enabled"] = NonDecodePerformance.isEnabled
                #if ALLOC_METER
                row["allocation_requests"] = meterRequests(); row["allocation_requested_bytes"] = meterBytes()
                #endif
                try emit(row)
            #if STATE_DIFFERENTIAL
            case "differential": try emit(StateDifferential.run())
            #endif
            default: throw PlaybackStatePublicationChecks.Failure(description: "unknown mode \(mode)")
            }
        } catch {
            FileHandle.standardError.write(Data(("ERROR: \(error)\n").utf8)); exit(1)
        }
    }
    static func cpuTime() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
    static func emit(_ value: [String:Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value,options: [.sortedKeys])
        print(String(decoding: data,as: UTF8.self))
    }
}
