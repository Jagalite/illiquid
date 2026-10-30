import Foundation

public struct MediaPlaybackProgress: Equatable, Sendable {
    public let position: TimeInterval
    public let duration: TimeInterval
    public let isCompleted: Bool

    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    public init(position: TimeInterval, duration: TimeInterval, isCompleted: Bool) {
        self.position = max(0, position.isFinite ? position : 0)
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.isCompleted = isCompleted
    }
}

/// Synchronous in-memory reads and mutations, with coalesced background writes.
/// Preferences have their own key so adjusting a control never encodes history.
public final class PlaybackPersistenceStore: @unchecked Sendable {
    private struct StoredState: Codable, Sendable {
        var playbackPositions: [String: TimeInterval]
        var playbackDurations: [String: TimeInterval]
        var completedFiles: Set<String>
        var lastWatchedFiles: [String: String]
        var lastOpenedMedia: PlaybackRestoreTarget?
        var mediaSettings: [String: MediaPlaybackSettings]
        var mediaVersions: [String: MediaContentVersion]
        var replacedHistory: [String: [ReplacedMediaHistory]]
        var preferences: PlaybackPreferences

        static let empty = StoredState(
            playbackPositions: [:],
            playbackDurations: [:],
            completedFiles: [],
            lastWatchedFiles: [:],
            lastOpenedMedia: nil,
            mediaSettings: [:],
            preferences: .standard
        )

        private enum CodingKeys: String, CodingKey {
            case playbackPositions
            case playbackDurations
            case completedFiles
            case lastWatchedFiles
            case lastOpenedMedia
            case mediaSettings
            case mediaVersions
            case replacedHistory
            case preferences
        }

        init(
            playbackPositions: [String: TimeInterval],
            playbackDurations: [String: TimeInterval] = [:],
            completedFiles: Set<String> = [],
            lastWatchedFiles: [String: String],
            lastOpenedMedia: PlaybackRestoreTarget? = nil,
            mediaSettings: [String: MediaPlaybackSettings] = [:],
            mediaVersions: [String: MediaContentVersion] = [:],
            replacedHistory: [String: [ReplacedMediaHistory]] = [:],
            preferences: PlaybackPreferences
        ) {
            self.playbackPositions = playbackPositions
            self.playbackDurations = playbackDurations
            self.completedFiles = completedFiles
            self.lastWatchedFiles = lastWatchedFiles
            self.lastOpenedMedia = lastOpenedMedia
            self.mediaSettings = mediaSettings
            self.mediaVersions = mediaVersions
            self.replacedHistory = replacedHistory
            self.preferences = preferences
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            playbackPositions = try container.decodeIfPresent(
                [String: TimeInterval].self,
                forKey: .playbackPositions
            ) ?? [:]
            playbackDurations = try container.decodeIfPresent(
                [String: TimeInterval].self,
                forKey: .playbackDurations
            ) ?? [:]
            completedFiles = try container.decodeIfPresent(
                Set<String>.self,
                forKey: .completedFiles
            ) ?? []
            lastWatchedFiles = try container.decodeIfPresent(
                [String: String].self,
                forKey: .lastWatchedFiles
            ) ?? [:]
            lastOpenedMedia = try container.decodeIfPresent(
                PlaybackRestoreTarget.self,
                forKey: .lastOpenedMedia
            )
            mediaSettings = try container.decodeIfPresent(
                [String: MediaPlaybackSettings].self,
                forKey: .mediaSettings
            ) ?? [:]
            mediaVersions = try container.decodeIfPresent([String: MediaContentVersion].self, forKey: .mediaVersions) ?? [:]
            replacedHistory = try container.decodeIfPresent([String: [ReplacedMediaHistory]].self, forKey: .replacedHistory) ?? [:]
            preferences = try container.decodeIfPresent(
                PlaybackPreferences.self,
                forKey: .preferences
            ) ?? .standard
        }
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey: String
    private var historyReadFailed = false
    public var hasUnreadableHistory: Bool {
        lock.lock()
        defer { lock.unlock() }
        return historyReadFailed
    }
    private var state: StoredState
    private let historyWriter: CoalescingPersistenceWriter<StoredState>
    private let preferencesWriter: CoalescingPersistenceWriter<PlaybackPreferences>
    private let historyWriteStatus = WriteStatus()
    private let preferencesWriteStatus = WriteStatus()

