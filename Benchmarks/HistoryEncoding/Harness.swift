// The timed implementation lives in the separately compiled production module.
// Fixture construction, payload export, and complete restore checks are untimed.
import Foundation
import IlliquidCore

private final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    private let recordingLock = NSLock()
    private var recording = false
    private var payloadSizes: [Int] = []

    func beginRecording() {
        recordingLock.lock()
        payloadSizes = []
        recording = true
        recordingLock.unlock()
    }

    override func set(_ value: Any?, forKey key: String) {
        // Exercise the real defaults implementation, not a dictionary stand-in.
        super.set(value, forKey: key)
        guard key == "Benchmark.playback-state.v1" else { return }
        recordingLock.lock()
        if recording { payloadSizes.append((value as? Data)?.count ?? 0) }
        recordingLock.unlock()
    }

    func recordedSizes() -> [Int] {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return payloadSizes
    }
}

private func mediaURL(_ index: Int, profile: String) -> URL {
    let path: String
    switch profile {
    case "short":
        path = "/v\(index).mkv"
    case "normal":
        path = "/Volumes/Media/Library/Series/Show-\(index / 24)/Season-01/Episode-\(index).mkv"
    case "deep":
        path = "/Volumes/Media/Archive/Library/Video/Collections/Television/International/Drama/Remastered/Series/Show-\(index / 24)/Season-01/Disc-01/Episode-\(index).mkv"
    case "escaped":
        path = "/Volumes/映像/Library/Café/Show-\(index / 24)/Season-01/Episode-\(index)-\"mix\"-\\-\t-\n-Ω.mkv"
    default:
        fatalError("unknown profile: \(profile)")
    }
    return URL(fileURLWithPath: path, isDirectory: false)
}

private func version(_ index: Int, replacement: Bool = false) -> MediaContentVersion {
    MediaContentVersion(
        fileIdentifier: UInt64(index + 1 + (replacement ? 1_000_000 : 0)),
        byteCount: Int64(10_000_000 + index),
        modificationSeconds: replacement ? 1_700_000_100 : 1_700_000_000,
        modificationNanoseconds: 123,
        creationSeconds: 1_600_000_000,
        creationNanoseconds: 456
    )
}

private func settings(_ index: Int, url: URL, profile: String) -> MediaPlaybackSettings {
    let title = profile == "escaped" ? "Audio / \"mix\" \\ tab\tline\n日本語\u{0001}" : "Main / stereo"
    let audio = MediaTrack(id: Int64(index + 1), kind: .audio,
                          title: title, languageCode: "en", codec: "aac")
    let subtitle = MediaTrack(id: Int64(index + 2), kind: .subtitle,
                             title: "English / SDH", languageCode: "en", codec: "srt",
                             isExternal: true,
                             externalFilename: url.deletingPathExtension().path + ".en.srt")
    return MediaPlaybackSettings(audioTrack: MediaTrackPreference(track: audio),
                                 subtitleTrack: MediaTrackPreference(track: subtitle),
                                 areSubtitlesVisible: index.isMultiple(of: 32),
                                 subtitleDelay: 0.25)
}

private func seed(_ store: PlaybackPersistenceStore, count: Int, profile: String) {
    // Build even the nested replacement-history records through production APIs;
    // the harness contains no duplicate Encodable representation of StoredState.
    for index in 0..<count {
        let url = mediaURL(index, profile: profile)
        let completed = index % 7 == 6
        if index.isMultiple(of: 16) {
            store.acceptMediaVersion(version(index), for: url)
            store.setMediaSettings(settings(index, url: url, profile: profile), for: url)
        }
        precondition(store.setPlaybackProgress(position: completed ? 3_500 : Double(index % 600 + 1),
                                               duration: 3_600, for: url))
        if index.isMultiple(of: 32) {
            precondition(store.acceptMediaVersion(version(index, replacement: true), for: url) == .changed)
            precondition(store.setPlaybackProgress(position: completed ? 3_500 : Double(index % 600 + 1),
                                                   duration: 3_600, for: url))
            store.setMediaSettings(settings(index, url: url, profile: profile), for: url)
        }
        if index.isMultiple(of: 24) {
            store.setLastWatchedFile(url, for: url.deletingLastPathComponent())
        }
    }
    if count > 0 {
        precondition(store.setLastOpenedMedia(.file(mediaURL(count - 1, profile: profile))))
    } else {
        store.clearPlaybackHistory()
    }
    store.flushSynchronously()
}