    /// A failed callback must remain retryable even when a later setter supplies
    /// an unchanged value. No store lock is acquired from this small status lock.
    private final class WriteStatus: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        var needsRetry: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }
        func perform(_ body: () throws -> Void) rethrows {
            do {
                try body()
                lock.lock(); failed = false; lock.unlock()
            } catch {
                lock.lock(); failed = true; lock.unlock()
                throw error
            }
        }
    }

    private final class DefaultsDestination: @unchecked Sendable {
        let defaults: UserDefaults
        init(_ defaults: UserDefaults) { self.defaults = defaults }
    }

    public init(
        userDefaults: UserDefaults = .standard,
        namespace: String = "Illiquid"
    ) {
        self.userDefaults = userDefaults
        storageKey = "\(namespace).playback-state.v1"
        let historyKey = storageKey
        let preferencesKey = "\(namespace).playback-preferences.v1"
        let destination = DefaultsDestination(userDefaults)
        let historyStatus = historyWriteStatus
        let preferencesStatus = preferencesWriteStatus
        historyWriter = CoalescingPersistenceWriter(label: "com.illiquid.history-writer") { snapshot in
            try historyStatus.perform {
                let data = try NonDecodePerformance.measure("HistoryEncode") {
                    let encoder = JSONEncoder()
                    // History is standalone JSON Data, so paths do not need the
                    // optional slash escapes used when embedding JSON in HTML.
                    encoder.outputFormatting = [.withoutEscapingSlashes]
                    return try encoder.encode(snapshot)
                }
                NonDecodePerformance.historyPayload(bytes: data.count)
                NonDecodePerformance.measure("HistoryDefaultsSet") {
                    destination.defaults.set(data, forKey: historyKey)
                }
            }
        }
        preferencesWriter = CoalescingPersistenceWriter(label: "com.illiquid.preferences-writer") { preferences in
            try preferencesStatus.perform {
                destination.defaults.set(try JSONEncoder().encode(preferences), forKey: preferencesKey)
            }
        }

        if let data = userDefaults.data(forKey: storageKey),
           let decodedState = try? JSONDecoder().decode(StoredState.self, from: data)
        {
            state = decodedState
        } else {
            state = .empty
            historyReadFailed = userDefaults.data(forKey: storageKey) != nil
        }
        if let data = userDefaults.data(forKey: preferencesKey),
           let preferences = try? JSONDecoder().decode(PlaybackPreferences.self, from: data) {
            state.preferences = preferences.sanitized()
        }
    }

    public func flush() async -> Result<Void, Error> {
        let interval = NonDecodePerformance.begin("HistoryFlush")
        defer { NonDecodePerformance.end(interval) }
        let history = await historyWriter.flush()
        let preferences = await preferencesWriter.flush()
        if case .failure = history { return history }
        return preferences
    }

    public func flushSynchronously() {
        _ = historyWriter.flushSynchronously()
        _ = preferencesWriter.flushSynchronously()
    }

    public func playbackPosition(for fileURL: URL) -> TimeInterval? {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else {
            return nil
        }

        return withLock { $0.playbackPositions[key] }
    }

    public func playbackProgress(for fileURL: URL) -> MediaPlaybackProgress? {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else {
            return nil
        }

        return withLock { state in
            let position = state.playbackPositions[key] ?? 0
            let duration = state.playbackDurations[key] ?? 0
            let isCompleted = state.completedFiles.contains(key)
            guard position > 0 || duration > 0 || isCompleted else { return nil }
            return MediaPlaybackProgress(
                position: isCompleted && duration > 0 ? duration : position,
                duration: duration,
                isCompleted: isCompleted
            )
        }
    }

    /// Stores a non-negative, finite playback position. Invalid positions and
    /// non-file URLs are ignored and return `false`.
    @discardableResult
    public func setPlaybackPosition(_ position: TimeInterval, for fileURL: URL) -> Bool {
        guard position.isFinite, position >= 0,
              let key = NormalizedFileURL.persistenceKey(for: fileURL)
        else {
            return false
        }

        mutateIfChanged { state in
            if let duration = state.playbackDurations[key], duration > 0,
               position / duration > 0.9 {
                var changed = false
                if !state.completedFiles.contains(key) {
                    state.completedFiles.insert(key); changed = true
                }
                if state.playbackPositions[key] != nil {
                    state.playbackPositions.removeValue(forKey: key); changed = true
                }
                return changed
            }
            guard state.playbackPositions[key] != position else { return false }
            state.playbackPositions[key] = position
            return true
        }
        return true
    }

    /// Stores both values needed to render playlist progress. Crossing 90% is
    /// sticky so a completed episode remains complete when it is replayed.
    @discardableResult
    public func setPlaybackProgress(
        position: TimeInterval,
        duration: TimeInterval,
        for fileURL: URL
    ) -> Bool {
        guard position.isFinite, position >= 0,
              duration.isFinite, duration > 0,
              let key = NormalizedFileURL.persistenceKey(for: fileURL)
        else {
            return false
        }

        mutateIfChanged { state in
            var changed = false
            // An unchanged assignment can still copy a dictionary shared with an
            // in-flight snapshot. Check individual fields BEFORE mutating them.
            if state.playbackDurations[key] != duration {
                state.playbackDurations[key] = duration; changed = true
            }
            if position / duration > 0.9 {
                if !state.completedFiles.contains(key) {
                    state.completedFiles.insert(key); changed = true
                }
                if state.playbackPositions[key] != nil {
                    state.playbackPositions.removeValue(forKey: key); changed = true
                }
            } else if state.playbackPositions[key] != position {
                state.playbackPositions[key] = position; changed = true
            }
            return changed
        }
        return true
    }

    public func markPlaybackCompleted(for fileURL: URL) {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else { return }
        mutateIfChanged { state in
            var changed = false
            if !state.completedFiles.contains(key) {
                state.completedFiles.insert(key); changed = true
            }
            if state.playbackPositions[key] != nil {
                state.playbackPositions.removeValue(forKey: key); changed = true
            }
            return changed
        }
    }

    public func removePlaybackPosition(for fileURL: URL) {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else {
            return
        }

        mutateIfChanged { state in
            guard state.playbackPositions[key] != nil else { return false }
            state.playbackPositions.removeValue(forKey: key)
            return true
        }
    }

    public func lastWatchedFile(for folderURL: URL) -> URL? {
        guard let folderKey = NormalizedFileURL.persistenceKey(for: folderURL),
              let filePath = withLock({ $0.lastWatchedFiles[folderKey] })
        else {
            return nil
        }

        return NormalizedFileURL.normalize(URL(fileURLWithPath: filePath, isDirectory: false))
    }

    public func setLastWatchedFile(_ fileURL: URL?, for folderURL: URL) {
        guard let folderKey = NormalizedFileURL.persistenceKey(for: folderURL) else {
            return
        }

        guard let fileURL else {
            mutateIfChanged { state in
                guard state.lastWatchedFiles[folderKey] != nil else { return false }
                state.lastWatchedFiles.removeValue(forKey: folderKey)
                return true
            }
            return
        }

        guard let filePath = NormalizedFileURL.persistenceKey(for: fileURL) else {
            return
        }

        mutateIfChanged { state in
            guard state.lastWatchedFiles[folderKey] != filePath else { return false }
            state.lastWatchedFiles[folderKey] = filePath
            return true
        }
    }

    public func lastOpenedMedia() -> PlaybackRestoreTarget? {
        withLock { $0.lastOpenedMedia }
    }

    /// Updates the source restored on next launch. Remote URLs are rejected so
    /// this store remains scoped to local playback.
    @discardableResult
    public func setLastOpenedMedia(_ target: PlaybackRestoreTarget?) -> Bool {
        guard let target else {
            mutateIfChanged { state in
                guard state.lastOpenedMedia != nil else { return false }
                state.lastOpenedMedia = nil
                return true
            }
            return true
        }

        guard let normalizedURL = NormalizedFileURL.normalize(target.url) else {
            return false
        }

        let normalizedTarget: PlaybackRestoreTarget = switch target {
        case .file: .file(normalizedURL)
        case .folder: .folder(normalizedURL)
        }
        mutateIfChanged { state in
            guard state.lastOpenedMedia != normalizedTarget else { return false }
            state.lastOpenedMedia = normalizedTarget
            return true
        }
        return true
    }

    public func loadPreferences() -> PlaybackPreferences {
        withLock { $0.preferences }
    }

    public func mediaSettings(for fileURL: URL) -> MediaPlaybackSettings? {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else {
            return nil
        }
        return withLock { $0.mediaSettings[key] }
    }

    public func setMediaSettings(
        _ settings: MediaPlaybackSettings?,
        for fileURL: URL
    ) {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else {
            return
        }
        mutateIfChanged { state in
            guard state.mediaSettings[key] != settings else { return false }
            state.mediaSettings[key] = settings
            return true
        }
    }

    public func mediaVersion(for fileURL: URL) -> MediaContentVersion? {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else { return nil }
        return withLock { $0.mediaVersions[key] }
    }

    public func replacedMediaHistory(for fileURL: URL) -> [ReplacedMediaHistory] {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else { return [] }
        return withLock { $0.replacedHistory[key] ?? [] }
    }

    /// Called after source commit, before applying any saved position or tracks.
    /// Legacy history without a version is retained on its first observation.
    @discardableResult
    public func acceptMediaVersion(_ version: MediaContentVersion, for fileURL: URL) -> MediaContentVersionDisposition {
        guard let key = NormalizedFileURL.persistenceKey(for: fileURL) else { return .firstObservation }
        var disposition = MediaContentVersionDisposition.firstObservation
        mutateIfChanged { state in
            if let previous = state.mediaVersions[key] {
                guard previous != version else { disposition = .unchanged; return false }
                disposition = .changed
                state.replacedHistory[key, default: []].append(ReplacedMediaHistory(
                    version: previous, position: state.playbackPositions[key],
                    duration: state.playbackDurations[key], isCompleted: state.completedFiles.contains(key),
                    mediaSettings: state.mediaSettings[key]
                ))
                state.playbackPositions.removeValue(forKey: key)
                state.playbackDurations.removeValue(forKey: key)
                state.completedFiles.remove(key)
                state.mediaSettings.removeValue(forKey: key)
            }
            state.mediaVersions[key] = version
            return true
        }
        return disposition
    }

    /// Explicit Locate may carry history across a rename when native metadata
    /// verifies the same version. Retain the original record as well.
    @discardableResult
    public func copyHistoryForLocatedMedia(from original: URL, to replacement: URL,
                                          version: MediaContentVersion) -> Bool {
        guard let oldKey = NormalizedFileURL.persistenceKey(for: original),
              let newKey = NormalizedFileURL.persistenceKey(for: replacement), oldKey != newKey,
              let history = withLock({ state -> ReplacedMediaHistory? in
                  guard state.mediaVersions[oldKey] == version else { return nil }
                  return ReplacedMediaHistory(version: version, position: state.playbackPositions[oldKey],
                                              duration: state.playbackDurations[oldKey], isCompleted: state.completedFiles.contains(oldKey),
                                              mediaSettings: state.mediaSettings[oldKey])
              }) else { return false }
        acceptMediaVersion(version, for: replacement)
        mutate { state in
            state.playbackPositions[newKey] = history.position
            state.playbackDurations[newKey] = history.duration
            if history.isCompleted { state.completedFiles.insert(newKey) }
            else { state.completedFiles.remove(newKey) }
            state.mediaSettings[newKey] = history.mediaSettings
        }
        return true
    }

    public func savePreferences(_ preferences: PlaybackPreferences) {
        mutatePreferences { $0.preferences = preferences.sanitized() }
    }

    public func setVolume(_ volume: Double) {
        mutatePreferences {
            // Preferences are sanitized on load/save and by each field setter.
            // Do not normalize unrelated language lists on every slider update.
            $0.preferences.volume = PlaybackPreferences.validVolume(volume)
        }
    }

    public func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences) {
        mutatePreferences { $0.preferences.trackSelection = preferences.sanitized() }
    }

    public func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding) {
        mutatePreferences { $0.preferences.subtitleFallbackEncoding = encoding }
    }

    public func setMuted(_ isMuted: Bool) {
        mutatePreferences { $0.preferences.isMuted = isMuted }
    }

    public func setPlaybackSpeed(_ playbackSpeed: Double) {
        mutatePreferences {
            $0.preferences.playbackSpeed = PlaybackPreferences.validPlaybackSpeed(playbackSpeed)
        }
    }

    public func setSidebarVisible(_ isVisible: Bool) {
        mutatePreferences { $0.preferences.isSidebarVisible = isVisible }
    }

    public func setRepeatMode(_ mode: PlaybackRepeatMode) {
        mutatePreferences { $0.preferences.repeatMode = mode }
    }

    public func setShuffleEnabled(_ isEnabled: Bool) {
        mutatePreferences { $0.preferences.isShuffleEnabled = isEnabled }
    }

    public func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {
        mutatePreferences { $0.preferences.hardwareDecodingPolicy = policy }
    }

    public func setPreferredAudioOutputDeviceID(_ id: String?) {
        let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutatePreferences {
            $0.preferences.preferredAudioOutputDeviceID = normalized.flatMap {
                $0.isEmpty || $0 == "auto" ? nil : $0
            }
        }
    }

    public func clearPlaybackProgress() {
        mutate(allowWhenHistoryDisabled: true) {
            $0.replacedHistory = $0.replacedHistory.mapValues { histories in
                histories.map { history in
                    var history = history
                    history.position = nil
                    history.duration = nil
                    history.isCompleted = false
                    return history
                }
            }
            $0.playbackPositions.removeAll()
            $0.playbackDurations.removeAll()
            $0.completedFiles.removeAll()
            $0.lastWatchedFiles.removeAll()
            $0.lastOpenedMedia = nil
        }
    }

    public func clearRememberedMediaSettings() {
        mutate(allowWhenHistoryDisabled: true) {
            $0.mediaSettings.removeAll()
            $0.replacedHistory = $0.replacedHistory.mapValues { histories in
                histories.map { history in
                    var history = history
                    history.mediaSettings = nil
                    return history
                }
            }
        }
    }

    public func clearPlaybackHistory() {
        mutate(allowWhenHistoryDisabled: true, allowUnreadableReset: true) {
            $0.mediaVersions.removeAll()
            $0.replacedHistory.removeAll()
            $0.playbackPositions.removeAll()
            $0.playbackDurations.removeAll()
            $0.completedFiles.removeAll()
            $0.lastWatchedFiles.removeAll()
            $0.lastOpenedMedia = nil
            $0.mediaSettings.removeAll()
        }
    }

    private func withLock<Result>(_ body: (StoredState) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func mutate(allowWhenHistoryDisabled: Bool = false, allowUnreadableReset: Bool = false, _ body: (inout StoredState) -> Void) {
        mutateIfChanged(allowWhenHistoryDisabled: allowWhenHistoryDisabled,
                        allowUnreadableReset: allowUnreadableReset) {
            body(&$0)
            return true
        }
    }

    /// Callers compare only the affected fields, never the complete history.
    /// Bulk clears intentionally remain unconditional (including unreadable reset).
    private func mutateIfChanged(allowWhenHistoryDisabled: Bool = false, allowUnreadableReset: Bool = false,
                                 _ body: (inout StoredState) -> Bool) {
        let interval = NonDecodePerformance.begin("HistoryMutation")
        lock.lock()
        defer { lock.unlock(); NonDecodePerformance.end(interval) }

        guard !historyReadFailed || allowUnreadableReset else { return }
        guard allowWhenHistoryDisabled || state.preferences.remembersPlaybackHistory else { return }
        if allowUnreadableReset { historyReadFailed = false }
        guard body(&state) || historyWriteStatus.needsRetry else { return }
        // Snapshot capture and serialization retain the v2 lock/lifetime contract.
        historyWriter.submitSnapshot { [self] in
            NonDecodePerformance.measure("HistorySnapshot") { withLock { $0 } }
        }
    }

    private func mutatePreferences(_ body: (inout StoredState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let previous = state.preferences
        body(&state)
        guard previous != state.preferences || preferencesWriteStatus.needsRetry else { return }
        preferencesWriter.submit(state.preferences)
    }
}