private func verifyRestore(_ store: PlaybackPersistenceStore, count: Int, profile: String,
                           finalPosition: Double) {
    precondition(!store.hasUnreadableHistory)
    precondition(store.loadPreferences() == .standard)
    if count == 0 {
        precondition(store.lastOpenedMedia() == nil)
        return
    }
    precondition(store.lastOpenedMedia() == .file(mediaURL(count - 1, profile: profile)))
    for index in 0..<count {
        let url = mediaURL(index, profile: profile)
        let completed = index % 7 == 6
        let expected = index == 0 ? finalPosition : Double(index % 600 + 1)
        let progress = store.playbackProgress(for: url)
        precondition(progress?.duration == 3_600)
        precondition(progress?.isCompleted == completed)
        precondition(progress?.position == (completed ? 3_600 : expected))
        precondition(store.playbackPosition(for: url) == (completed ? nil : expected))
        if index.isMultiple(of: 16) {
            precondition(store.mediaSettings(for: url) == settings(index, url: url, profile: profile))
            precondition(store.mediaVersion(for: url) == version(index, replacement: index.isMultiple(of: 32)))
        } else {
            precondition(store.mediaSettings(for: url) == nil)
            precondition(store.mediaVersion(for: url) == nil)
        }
        let replaced = store.replacedMediaHistory(for: url)
        if index.isMultiple(of: 32) {
            precondition(replaced.count == 1)
            precondition(replaced[0].version == version(index))
            precondition(replaced[0].position == (completed ? nil : Double(index % 600 + 1)))
            precondition(replaced[0].duration == 3_600)
            precondition(replaced[0].isCompleted == completed)
            precondition(replaced[0].mediaSettings == settings(index, url: url, profile: profile))
        } else {
            precondition(replaced.isEmpty)
        }
    }
}

@main
private struct Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let count = Int(arguments[1]), count >= 0,
              let iterations = Int(arguments[3]), iterations > 0 else {
            fatalError("usage: history-encoding COUNT PROFILE ITERATIONS PAYLOAD_PATH")
        }
        let profile = arguments[2]
        let suite = "IlliquidHistoryEncodingBenchmark.\(UUID().uuidString)"
        let defaults = RecordingDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Benchmark")
        seed(store, count: count, profile: profile)
        let changedURL = mediaURL(0, profile: profile)
        func update(_ iteration: Int) {
            if count == 0 {
                // Bulk clear intentionally writes even when the history is empty.
                store.clearPlaybackHistory()
            } else {
                precondition(store.setPlaybackProgress(position: Double(100 + iteration),
                                                       duration: 3_600, for: changedURL))
            }
            store.flushSynchronously()
        }
        let warmupIterations = 3
        for iteration in 0..<warmupIterations { update(iteration) }
        defaults.beginRecording()
        var elapsed: [UInt64] = []
        elapsed.reserveCapacity(iterations)
        for iteration in warmupIterations..<(warmupIterations + iterations) {
            let before = DispatchTime.now().uptimeNanoseconds
            update(iteration)
            elapsed.append(DispatchTime.now().uptimeNanoseconds - before)
        }
        let sizes = defaults.recordedSizes()
        precondition(sizes.count == iterations, "each changed update must flush one history callback")
        let data = defaults.data(forKey: "Benchmark.playback-state.v1")!
        precondition(sizes.allSatisfy { $0 == data.count })
        let restored = PlaybackPersistenceStore(userDefaults: defaults, namespace: "Benchmark")
        verifyRestore(restored, count: count, profile: profile,
                      finalPosition: Double(100 + warmupIterations + iterations - 1))
        try data.write(to: URL(fileURLWithPath: arguments[4]), options: .atomic)
        let receipt: [String: Any] = [
            "count": count, "profile": profile, "iterations": iterations,
            "warmup_iterations": warmupIterations, "mutation_flush_ns": elapsed,
            "writes": sizes.count, "write_payload_bytes": sizes,
            "final_payload_bytes": data.count, "restored_entries_checked": count,
            "scope": "changed mutation + production writer flush + real UserDefaults.set; not fsync"
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                     as: UTF8.self))
    }
}
