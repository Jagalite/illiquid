import AppKit
import Foundation
import IlliquidCore
import IlliquidNativePlayback
import IlliquidPlayback
import IlliquidPlaybackCore

@MainActor
public final class PlaybackCoordinator {
    private struct PendingPlaybackRestore {
        let source: MediaSource
        let position: TimeInterval
        let wasPaused: Bool
        let playlistIndex: Int?
        let positionIsExplicit: Bool

        init(source: MediaSource, position: TimeInterval, wasPaused: Bool,
             playlistIndex: Int?, positionIsExplicit: Bool = false) {
            self.source = source
            self.position = position
            self.wasPaused = wasPaused
            self.playlistIndex = playlistIndex
            self.positionIsExplicit = positionIsExplicit
        }
    }

    private struct PendingSourceTransaction {
        let previousSessionID: PlaybackSessionID?
        let request: MediaLoadRequest
        let identity: PlayerSessionIdentity
        let folder: URL?
        let playlist: [FolderPlaylistItem]
        let playlistIndex: Int
        let externalSubtitleURLs: [URL]
        let mediaSettings: MediaPlaybackSettings?
        let restoreTarget: PlaybackRestoreTarget?
        let traversalStep: Int?
        let recoverySession: PlaybackSessionRecord?
    }

    private struct PreparedOpenPlan: Sendable {
        let items: [FolderPlaylistItem]
        let subtitleURLs: [URL]
        let folderURL: URL?
        let sourceFolders: [URL]
    }

    private struct PendingBenchmarkControl {
        let session: String
        let id: String
        let action: PlaybackBenchmarkControlAction
        let requestedUptime: TimeInterval
    }

    // Only this module may mutate the product projection. External consumers
    // observe viewStore and send commands through the coordinator.
    let state: PlaybackState
    public let viewStore: PlaybackViewStore
    public let videoColorStore: PlaybackVideoColorStore
    public private(set) var preferredAudioOutputDeviceID: String?
    public private(set) var shutdownPersistenceError: String?
    public var hasUnreadableHistory: Bool { persistence.hasUnreadableHistory }
    public var remembersPlaybackHistory: Bool { persistence.loadPreferences().remembersPlaybackHistory }
    public var restoresSessionPaused: Bool { persistence.loadPreferences().restoresSessionPaused }
    private var retainsCompletedFrame = false

    public func setRemembersPlaybackHistory(_ enabled: Bool) {
        var preferences = persistence.loadPreferences()
        preferences.remembersPlaybackHistory = enabled
        persistence.savePreferences(preferences)
        if !enabled {
            cancelFolderScans()
            pendingPlaybackRestore = nil
            preparedRestoreSession = nil
        }
    }

    public func setRestoresSessionPaused(_ enabled: Bool) {
        var preferences = persistence.loadPreferences()
        preferences.restoresSessionPaused = enabled
        persistence.savePreferences(preferences)
    }

    private let persistence: PlaybackPersistenceStore
    private let sessionStore: any PlaybackSessionStoring
    private let checkpointWriter: CoalescingPersistenceWriter<PlaybackCheckpointMutation>
    private var checkpointFlushTask: Task<Void, Never>?
    private var checkpointRevision: UInt64 = 0
    private var sessionRestoreWasCleared = false
    // Clearing history suppresses passive saves until the position changes or
    // another source commits. Quit, pause and queue edits cannot undo Clear.
    private var progressClearedAtPosition: TimeInterval?
    private var backend: (any PlaybackRuntime)?
    private var runtimeDriver: PlaybackRuntimeDriver?
    private var surfaceHost: (any PlaybackSurfaceHost)?
    private var eventGate = PlaybackRuntimeEventGate()
    private var playbackGeneration: UInt64 = 0
    private var pendingExternalSubtitles: [URL] = []
    private let sourcePreparation = SourcePreparationExecutor.shared
    var isPreparingSource: Bool { !folderScanTasks.isEmpty }
    private var folderScanGeneration = UUID()
    private var folderScanTasks: [UUID: Task<Void, Never>] = [:]
    private struct QueuedSourceOpen {
        let urls: [URL]
        let mode: PlaylistOpenMode
        let folders: @MainActor @Sendable ([URL]) -> Void
        let files: (@MainActor @Sendable ([FolderPlaylistItem]) -> Void)?
    }
    private var queuedSourceOpens: [QueuedSourceOpen] = []
    private var sourceOpenGeneration: UUID?
    private var isShuttingDown = false
    private var isVideoColorSamplingEnabled = false
    private var preparedRestoreSession: PlaybackSessionRecord?
    private var pendingPlaybackRestore: PendingPlaybackRestore?
    private var unshuffledPlaylistIDs: [FolderPlaylistItem.ID]?
    private var pendingSourceTransaction: PendingSourceTransaction?
    private var failedSourceTransaction: PendingSourceTransaction?
    private var pendingMediaSettingFields: Set<MediaPlaybackSetting> = []
    private var hasReceivedCurrentCatalog = false
    private var pendingPositionRestore: PendingPlaybackRestore?
    private var pendingExternalInstallURL: URL?
    private var isDrainingMediaRestore = false
    private var restoreDrainTask: Task<Void, Never>?
    private var pendingExternalSubtitleRestore: (preference: MediaTrackPreference?, visible: Bool)?
    private var ignoresSavedPositionForCurrentSource = false
    private var canPersistCurrentMediaHistory = true
    // A source commit precedes metadata/restore. Never persist its zero-valued
    // loading projection or an optimistic seek target over a valid checkpoint.
    private var hasLoadedCurrentSource = false
    private var checkpointWhenSettled = false
    private var historyCheckpointWhenSettled = false
    private var lastSettledSession: PlaybackSessionRecord?
    private var interruptedRecoverySession: PlaybackSessionRecord?
    private var pendingLocatedSession: PlaybackSessionRecord?
    private var currentContentVersion: MediaContentVersion?
    private var currentMediaSettings = MediaPlaybackSettings()
    private var installedExternalSubtitleURL: URL?
    private var pendingExternalPreferenceURL: URL?
    private var pendingRestoredAudioDelay: Double?
    private let automationQueue = PlaybackAutomationQueue()
    private let automationTimeout: TimeInterval
    private var activeAutomationID: UUID?
    private var automationCheckpointOwner: UUID?
    private var pendingLocatedHistorySource: URL?
    private var lastCheckpointedPosition: TimeInterval = 0
    private var filterMutationTokens: [VideoFilterPreset: UUID] = [:]
    private var pendingBenchmarkTransport: PendingBenchmarkControl?
    private var pendingBenchmarkSeek: PendingBenchmarkControl?
    private var defersBenchmarkCompletionDiagnostics = false
    private var deferredBenchmarkCompletionDiagnostics: [(PendingBenchmarkControl, String)] = []
    var benchmarkDiagnosticHandler: ((String) -> Void)?
    private var playbackCompletionHandler: ((URL) -> Void)?
    private let timelineThumbnailGenerator: NativeTimelineThumbnailGenerator
    private let thumbnailMetadataReader = NativeThumbnailMetadataReader()
    public var thumbnailInteractionHandler: ((URL, Double) -> Void)?
    private var timelineThumbnailRevision: UInt64 = 0
    public var interactionSourceRevision: UInt64 { timelineThumbnailRevision }
    public var pendingOperationLabel: String {
        if state.phase == .preparing { return "Preparing media…" }
        if runtimeDriver?.currentSnapshot.phase == .seeking { return "Seeking…" }
        return state.isLoading ? "Loading media…" : "Buffering…"
    }

    static func softwareVideoOutputPolicy(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> NativeSoftwareVideoOutputPolicy {
        guard bundleIdentifier == "com.example.IlliquidBenchmark",
              environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
        else { return .planarPreferred }
        return environment["ILLIQUID_BENCHMARK_SOFTWARE_OUTPUT"] == "planar"
            ? .planarExperimental : .bgra
    }

    public func setVideoColorSamplingEnabled(_ enabled: Bool) {
        guard isVideoColorSamplingEnabled != enabled else { return }
        isVideoColorSamplingEnabled = enabled
        backend?.setVideoColorSamplingEnabled(enabled)
        if !enabled {
            videoColorStore.reset()
        }
    }

    static func benchmarkVideoFrameQueueCapacity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Int {
        guard bundleIdentifier == "com.example.IlliquidBenchmark",
              environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1",
              let raw = environment[
                "ILLIQUID_BENCHMARK_VIDEO_FRAME_QUEUE_CAPACITY"
              ],
              let value = Int(raw), [4, 6, 8, 12].contains(value)
        else { return 12 }
        return value
    }

    static func benchmarkSoftwarePlanarPoolCapacity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Int {
        guard bundleIdentifier == "com.example.IlliquidBenchmark",
              environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1",
              let raw = environment[
                "ILLIQUID_BENCHMARK_PLANAR_POOL_CAPACITY"
              ],
              let value = Int(raw), [8, 10, 12, 16].contains(value)
        else { return 16 }
        return value
    }

    static func benchmarkReservesVideoPipelineCapacity(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard bundleIdentifier == "com.example.IlliquidBenchmark",
              environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
        else { return true }
        return environment[
            "ILLIQUID_BENCHMARK_RESERVE_VIDEO_PIPELINE_CAPACITY"
        ] != "0"
    }

    static func benchmarkVideoPipelineCapacityOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Int? {
        guard bundleIdentifier == "com.example.IlliquidBenchmark",
              environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1",
              let raw = environment[
                "ILLIQUID_BENCHMARK_VIDEO_PIPELINE_CAPACITY"
              ],
              let value = Int(raw), (1...16).contains(value)
        else { return nil }
        return value
    }

    static func benchmarkUsesFairDemuxDispatch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == "com.example.IlliquidBenchmark"
            && environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
            && environment["ILLIQUID_BENCHMARK_FAIR_DEMUX_DISPATCH"] == "1"
    }

    static func benchmarkControlEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == "com.example.IlliquidBenchmark"
            && environment["ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"] == "1"
            && environment["ILLIQUID_BENCHMARK_CONTROL_SESSION"]?.isEmpty == false
    }

    public init(
        persistence: PlaybackPersistenceStore = PlaybackPersistenceStore(),
        sessionStore: any PlaybackSessionStoring = AtomicPlaybackSessionStore(),
        runtime: (any PlaybackRuntime)? = nil,
        thumbnailCacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Illiquid/Thumbnails-v1", isDirectory: true),
        automationTimeout: TimeInterval = 30
    ) {
        let timing = LifecyclePerformance.begin("controller-init")
        defer { LifecyclePerformance.end("controller-init", since: timing) }
        timelineThumbnailGenerator = NativeTimelineThumbnailGenerator(cacheDirectory: thumbnailCacheDirectory)
        self.persistence = persistence
        self.automationTimeout = min(max(automationTimeout.isFinite ? automationTimeout : 30, 0.05), 120)
        self.sessionStore = sessionStore
        checkpointWriter = CoalescingPersistenceWriter(label: "com.illiquid.session-writer") {
            try $0.apply(to: sessionStore)
        }
        let preferences = persistence.loadPreferences()
        preferredAudioOutputDeviceID = preferences.preferredAudioOutputDeviceID
        let playbackState = PlaybackState(preferences: preferences)
        state = playbackState
        if persistence.hasUnreadableHistory {
            playbackState.setRecoveryIssue(.init(kind: .message, message: "Playback history could not be read. The saved data has been kept and new history will not replace it. You can quit and retry, or explicitly clear history in Settings.", source: nil))
        }
        videoColorStore = PlaybackVideoColorStore()
        let viewStore = PlaybackViewStore(snapshot: PlaybackViewSnapshot(state: playbackState))
        self.viewStore = viewStore
        playbackState.onMutation = { [weak playbackState, weak viewStore] in
            guard let playbackState else { return }
            viewStore?.publish(PlaybackViewSnapshot(state: playbackState))
        }

        do {
            let backend: any PlaybackRuntime
            if let runtime {
                backend = runtime
            } else {
                let policy = Self.softwareVideoOutputPolicy()
                let queueCapacity = Self.benchmarkVideoFrameQueueCapacity()
                let reservesPipelineCapacity =
                    Self.benchmarkReservesVideoPipelineCapacity()
                let pipelineCapacityOverride =
                    Self.benchmarkVideoPipelineCapacityOverride()
                let usesFairDemuxDispatch =
                    Self.benchmarkUsesFairDemuxDispatch()
                let planarPoolCapacity = Self.benchmarkSoftwarePlanarPoolCapacity()
                if Bundle.main.bundleIdentifier == "com.example.IlliquidBenchmark",
                   ProcessInfo.processInfo.environment[
                    "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"
                   ] == "1"
                {
                    let message = "[native-benchmark] "
                        + "software-output=\(policy.rawValue) "
                        + "video-frame-queue=\(queueCapacity) "
                        + "reserve-video-pipeline-capacity="
                        + "\(reservesPipelineCapacity) "
                        + "video-pipeline-capacity="
                        + "\(pipelineCapacityOverride.map(String.init) ?? "auto") "
                        + "fair-demux-dispatch=\(usesFairDemuxDispatch) "
                        + "planar-pool-cap=\(planarPoolCapacity)\n"
                    FileHandle.standardError.write(Data(message.utf8))
                }
                backend = try NativePlaybackRuntime(
                    softwareVideoOutputPolicy: policy,
                    videoFrameQueueCapacity: queueCapacity,
                    reservesVideoPipelineCapacity: reservesPipelineCapacity,
                    videoPipelineCapacityOverride: pipelineCapacityOverride,
                    usesFairDemuxDispatch: usesFairDemuxDispatch,
                    softwarePlanarOutputMaximumBufferCount: planarPoolCapacity
                )
            }
            self.backend = backend
            backend.setTrackSelectionPreferences(preferences.trackSelection)
            backend.setSubtitleFallbackEncoding(state.subtitleFallbackEncoding)
            let driver = PlaybackRuntimeDriver(runtime: backend)
            runtimeDriver = driver
            driver.onRuntimeEvent = { [weak self] event in self?.handle(event) }
            driver.onTransition = { [weak self] transition in
                self?.applyCoreTransition(transition)
            }
            driver.onPersistCheckpoint = { [weak self] in
                guard let self, saveCurrentProgress() else { return false }
                return await flushPlaybackPersistence()
            }
            driver.onAdvancePlaylist = { [weak self] in
                guard let self else { return }
                let completedFile = canPersistCurrentMediaHistory && progressClearedAtPosition == nil
                    ? state.currentURL : nil
                if state.repeatMode == .one,
                   let currentIndex = state.currentPlaylistIndex
                {
                    playItem(
                        at: currentIndex,
                        origin: state.currentSourceOrigin ?? .userSelected,
                        reloadCurrent: true,
                        traversalStep: 1
                    )
                } else if state.hasNextItem {
                    playNext()
                } else if state.repeatMode == .all, !state.playlist.isEmpty {
                    playItem(at: state.playlist.startIndex, origin: state.currentSourceOrigin ?? .userSelected,
                             traversalStep: 1)
                } else {
                    retainsCompletedFrame = true
                    pause()
                }
                if let completedFile {
                    persistence.markPlaybackCompleted(for: completedFile)
                    playbackCompletionHandler?(completedFile)
                }
            }
            let capabilityModel = PlayerCapabilityModel(capabilities: backend.capabilities)
            let effectivePlaybackSpeed = capabilityModel.sanitizedPlaybackSpeed(
                preferences.playbackSpeed
            )
            if state.playbackSpeed != effectivePlaybackSpeed {
                state.setPlaybackSpeed(effectivePlaybackSpeed)
                persistence.setPlaybackSpeed(effectivePlaybackSpeed)
            }
            backend.setVolume(preferences.volume)
            backend.setMuted(preferences.isMuted)
            backend.setHardwareDecodingPolicy(preferences.hardwareDecodingPolicy)
            if capabilityModel.supports(.changePlaybackSpeed) {
                _ = runtimeDriver?.setPlaybackSpeed(effectivePlaybackSpeed)
                backend.setPlaybackSpeed(effectivePlaybackSpeed)
            }
        } catch {
            state.setShellError(error.localizedDescription)
            backend = nil
        }
    }

    public func open(url: URL) {
        open(url: url, origin: .userSelected)
    }

    public func reportError(_ message: String) { state.setShellError(message) }
    public func clearError() { state.setShellError(nil) }

    public func dismissRecovery() {
        failedSourceTransaction = nil
        state.setRecoveryIssue(nil)
    }

    public func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences) {
        let preferences = preferences.sanitized()
        persistence.setTrackSelectionPreferences(preferences)
        state.setTrackSelectionPreferences(preferences)
        backend?.setTrackSelectionPreferences(preferences)
    }

    public func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding) {
        persistence.setSubtitleFallbackEncoding(encoding)
        state.setSubtitleFallbackEncoding(encoding)
        backend?.setSubtitleFallbackEncoding(encoding)
    }

    public func retryRecovery() {
        if let failed = failedSourceTransaction {
            if let saved = failed.recoverySession {
                pendingPlaybackRestore = PendingPlaybackRestore(source: failed.request.source,
                    position: saved.position, wasPaused: saved.wasPaused, playlistIndex: failed.playlistIndex)
                pendingLocatedHistorySource = saved.source.url
            }
            beginSourceTransaction(
                item: failed.playlist[failed.playlistIndex], playlist: failed.playlist,
                folder: failed.folder, playlistIndex: failed.playlistIndex,
                origin: failed.request.origin, restoreTarget: failed.restoreTarget,
                traversalStep: failed.traversalStep, recoverySession: failed.recoverySession
            )
        } else if case .interruptedSource = state.recoveryIssue?.kind,
                  let saved = interruptedRecoverySession {
            applyLocatedSession(at: saved.source.url, isFolder: false, saved: saved)
        } else if case .unavailableRestore = state.recoveryIssue?.kind {
            _ = restoreLastSession()
        }
    }

    private func discardFailedTraversalForPlaylistChange() {
        if failedSourceTransaction != nil { dismissRecovery() }
    }

    public func skipFailedSource() {
        guard let failed = failedSourceTransaction,
              let step = failed.traversalStep,
              failed.playlist.indices.contains(failed.playlistIndex + step)
        else { return }
        let next = failed.playlistIndex + step
        // Each explicit Skip tries one item. Never silently loop through a
        // broken playlist or wrap back to an already failed entry.
        beginSourceTransaction(
            item: failed.playlist[next], playlist: failed.playlist,
            folder: failed.folder, playlistIndex: next,
            origin: failed.request.origin, restoreTarget: failed.folder.map(PlaybackRestoreTarget.folder)
                ?? .file(failed.playlist[next].url), traversalStep: step
        )
    }

    public func forgetUnavailableSession() {
        guard case .unavailableRestore = state.recoveryIssue?.kind else { return }
        cancelFolderScans()
        pendingPlaybackRestore = nil
        persistence.setLastOpenedMedia(nil)
        clearSavedPlaybackSession()
        dismissRecovery()
    }

    public func locateUnavailableSession(at url: URL, expectedIssueID: UUID? = nil) {
        guard let issue = state.recoveryIssue, url.isFileURL,
              expectedIssueID == nil || issue.id == expectedIssueID else { return }
        let saved: PlaybackSessionRecord?
        let isFolder: Bool
        switch issue.kind {
        case .unavailableRestore(let folder):
            if let session = preparedRestoreSession {
                saved = session
            } else if let source = issue.source, !folder {
                saved = PlaybackSessionRecord(source: .localFile(source),
                    position: persistence.playbackPosition(for: source) ?? 0, wasPaused: restoresSessionPaused)
            } else { saved = nil }
            isFolder = folder
        case .failedSource:
            guard let failed = failedSourceTransaction, !failed.request.source.isRemote else { return }
            saved = failed.recoverySession ?? recoveryRecord(for: failed)
            isFolder = false
        case .interruptedSource:
            saved = interruptedRecoverySession
            isFolder = false
        case .message: return
        }
        guard saved != nil || isFolder else { return }
        cancelFolderScans()
        let generation = folderScanGeneration
        let preparation = sourcePreparation
        folderScanTasks[generation] = Task { @MainActor [weak self] in
            let result = await preparation.result { check in
                try check()
                let resolved = NormalizedFileURL.resolveFilesystemIdentity(url) ?? url
                try check()
                return resolved
            }
            guard let self else { return }
            defer { folderScanTasks[generation] = nil }
            guard !Task.isCancelled, !isShuttingDown, generation == folderScanGeneration,
                  state.recoveryIssue?.id == issue.id else { return }
            do { applyLocatedSession(at: try result.get(), isFolder: isFolder, saved: saved) }
            catch { state.setShellError(error.localizedDescription) }
        }
    }

    private func applyLocatedSession(at url: URL, isFolder: Bool, saved: PlaybackSessionRecord?) {
        guard let saved else {
            // Legacy history may have a restore target but no session document.
            if isFolder { openFolder(url: url, origin: .restoredSession) }
            else { open(url: url, origin: .restoredSession) }
            return
        }
        let sourceURL = isFolder
            ? url.appendingPathComponent(saved.source.url.lastPathComponent, isDirectory: false) : url
        pendingLocatedHistorySource = saved.source.url
        pendingLocatedSession = saved
        pendingPlaybackRestore = PendingPlaybackRestore(
            source: .localFile(sourceURL), position: saved.position,
            wasPaused: saved.wasPaused, playlistIndex: nil
        )
        // Do not publish the replacement session until loading and its restored
        // seek have completed. Rejected Locate and retry attempts retain saved.
        dismissRecovery()
        if isFolder {
            openFolder(url: url, origin: .restoredSession)
        } else {
            var items = saved.playlistItems.map { item in
                item.url == saved.source.url
                    ? FolderPlaylistItem(url: url, externalSubtitleURLs: item.externalSubtitleURLs,
                                         dateAdded: item.dateAdded) : item
            }
            if !items.contains(where: { $0.url == url }) { items.append(FolderPlaylistItem(url: url)) }
            guard let index = items.firstIndex(where: { $0.url == url }) else { return }
            beginSourceTransaction(item: items[index], playlist: items, folder: nil,
                playlistIndex: index, origin: .restoredSession, restoreTarget: .file(url), recoverySession: saved)
        }
    }

    private func recoveryRecord(for failed: PendingSourceTransaction) -> PlaybackSessionRecord {
        let restore = pendingPlaybackRestore.flatMap {
            $0.source.representsSameResource(as: failed.request.source) ? $0 : nil
        }
        return PlaybackSessionRecord(source: failed.request.source, collectionFolder: failed.folder,
            playlistItems: failed.playlist, playlistIndex: failed.playlistIndex,
            position: restore?.position ?? persistence.playbackPosition(for: failed.request.source.url) ?? 0,
            wasPaused: restore?.wasPaused ?? true)
    }

    private func reportUnavailableRestore(_ url: URL, isFolder: Bool) {
        state.setRecoveryIssue(PlaybackRecoveryIssue(
            kind: .unavailableRestore(isFolder: isFolder),
            message: "The previous \(isFolder ? "folder" : "file") is unavailable. Reconnect its drive and retry, or locate it.",
            source: url
        ))
    }

    private func open(url: URL, origin: MediaSourceOrigin) {
        guard !isShuttingDown else { return }
        guard url.isFileURL else {
            state.setShellError("Use Open Location to open an HTTP or HTTPS stream.")
            return
        }

        // A file open supersedes any folder discovery still running, including
        // a launch-time session restore that Finder may immediately override.
        cancelFolderScans()
        supersedePendingRestore(ifNeededFor: origin)

        let generation = folderScanGeneration
        let preparation = sourcePreparation
        let worker = Task {
            await preparation.result { check in
                try check()
                let resolved = NormalizedFileURL.resolveFilesystemIdentity(url) ?? url
                try check()
                return FolderPlaylistItem(url: resolved, dateAdded: FolderPlaylistItem.metadataDate(for: resolved))
            }
        }
        folderScanTasks[generation] = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler { await worker.value }
                onCancel: { worker.cancel() }
            guard let self else { return }
            defer { folderScanTasks[generation] = nil }
            guard !Task.isCancelled, !isShuttingDown, generation == folderScanGeneration else { return }
            do {
                let item = try result.get()
                if let index = state.playlist.firstIndex(where: {
                    NormalizedFileURL.representsSameFile($0.url, item.url)
                }) {
                    playItem(at: index, origin: origin)
                } else {
                    beginSourceTransaction(item: item, playlist: [item], folder: nil,
                        playlistIndex: 0, origin: origin, restoreTarget: .file(item.url))
                }
            } catch { state.setShellError(error.localizedDescription) }
        }
    }

    /// A tab activation is an explicit source transaction through the core's
    /// existing load path. Resume state is applied only to the matching source.
    @discardableResult
    public func activateOpenVideo(_ tab: OpenVideoTab) -> Bool {
        guard !isShuttingDown, backend != nil,
              !tab.source.isRemote || supports(.openRemoteStream) else { return false }
        cancelFolderScans()
        pendingLocatedHistorySource = nil
        let items = tab.playlist
        guard let index = items.firstIndex(where: {
            MediaSource(url: $0.url)?.representsSameResource(as: tab.source) == true
        }) else { return false }
        pendingPlaybackRestore = PendingPlaybackRestore(
            source: tab.source, position: tab.position, wasPaused: tab.wasPaused, playlistIndex: index
        )
        let accepted = beginSourceTransaction(item: items[index], playlist: items, folder: tab.folder,
            playlistIndex: index, origin: .userSelected,
            restoreTarget: tab.source.isRemote ? nil : (tab.folder.map(PlaybackRestoreTarget.folder) ?? .file(tab.source.url)))
        if !accepted { pendingPlaybackRestore = nil }
        return accepted
    }

    public func openRemoteStream(url: URL) {
        guard supports(.openRemoteStream, operation: "remote streams") else { return }
        guard let source = MediaSource(url: url), source.isRemote else {
            state.setShellError("Enter an HTTP or HTTPS media URL.")
            return
        }
        cancelFolderScans()
        pendingPlaybackRestore = nil
        let item = FolderPlaylistItem(url: source.url)
        beginSourceTransaction(
            item: item,
            playlist: [item],
            folder: nil,
            playlistIndex: 0,
            origin: .userSelected,
            restoreTarget: nil
        )
    }

    public func open(
        urls: [URL], mode: PlaylistOpenMode = .replace,
        foldersAsSources: (@MainActor @Sendable ([URL]) -> Void)? = nil
    ) {
        open(urls: urls, mode: mode, openedFiles: nil, foldersAsSources: foldersAsSources)
    }

    public func open(
        urls: [URL], mode: PlaylistOpenMode = .replace,
        openedFiles: (@MainActor @Sendable ([FolderPlaylistItem]) -> Void)?,
        foldersAsSources: (@MainActor @Sendable ([URL]) -> Void)? = nil
    ) {
        guard !isShuttingDown, !urls.isEmpty else { return }
        if let foldersAsSources, sourceOpenGeneration != nil {
            guard queuedSourceOpens.count < 64 else {
                state.setShellError("Too many pending open requests. Wait for file access, then retry.")
                return
            }
            queuedSourceOpens.append(QueuedSourceOpen(urls: urls, mode: mode, folders: foldersAsSources, files: openedFiles))
            return
        }
        cancelFolderScans()
        startBatchOpen(urls: urls, mode: mode, openedFiles: openedFiles, foldersAsSources: foldersAsSources)
    }

    private func startBatchOpen(
        urls: [URL], mode: PlaylistOpenMode,
        openedFiles: (@MainActor @Sendable ([FolderPlaylistItem]) -> Void)?,
        foldersAsSources: (@MainActor @Sendable ([URL]) -> Void)?
    ) {
        pendingLocatedHistorySource = nil
        pendingPlaybackRestore = nil
        let generation = UUID()
        folderScanGeneration = generation
        if foldersAsSources != nil { sourceOpenGeneration = generation }
        let preparation = sourcePreparation
        let worker = Task {
            await preparation.result { check in
                try Self.prepareOpenPlan(urls, expandsFolders: foldersAsSources == nil, checkCancellation: check)
            }
        }
        let scanTask = Task { @MainActor [weak self] in
            let plan = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            defer {
                folderScanTasks[generation] = nil
                if sourceOpenGeneration == generation {
                    sourceOpenGeneration = nil
                    if !isShuttingDown, !queuedSourceOpens.isEmpty {
                        let next = queuedSourceOpens.removeFirst()
                        startBatchOpen(urls: next.urls, mode: next.mode, openedFiles: next.files, foldersAsSources: next.folders)
                    }
                }
            }
            guard !Task.isCancelled, generation == folderScanGeneration else { return }
            do {
                let prepared = try plan.get()
                openedFiles?(prepared.items)
                foldersAsSources?(prepared.sourceFolders)
                if prepared.items.isEmpty, prepared.subtitleURLs.isEmpty, !prepared.sourceFolders.isEmpty { return }
                applyOpenPlan(prepared, mode: mode)
            }
            catch { state.setShellError(error.localizedDescription) }
        }
        folderScanTasks[generation] = scanTask
    }

    public func openFolder(url: URL) {
        openFolder(url: url, origin: .userSelected)
    }

    /// Plays a file selected from the source browser while keeping its containing
    /// folder as the Previous/Next navigation scope.
    public func openFileInContainingFolder(url: URL) {
        guard !isShuttingDown else { return }
        guard url.isFileURL, MediaFileSupport.isSupportedMediaFile(url) else {
            state.setShellError("The selected file is not a supported video.")
            return
        }

        let folderURL = url.deletingLastPathComponent()
        if let currentFolder = state.currentFolder,
           NormalizedFileURL.representsSameFile(currentFolder, folderURL),
           let existingIndex = state.playlist.firstIndex(where: {
               NormalizedFileURL.representsSameFile($0.url, url)
           })
        {
            cancelFolderScans()
            playItem(at: existingIndex, origin: .userSelected)
            return
        }

        cancelFolderScans()
        supersedePendingRestore(ifNeededFor: .userSelected)
        let generation = UUID()
        folderScanGeneration = generation
        let preparation = sourcePreparation
        let worker = Task {
            await preparation.result { check in
                let selectedURL = NormalizedFileURL.resolveFilesystemIdentity(url) ?? url
                try check()
                let playlist = try FolderPlaylistDiscovery.discover(in: folderURL, checkCancellation: check)
                return (playlist, selectedURL)
            }
        }
        let scanTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            defer { folderScanTasks[generation] = nil }
            guard !Task.isCancelled, generation == folderScanGeneration else { return }

            do {
                let (playlist, selectedURL) = try result.get()
                guard let selectedIndex = playlist.index(of: selectedURL) else {
                    state.setShellError("The selected video is no longer available.")
                    return
                }
                beginSourceTransaction(
                    item: playlist.items[selectedIndex],
                    playlist: playlist.items,
                    folder: playlist.folderURL,
                    playlistIndex: selectedIndex,
                    origin: .userSelected,
                    restoreTarget: .folder(playlist.folderURL)
                )
            } catch {
                guard !Task.isCancelled, generation == folderScanGeneration else { return }
                state.setShellError(error.localizedDescription)
            }
        }
        folderScanTasks[generation] = scanTask
    }

    private func openFolder(url: URL, origin: MediaSourceOrigin) {
        guard !isShuttingDown else { return }
        dismissRecovery()
        cancelFolderScans()
        supersedePendingRestore(ifNeededFor: origin)
        let generation = UUID()
        folderScanGeneration = generation
        let preparation = sourcePreparation
        let worker = Task {
            await preparation.result { check in
                try FolderPlaylistDiscovery.discover(in: url, checkCancellation: check)
            }
        }
        let scanTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self else { return }
            defer { folderScanTasks[generation] = nil }
            guard !Task.isCancelled, generation == folderScanGeneration else { return }
            do {
                let playlist = try result.get()
                guard let initialIndex = playlist.initialIndex(
                    restoring: persistence.lastWatchedFile(for: url)
                ) else {
                    state.setShellError("The selected folder contains no supported media files.")
                    return
                }

                let orderedItems = PlaylistMutation.sorted(
                    playlist.items,
                    by: .dateAdded,
                    ascending: false
                )
                let indexOfURL: (URL) -> Int? = { url in
                    orderedItems.firstIndex {
                        NormalizedFileURL.representsSameFile($0.url, url)
                    }
                }
                let restoredIndex: Int? = if origin == .restoredSession,
                                             let pendingPlaybackRestore
                {
                    if case let .localFile(savedURL) = pendingPlaybackRestore.source,
                       let sourceIndex = indexOfURL(savedURL)
                    {
                        sourceIndex
                    } else if let savedIndex = pendingPlaybackRestore.playlistIndex,
                              orderedItems.indices.contains(savedIndex)
                    {
                        savedIndex
                    } else {
                        initialIndex
                    }
                } else {
                    nil
                }
                let currentIndex = state.currentURL.flatMap(indexOfURL)
                let initialURL = playlist.items[initialIndex].url
                let selectedIndex = if origin == .restoredSession {
                    restoredIndex
                        ?? currentIndex
                        ?? indexOfURL(initialURL)
                        ?? orderedItems.startIndex
                } else {
                    currentIndex ?? orderedItems.startIndex
                }
                if currentIndex == nil || origin == .restoredSession {
                    beginSourceTransaction(
                        item: orderedItems[selectedIndex],
                        playlist: orderedItems,
                        folder: playlist.folderURL,
                        playlistIndex: selectedIndex,
                        origin: origin,
                        restoreTarget: .folder(playlist.folderURL)
                    )
                } else {
                    discardFailedTraversalForPlaylistChange()
                    state.configurePlaylist(
                        folder: playlist.folderURL,
                        items: orderedItems,
                        selectedIndex: selectedIndex
                    )
                    persistence.setLastOpenedMedia(.folder(playlist.folderURL))
                    checkpointSession()
                }
            } catch {
                guard !Task.isCancelled, generation == folderScanGeneration else { return }
                state.setShellError(error.localizedDescription)
                if origin == .restoredSession { reportUnavailableRestore(url, isFolder: true) }
            }
        }
        folderScanTasks[generation] = scanTask
    }

    public func play() {
        activeAutomationID = nil
        updatePendingRestoreTransport(paused: false)
        if retainsCompletedFrame {
            retainsCompletedFrame = false
            seek(to: 0)
        }
        if eventGate.activeIdentity == nil,
           let index = state.currentPlaylistIndex,
           state.phase == .idle || state.phase == .failed
        {
            playItem(at: index, origin: state.currentSourceOrigin ?? .userSelected)
            return
        }
        _ = runtimeDriver?.play()
    }

    public func pause() {
        activeAutomationID = nil
        updatePendingRestoreTransport(paused: true)
        _ = runtimeDriver?.pause()
    }

    public func togglePause() {
        state.isPauseDesired ? play() : pause()
    }

    public func stop() {
        activeAutomationID = nil
        retainsCompletedFrame = false
        invalidateTimelineThumbnails()
        cancelFolderScans()
        pendingLocatedHistorySource = nil
        pendingPlaybackRestore = nil
        saveCurrentProgress()
        pendingMediaSettingFields.removeAll()
        pendingPositionRestore = nil
        pendingExternalInstallURL = nil
        pendingRestoredAudioDelay = nil
        restoreDrainTask?.cancel()
        restoreDrainTask = nil
        pendingSourceTransaction = nil
        dismissRecovery()
        eventGate.activate(nil)
        _ = runtimeDriver?.stop()
    }

    /// Closes media instead of keeping Stop's replayable file and playlist.
    public func closeCurrentVideo() {
        guard !isShuttingDown else { return }
        stop()
        persistence.setLastOpenedMedia(nil)
        clearSavedPlaybackSession()
        discardFailedTraversalForPlaylistChange()
        pendingExternalSubtitles = []
        pendingMediaSettingFields.removeAll()
        pendingExternalSubtitleRestore = nil
        pendingExternalPreferenceURL = nil
        installedExternalSubtitleURL = nil
        pendingRestoredAudioDelay = nil
        currentMediaSettings = MediaPlaybackSettings()
        hasLoadedCurrentSource = false
        currentContentVersion = nil
        lastSettledSession = nil
        interruptedRecoverySession = nil
        videoColorStore.reset()
        state.clearMediaMetadata()
    }

    public func seek(relative seconds: TimeInterval) {
        activeAutomationID = nil
        pendingPositionRestore = nil
        pendingPlaybackRestore = nil
        checkpointWhenSettled = true
        historyCheckpointWhenSettled = true
        _ = runtimeDriver?.seek(to: seconds, mode: .relative)
    }

    public func seek(to seconds: TimeInterval) {
        activeAutomationID = nil
        pendingPositionRestore = nil
        pendingPlaybackRestore = nil
        checkpointWhenSettled = true
        historyCheckpointWhenSettled = true
        retainsCompletedFrame = false
        _ = runtimeDriver?.seek(to: seconds, mode: .exact)
    }

    public func previewSeek(to seconds: TimeInterval) {
        activeAutomationID = nil
        pendingPositionRestore = nil
        pendingPlaybackRestore = nil
        checkpointWhenSettled = true
        historyCheckpointWhenSettled = true
        retainsCompletedFrame = false
        _ = runtimeDriver?.seek(to: seconds, mode: .preview)
    }

    public func timelineThumbnail(
        at seconds: TimeInterval,
        maximumPixelSize: CGSize,
        delayBeforeDecoding: Duration = .zero
    ) async -> CGImage? {
        guard !isShuttingDown, let source = state.currentSource,
              source.url.isFileURL,
              state.videoAspectRatio != nil
        else { return nil }
        thumbnailInteractionHandler?(source.url, seconds)
        let revision = timelineThumbnailRevision
        let image = await timelineThumbnailGenerator.thumbnail(
            for: source.url,
            at: seconds,
            maximumPixelSize: maximumPixelSize,
            delayBeforeDecoding: delayBeforeDecoding,
            sourceRevision: revision,
            allowDecoding: !state.phase.isLoading && runtimeDriver?.currentSnapshot.phase != .seeking
        )
        guard !isShuttingDown, revision == timelineThumbnailRevision else { return nil }
        return image
    }

    public func cachedTimelineThumbnail(at seconds: Double, maximumPixelSize: CGSize,
                                         maximumDistance: Double) async -> CachedTimelineThumbnail? {
        guard !isShuttingDown, let url = state.currentURL, url.isFileURL else { return nil }
        thumbnailInteractionHandler?(url, seconds)
        let revision = timelineThumbnailRevision
        let result = await timelineThumbnailGenerator.cachedThumbnail(for: url, at: seconds,
            size: maximumPixelSize, maximumDistance: maximumDistance, sourceRevision: revision,
            storyboardDuration: state.duration)
        return !isShuttingDown && revision == timelineThumbnailRevision ? result : nil
    }

    public func configureThumbnailCache(_ preferences: ThumbnailPreferences) async {
        await timelineThumbnailGenerator.configure(preferences)
    }

    public func clearThumbnailCache() async -> Bool {
        invalidateTimelineThumbnails()
        return await timelineThumbnailGenerator.removeAllCachedThumbnails()
    }

    public func thumbnailDuration(for url: URL) async -> Double? {
        guard !isShuttingDown, !Task.isCancelled else { return nil }
        return await thumbnailMetadataReader.duration(of: url)
    }

    public func prewarmThumbnail(for url: URL, at seconds: Double, currentVideo: Bool = false) async -> Bool {
        guard !isShuttingDown, !Task.isCancelled,
              ((state.phase == .idle || state.phase == .paused) && state.isPauseDesired)
                || (currentVideo && url == state.currentURL && state.phase == .playing
                    && runtimeDriver?.currentSnapshot.phase == .playing),
              runtimeDriver?.currentSnapshot.phase != .seeking else { return false }
        return await timelineThumbnailGenerator.thumbnail(for: url, at: seconds,
            maximumPixelSize: CGSize(width: 368, height: 208), background: true,
            storyboard: currentVideo && url == state.currentURL && ThumbnailPolicy.storyboard(duration: state.duration).contains(seconds)) != nil
    }

    public func releaseIdleThumbnailResources() async {
        await timelineThumbnailGenerator.releaseIdleResources()
    }

    public func thumbnailCacheUsage() async -> ThumbnailCacheUsage {
        await timelineThumbnailGenerator.cacheUsage()
    }

    public func handleThumbnailMemoryPressure(critical: Bool) async {
        await timelineThumbnailGenerator.handleMemoryPressure(critical: critical)
    }

    private func invalidateTimelineThumbnails() {
        timelineThumbnailRevision &+= 1
        let revision = timelineThumbnailRevision
        Task { [timelineThumbnailGenerator] in
            await timelineThumbnailGenerator.invalidate(for: revision)
        }
    }

    /// Executes an acknowledged, benchmark-only control without routing
    /// through screen coordinates. Renderer-backed presentation evidence is
    /// emitted separately by the snapshot action so command acceptance is
    /// never mislabeled as visible completion.
    @discardableResult
    public func executeBenchmarkControl(
        session: String,
        id: String,
        action: PlaybackBenchmarkControlAction,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard Self.benchmarkControlEnabled(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        ),
        environment["ILLIQUID_BENCHMARK_CONTROL_SESSION"] == session,
        Self.isValidBenchmarkControlToken(session),
        Self.isValidBenchmarkControlToken(id)
        else { return false }

        if case let .seekExact(target) = action,
           (!target.isFinite || target < 0)
        {
            writeBenchmarkControlDiagnostic(
                session: session,
                id: id,
                action: action,
                fields: "phase=rejected accepted=no reason=invalid-target"
            )
            return false
        }

        if case .rendererMetrics = action {
            Task { [weak self] in
                guard let self else { return }
                let metrics = await (backend as? NativePlaybackRuntime)?.benchmarkRendererMetrics()
                writeBenchmarkControlDiagnostic(session: session, id: id, action: action,
                    fields: "phase=completed accepted=yes metrics-available=\(metrics != nil ? "yes" : "no") " + (metrics ?? ""))
            }
            return true
        }
        if case .snapshot = action {
            guard let snapshot = (backend as? NativePlaybackRuntime)?.diagnosticSnapshot else {
                writeBenchmarkControlDiagnostic(
                    session: session,
                    id: id,
                    action: action,
                    fields: "phase=snapshot accepted=no reason=no-active-snapshot"
                )
                return false
            }
            let displayed = environment["ILLIQUID_BENCHMARK_DISPLAY_READBACK"] == "1"
                ? (backend as? NativePlaybackRuntime)?.pausedReadbackDiagnostic() : nil
            let displayedFields = " displayed-pts=\(displayed?.displayedPTS.map { String($0) } ?? "unavailable")"
                + " displayed-generation=\(displayed?.displayedGeneration.map { String($0) } ?? "unavailable")"
                + " displayed-current=\(displayed?.isCurrent == true ? "yes" : "no")"
            writeBenchmarkControlDiagnostic(
                session: session,
                id: id,
                action: action,
                fields: "phase=snapshot accepted=yes "
                    + "generation=\(snapshot.mediaGeneration) "
                    + "renderer-time="
                    + String(format: "%.6f", snapshot.rendererMediaTimeSeconds)
                    + " renderer-rate=\(snapshot.rendererRate) "
                    + "renderer-clock-advanced="
                    + "\(snapshot.rendererClockAdvanced ? "yes" : "no") "
                    + "video-submit=\(snapshot.videoSubmissionAttempts) "
                    + "frames-submitted=\(snapshot.framesSubmitted)" + displayedFields
            )
            return true
        }

        let pending = PendingBenchmarkControl(
            session: session,
            id: id,
            action: action,
            requestedUptime: ProcessInfo.processInfo.systemUptime
        )
        defersBenchmarkCompletionDiagnostics = true
        let accepted: Bool
        switch action {
        case .play:
            let previous = pendingBenchmarkTransport
            pendingBenchmarkTransport = pending
            accepted = runtimeDriver?.play() == true
            if accepted {
                supersedeBenchmarkControl(previous)
            } else if pendingBenchmarkTransport?.id == pending.id {
                pendingBenchmarkTransport = previous
            }
        case .pause:
            let previous = pendingBenchmarkTransport
            pendingBenchmarkTransport = pending
            accepted = runtimeDriver?.pause() == true
            if accepted {
                supersedeBenchmarkControl(previous)
            } else if pendingBenchmarkTransport?.id == pending.id {
                pendingBenchmarkTransport = previous
            }
        case let .seekExact(target):
            let previous = pendingBenchmarkSeek
            pendingBenchmarkSeek = pending
            accepted = runtimeDriver?.seek(to: target, mode: .exact) == true
            if accepted {
                supersedeBenchmarkControl(previous)
            } else if pendingBenchmarkSeek?.id == pending.id {
                pendingBenchmarkSeek = previous
            }
        case .snapshot, .rendererMetrics:
            accepted = false
        }
        defersBenchmarkCompletionDiagnostics = false
        writeBenchmarkControlDiagnostic(
            session: session,
            id: id,
            action: action,
            fields: "phase=request accepted=\(accepted ? "yes" : "no")"
        )
        flushDeferredBenchmarkCompletionDiagnostics()
        return accepted
    }

    @discardableResult
    public func setLoop(start: TimeInterval?, end: TimeInterval?) -> Bool {
        runtimeDriver?.setLoop(start: start, end: end) == true
    }

    private var frameStepTask: Task<Void, Never>?
    private var pendingFrameSteps: [Int] = []

    public func stepFrameForward() { stepFrame(direction: 1) }
    public func stepFrameBackward() { stepFrame(direction: -1) }

    private func stepFrame(direction: Int) {
        guard supports(.stepFrame, operation: "frame stepping"), let backend else { return }
        guard pendingFrameSteps.count < 32 else { return }
        pendingFrameSteps.append(direction)
        guard frameStepTask == nil else { return }
        _ = runtimeDriver?.pause()
        var revision = runtimeDriver?.commandRevision
        frameStepTask = Task { [weak self] in
            guard let self else { return }
            defer { frameStepTask = nil; pendingFrameSteps.removeAll() }
            do {
                while !pendingFrameSteps.isEmpty {
                    guard revision == runtimeDriver?.commandRevision else { return }
                    let direction = pendingFrameSteps.removeFirst()
                    let target = try await backend.frameStepTarget(direction: direction)
                    guard revision == runtimeDriver?.commandRevision else { return }
                    if let target {
                        seek(to: target)
                        revision = runtimeDriver?.commandRevision
                    }
                }
            } catch is CancellationError {
            } catch {
                state.setShellError(error.localizedDescription)
            }
        }
    }

    public func setVolume(_ volume: Double) {
        let sanitized = min(max(volume, 0), 100)
        state.setVolume(sanitized)
        persistence.setVolume(sanitized)
        backend?.setVolume(sanitized)
    }

    public func setMuted(_ isMuted: Bool) {
        state.setMuted(isMuted)
        persistence.setMuted(isMuted)
        backend?.setMuted(isMuted)
    }

    public func setPlaybackSpeed(_ speed: Double) {
        guard supports(.changePlaybackSpeed, operation: "playback speed") else { return }
        guard speed.isFinite else { return }
        let sanitized = (min(max(speed, 0.25), 4) * 1_000).rounded() / 1_000
        state.setPlaybackSpeed(sanitized)
        _ = runtimeDriver?.setPlaybackSpeed(sanitized)
        backend?.setPlaybackSpeed(sanitized)
        if state.currentSource == nil {
            persistence.setPlaybackSpeed(sanitized)
        } else {
            updateCurrentMediaSettings { settings in
                settings.overriddenFields.insert(.playbackSpeed)
                settings.playbackSpeed = sanitized
            }
        }
    }

    public func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {
        state.setHardwareDecodingPolicy(policy)
        persistence.setHardwareDecodingPolicy(policy)
        applyEffectiveHardwareDecodingPolicy()
    }

    public func selectAudioTrack(_ track: MediaTrack?) {
        guard supports(.selectAudioTrack, operation: "audio tracks") else { return }
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(.audio)
            settings.audioTrack = track.map(MediaTrackPreference.init)
            settings.audioLanguage = nil
        }
        pendingMediaSettingFields.insert(.audio)
        drainMediaRestore()
    }

    public func selectSubtitleTrack(_ track: MediaTrack?) {
        pendingExternalSubtitleRestore = nil
        pendingExternalPreferenceURL = nil
        guard supports(.selectSubtitleTrack, operation: "subtitle tracks") else { return }
        pendingExternalInstallURL = nil
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(.subtitles)
            settings.subtitleTrack = track.map(MediaTrackPreference.init)
            settings.subtitleLanguage = nil
            settings.externalSubtitleURL = track?.isExternal == true ? installedExternalSubtitleURL : nil
            settings.areSubtitlesVisible = track != nil
        }
        pendingMediaSettingFields.insert(.subtitles)
        drainMediaRestore()
    }

    public func selectAudioOutputDevice(_ device: AudioOutputDevice?) {
        guard supports(.selectAudioDevice, operation: "audio output selection") else { return }
        preferredAudioOutputDeviceID = device?.id == "auto" ? nil : device?.id
        persistence.setPreferredAudioOutputDeviceID(preferredAudioOutputDeviceID)
        backend?.selectAudioOutputDevice(device?.id)
    }

    public func selectChapter(_ chapter: Chapter) {
        guard supports(.selectChapter, operation: "chapters") else { return }
        seek(to: chapter.startTime)
    }

    public func setAudioDelay(_ delay: TimeInterval) {
        guard supports(.changeAudioDelay, operation: "audio delay") else { return }
        guard delay.isFinite else { return }
        let sanitized = min(max(delay, -10), 10)
        pendingRestoredAudioDelay = sanitized
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(.audioDelay)
            settings.audioDelay = sanitized
        }
        applyDeferredMediaAudioDelay()
    }

    public func setSubtitleDelay(_ delay: TimeInterval) {
        guard supports(.changeSubtitleDelay, operation: "subtitle delay") else { return }
        guard delay.isFinite else { return }
        let sanitized = min(max(delay, -10), 10)
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(.subtitleDelay)
            settings.subtitleDelay = sanitized
        }
        pendingMediaSettingFields.insert(.subtitleDelay)
        drainMediaRestore()
    }

    public func setVideoScaleMode(_ mode: VideoScaleMode) {
        guard supports(.changeVideoGeometry, operation: "video sizing") else { return }
        state.updateVideoAdjustments { $0.scaleMode = mode }
        backend?.setVideoScaleMode(mode)
    }

    public func resetVideoGeometry() {
        setVideoScaleMode(.fit)
        setVideoAspect(nil)
        setVideoCrop(nil)
    }

    public func setVideoAspect(_ aspect: String?) {
        guard !state.pictureInPicture.isActive else { return }
        guard aspect == nil || VideoPresentationGeometry.ratio(aspect) != nil else { return }
        guard supports(.changeVideoGeometry, operation: "video aspect override") else { return }
        state.updateVideoAdjustments { $0.aspectRatio = aspect }
        backend?.setVideoAspect(aspect)
    }

    public func setVideoCrop(_ crop: String?) {
        guard !state.pictureInPicture.isActive else { return }
        guard crop == nil || VideoPresentationGeometry.ratio(crop) != nil else { return }
        guard supports(.changeVideoGeometry, operation: "video crop") else { return }
        state.updateVideoAdjustments { $0.crop = crop }
        backend?.setVideoCrop(crop)
    }

    public func setVideoRotation(_ rotation: Int) {
        guard supports(.changeVideoAdjustments, operation: "video rotation") else { return }
        let normalized = ((rotation % 360) + 360) % 360
        state.updateVideoAdjustments { $0.rotation = normalized }
        backend?.setVideoRotation(normalized)
    }

    public func setDeinterlace(_ enabled: Bool) {
        guard supports(.changeVideoAdjustments, operation: "deinterlacing") else { return }
        state.updateVideoAdjustments { $0.isDeinterlacing = enabled }
        backend?.setDeinterlace(enabled)
    }

    public func setVideoEqualizer(_ adjustments: VideoAdjustmentState) {
        guard supports(.changeVideoAdjustments, operation: "video equalizer") else { return }
        state.updateVideoAdjustments {
            $0.brightness = min(max(adjustments.brightness, -100), 100)
            $0.contrast = min(max(adjustments.contrast, -100), 100)
            $0.saturation = min(max(adjustments.saturation, -100), 100)
            $0.gamma = min(max(adjustments.gamma, -100), 100)
            $0.hue = min(max(adjustments.hue, -100), 100)
        }
        let value = state.videoAdjustments
        backend?.setVideoEqualizer(value)
    }

    public func setVideoFilter(_ filter: VideoFilterPreset, enabled: Bool) {
        guard supports(.changeVideoFilters, operation: "video filters") else { return }
        let wasEnabled = state.activeVideoFilters.contains(filter)
        guard wasEnabled != enabled, let backend else { return }

        let token = UUID()
        filterMutationTokens[filter] = token
        state.setVideoFilter(filter, enabled: enabled)
        applyEffectiveHardwareDecodingPolicy()

        Task {
            do {
                let command: IlliquidCore.PlaybackCommand = enabled
                    ? .addVideoFilter(filter)
                    : .removeVideoFilter(filter)
                try await backend.execute(command)
                guard filterMutationTokens[filter] == token else { return }
                filterMutationTokens[filter] = nil
                recordDiagnostic(
                    "[video] \(enabled ? "Enabled" : "Disabled") \(filter.displayName) filter.",
                    code: "video.filterMutationSucceeded"
                )
            } catch {
                guard filterMutationTokens[filter] == token else {
                    recordDiagnostic(
                        "[video] Superseded \(filter.displayName) filter command failed: \(error.localizedDescription)",
                        code: "video.supersededFilterMutationFailed"
                    )
                    return
                }
                filterMutationTokens[filter] = nil
                state.setVideoFilter(filter, enabled: wasEnabled)
                applyEffectiveHardwareDecodingPolicy()
                state.setShellError("Could not update \(filter.displayName): \(error.localizedDescription)")
            }
        }
    }

    public func resetVideoAdjustments() {
        guard supports(.changeVideoAdjustments, operation: "video adjustments") else { return }
        for filter in state.activeVideoFilters {
            setVideoFilter(filter, enabled: false)
        }
        state.updateVideoAdjustments { $0 = .standard }
        backend?.setVideoAspect(nil)
        backend?.setVideoCrop(nil)
        backend?.setVideoRotation(0)
        backend?.setDeinterlace(false)
        backend?.setVideoEqualizer(.standard)
    }

    public func loadExternalSubtitle(_ url: URL) {
        guard MediaFileSupport.isSupportedSubtitleFile(url) else {
            state.setShellError("Choose an SRT, ASS, SSA, WebVTT, or VobSub IDX subtitle file.")
            return
        }
        guard supports(.loadExternalSubtitle, operation: "external subtitles") else { return }
        guard url.isFileURL else { return }
        pendingExternalPreferenceURL = url
        pendingExternalInstallURL = url
        pendingMediaSettingFields.remove(.subtitles)
        pendingExternalSubtitleRestore = nil
        drainMediaRestore()
    }

    public func captureScreenshot(to url: URL, includeSubtitles: Bool = true) async throws {
        guard url.isFileURL else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        guard let backend else {
            throw UnsupportedPlaybackCapabilityError("screenshots")
        }
        guard capabilityModel.supports(.saveScreenshot) else {
            throw UnsupportedPlaybackCapabilityError("screenshots")
        }
        let resume = !state.isPauseDesired
        if resume { _ = runtimeDriver?.pause() }
        let revision = runtimeDriver?.commandRevision
        defer {
            if resume, revision == runtimeDriver?.commandRevision { _ = runtimeDriver?.play() }
        }
        try await backend.execute(.screenshot(url, includeSubtitles: includeSubtitles))
    }

    public func playNext() {
        cancelFolderScans()
        if failedSourceTransaction?.traversalStep == 1 {
            skipFailedSource()
            return
        }
        guard let currentIndex = state.currentPlaylistIndex,
              state.playlist.indices.contains(currentIndex + 1)
        else { return }
        playItem(at: currentIndex + 1, origin: state.currentSourceOrigin ?? .userSelected, traversalStep: 1)
    }

    public func playPrevious() {
        cancelFolderScans()
        if failedSourceTransaction?.traversalStep == -1 {
            skipFailedSource()
            return
        }
        guard let currentIndex = state.currentPlaylistIndex,
              state.playlist.indices.contains(currentIndex - 1)
        else { return }
        playItem(at: currentIndex - 1, origin: state.currentSourceOrigin ?? .userSelected, traversalStep: -1)
    }

    public func playItem(at index: Int) {
        guard state.playlist.indices.contains(index) else { return }
        cancelFolderScans()
        playItem(at: index, origin: .userSelected)
    }

    public func sortPlaylist(by order: PlaylistSortOrder, ascending: Bool) {
        activeAutomationID = nil
        guard !state.playlist.isEmpty else { return }
        finishShuffleForExplicitOrder()
        let items = PlaylistMutation.sorted(
            state.playlist,
            by: order,
            ascending: ascending
        )
        let selectedIndex = PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: state.currentURL,
            fallbackIndex: state.currentPlaylistIndex,
            in: items
        )
        discardFailedTraversalForPlaylistChange()
        state.configurePlaylist(
            folder: state.currentFolder,
            items: items,
            selectedIndex: selectedIndex
        )
        checkpointSession()
    }

    public func restartItem(at index: Int) {
        guard state.playlist.indices.contains(index) else { return }
        if index == state.currentPlaylistIndex {
            seek(to: 0)
            play()
        } else {
            playItem(at: index)
        }
    }

    public func removePlaylistItem(id: FolderPlaylistItem.ID) {
        activeAutomationID = nil
        guard let index = state.playlist.firstIndex(where: { $0.id == id }) else {
            return
        }
        var items = state.playlist
        let removedCurrent = index == state.currentPlaylistIndex
        items.remove(at: index)
        let replacementIndex: Int? = if items.isEmpty {
            nil
        } else if removedCurrent {
            min(index, items.count - 1)
        } else {
            PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: state.currentURL,
                fallbackIndex: state.currentPlaylistIndex,
                in: items
            )
        }
        discardFailedTraversalForPlaylistChange()
        state.configurePlaylist(
            folder: state.currentFolder,
            items: items,
            selectedIndex: replacementIndex
        )
        if removedCurrent, let replacementIndex {
            playItem(at: replacementIndex)
        } else {
            checkpointSession()
        }
    }

    public func removeCompletedPlaylistItems() {
        activeAutomationID = nil
        let currentURL = state.currentURL
        let items = state.playlist.filter { item in
            if let currentURL,
               NormalizedFileURL.representsSameFile(item.url, currentURL)
            {
                return true
            }
            return persistence.playbackProgress(for: item.url)?.isCompleted != true
        }
        guard items != state.playlist else { return }
        discardFailedTraversalForPlaylistChange()
        state.configurePlaylist(
            folder: state.currentFolder,
            items: items,
            selectedIndex: PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: currentURL,
                fallbackIndex: state.currentPlaylistIndex,
                in: items
            )
        )
        checkpointSession()
    }

    public func clearPlaylist() {
        activeAutomationID = nil
        discardFailedTraversalForPlaylistChange()
        state.configurePlaylist(folder: nil, items: [], selectedIndex: nil)
        checkpointSession()
    }

    public func movePlaylistItem(id: FolderPlaylistItem.ID, before targetID: FolderPlaylistItem.ID) {
        activeAutomationID = nil
        guard id != targetID,
              let sourceIndex = state.playlist.firstIndex(where: { $0.id == id }),
              let originalTargetIndex = state.playlist.firstIndex(where: { $0.id == targetID })
        else { return }
        var items = state.playlist
        let item = items.remove(at: sourceIndex)
        finishShuffleForExplicitOrder()
        let targetIndex = sourceIndex < originalTargetIndex
            ? originalTargetIndex - 1
            : originalTargetIndex
        items.insert(item, at: targetIndex)
        discardFailedTraversalForPlaylistChange()
        state.configurePlaylist(
            folder: state.currentFolder,
            items: items,
            selectedIndex: PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: state.currentURL,
                fallbackIndex: state.currentPlaylistIndex,
                in: items
            )
        )
        checkpointSession()
    }

    public func playbackProgress(for fileURL: URL) -> MediaPlaybackProgress? {
        let persisted = persistence.playbackProgress(for: fileURL)
        guard let currentURL = state.currentURL,
              NormalizedFileURL.representsSameFile(currentURL, fileURL)
        else {
            return persisted
        }

        let applicableHistory = canPersistCurrentMediaHistory ? persisted : nil
        let duration = state.duration > 0 ? state.duration : (applicableHistory?.duration ?? 0)
        let fraction = duration > 0 ? state.position / duration : 0
        return MediaPlaybackProgress(
            position: state.position,
            duration: duration,
            isCompleted: applicableHistory?.isCompleted == true || fraction > 0.9
        )
    }

    private func playItem(
        at index: Int,
        origin: MediaSourceOrigin,
        reloadCurrent: Bool = false,
        traversalStep: Int? = nil
    ) {
        guard state.playlist.indices.contains(index), backend != nil else { return }
        supersedePendingRestore(ifNeededFor: origin)

        let item = state.playlist[index]

        // Clicking the episode that is already loaded should behave like Play,
        // not restart it from its saved position. An ended file has no active
        // entry and intentionally falls through so it can be loaded again.
        if !reloadCurrent,
           pendingSourceTransaction == nil,
           eventGate.activeIdentity != nil,
           let currentURL = state.currentURL,
           NormalizedFileURL.representsSameFile(currentURL, item.url)
        {
            play()
            return
        }

        beginSourceTransaction(
            item: item,
            playlist: state.playlist,
            folder: state.currentFolder,
            playlistIndex: index,
            origin: origin,
            restoreTarget: state.currentFolder.map(PlaybackRestoreTarget.folder)
                ?? .file(item.url),
            traversalStep: traversalStep
        )
    }

    @discardableResult
    private func beginSourceTransaction(
        item: FolderPlaylistItem,
        playlist: [FolderPlaylistItem],
        folder: URL?,
        playlistIndex: Int,
        origin: MediaSourceOrigin,
        restoreTarget: PlaybackRestoreTarget?,
        traversalStep: Int? = nil,
        recoverySession: PlaybackSessionRecord? = nil,
        automationID: UUID? = nil
    ) -> Bool {
        guard backend != nil, playlist.indices.contains(playlistIndex) else { return false }
        activeAutomationID = automationID
        invalidateTimelineThumbnails()
        dismissRecovery()
        saveCurrentProgress()
        automationCheckpointOwner = automationID
        guard let source = MediaSource(url: item.url) else {
            state.setShellError("This media source is not supported.")
            return false
        }
        guard let request = MediaLoadRequest(source: source, origin: origin) else {
            state.setShellError("Remote streams must be opened by an explicit user action.")
            return false
        }

        playbackGeneration &+= 1
        let identity = PlayerSessionIdentity(source: source, generation: playbackGeneration)
        pendingSourceTransaction = PendingSourceTransaction(
            previousSessionID: runtimeDriver?.currentSnapshot.sessionID,
            request: request,
            identity: identity,
            folder: folder,
            playlist: playlist,
            playlistIndex: playlistIndex,
            externalSubtitleURLs: item.externalSubtitleURLs,
            mediaSettings: remembersPlaybackHistory ? persistence.mediaSettings(for: item.url) : nil,
            restoreTarget: restoreTarget,
            traversalStep: traversalStep,
            recoverySession: recoverySession ?? pendingLocatedSession
        )
        pendingLocatedSession = nil
        let accepted = runtimeDriver?.load(
            PlaybackRuntimeLoadRequest(media: request, identity: identity),
            autoplay: !(pendingPlaybackRestore.map {
                $0.source.representsSameResource(as: source) && $0.wasPaused
            } ?? (origin == .restoredSession && restoresSessionPaused))
        ) == true
        if !accepted {
            pendingSourceTransaction = nil
            state.setShellError("Playback core rejected the load command.")
            surfaceHost?.setPlaybackPhase(state.phase)
        }
        return accepted
    }

    public func setFullscreen(_ isFullscreen: Bool) {
        state.setFullscreen(isFullscreen)
    }

    public func setPictureInPictureActive(_ active: Bool) {
        guard supports(.pictureInPicture, operation: "Picture in Picture") else { return }
        guard !active || state.currentSource != nil else { return }
        backend?.setPictureInPictureActive(active)
    }

    public func setPictureInPictureRestoreRequestHandler(
        _ handler: PictureInPictureRestoreRequestHandler?
    ) {
        backend?.setPictureInPictureRestoreRequestHandler(handler)
    }

    public func setPlaybackCompletionHandler(_ handler: ((URL) -> Void)?) {
        playbackCompletionHandler = handler
    }

    public func isVideoSurfaceAttached(to window: NSWindow) -> Bool {
        surfaceHost?.view.window === window
    }

    public func setSidebarVisible(_ isVisible: Bool) {
        state.setSidebarVisible(isVisible)
        persistence.setSidebarVisible(isVisible)
    }

    public func setRepeatMode(_ mode: PlaybackRepeatMode) {
        state.setRepeatMode(mode)
        persistence.setRepeatMode(mode)
    }

    public func setShuffleEnabled(_ isEnabled: Bool) {
        activeAutomationID = nil
        guard state.isShuffleEnabled != isEnabled else { return }
        if isEnabled { unshuffledPlaylistIDs = state.playlist.map(\.id) }
        state.setShuffleEnabled(isEnabled)
        persistence.setShuffleEnabled(isEnabled)
        let items = isEnabled
            ? state.playlist.shuffled()
            : PlaylistMutation.restoringOrder(state.playlist, ids: unshuffledPlaylistIDs ?? [])
        if !isEnabled { unshuffledPlaylistIDs = nil }
        let selectedIndex = PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: state.currentURL,
            fallbackIndex: state.currentPlaylistIndex,
            in: items
        )
        discardFailedTraversalForPlaylistChange()
        state.configurePlaylist(
            folder: state.currentFolder,
            items: items,
            selectedIndex: selectedIndex
        )
        checkpointSession()
    }

    private func finishShuffleForExplicitOrder() {
        guard state.isShuffleEnabled else { return }
        state.setShuffleEnabled(false)
        persistence.setShuffleEnabled(false)
        unshuffledPlaylistIDs = nil
    }

    public func clearPlaybackHistory() {
        persistence.clearPlaybackHistory()
        clearSavedPlaybackSession()
    }

    public func clearPlaybackProgress() {
        progressClearedAtPosition = state.position
        persistence.clearPlaybackProgress()
        clearSavedPlaybackSession()
    }

    public func clearRememberedMediaSettings() {
        persistence.clearRememberedMediaSettings()
    }

    private func clearSavedPlaybackSession() {
        sessionRestoreWasCleared = true
        checkpointRevision &+= 1
        checkpointWriter.submit(.clear)
        scheduleCheckpointFlush()
    }

    /// Reopens the previous local file or rebuilds the previous folder
    /// playlist without querying filesystem metadata on the UI actor.
    /// Returns whether preparation was scheduled. Availability and restore
    /// success are reported asynchronously through state and recovery UI.
    @discardableResult
    public func restoreLastSession() -> Bool {
        guard remembersPlaybackHistory, !persistence.hasUnreadableHistory, !isShuttingDown, !sessionRestoreWasCleared,
              state.currentSource == nil, !state.isLoading else { return false }
        cancelFolderScans()
        let generation = UUID()
        folderScanGeneration = generation
        let store = sessionStore
        let legacy = persistence.lastOpenedMedia()
        pendingLocatedHistorySource = nil
        let preparation = sourcePreparation
        let worker = Task {
            await preparation.result { check in
                try check()
                let session = try store.load()
                let target: PlaybackRestoreTarget?
                if let session {
                    if let folder = session.collectionFolder { target = .folder(folder) }
                    else if session.source.url.isFileURL { target = .file(session.source.url) }
                    else { target = nil }
                } else { target = legacy }
                try check()
                var directory = ObjCBool(false)
                let exists = target.map {
                    FileManager.default.fileExists(atPath: $0.url.path, isDirectory: &directory)
                } ?? false
                try check()
                return PreparedRestore(session: session, target: target,
                                       exists: exists, isDirectory: directory.boolValue)
            }
        }
        let task = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler { await worker.value }
                onCancel: { worker.cancel() }
            guard let self else { return }
            defer { folderScanTasks[generation] = nil }
            guard !Task.isCancelled, generation == folderScanGeneration,
                  !sessionRestoreWasCleared, state.currentSource == nil else { return }
            do { _ = applyPreparedRestore(try result.get()) }
            catch { state.setShellError(error.localizedDescription) }
        }
        folderScanTasks[generation] = task
        return true
    }

    private struct PreparedRestore: Sendable {
        let session: PlaybackSessionRecord?
        let target: PlaybackRestoreTarget?
        let exists: Bool
        let isDirectory: Bool
    }

    private func applyPreparedRestore(_ prepared: PreparedRestore) -> Bool {
        preparedRestoreSession = prepared.session
        if let session = prepared.session {
            unshuffledPlaylistIDs = session.unshuffledPlaylistIDs
            pendingPlaybackRestore = PendingPlaybackRestore(
                source: session.source,
                position: normalizedRestorePosition(
                    session.position,
                    for: session.source
                ),
                wasPaused: restoresSessionPaused || session.wasPaused,
                playlistIndex: session.playlistIndex
            )

            if let folder = session.collectionFolder {
                guard prepared.exists, prepared.isDirectory
                else {
                    // An offline volume is not a request to forget the session.
                    pendingPlaybackRestore = nil
                    reportUnavailableRestore(folder, isFolder: true)
                    return false
                }
                openFolder(url: folder, origin: .restoredSession)
                return true
            }

            switch session.source {
            case let .localFile(url):
                guard prepared.exists, !prepared.isDirectory,
                      MediaFileSupport.isSupportedMediaFile(url)
                else {
                    pendingPlaybackRestore = nil
                    reportUnavailableRestore(url, isFolder: false)
                    return false
                }
                let validItems = session.playlistItems.filter {
                    MediaFileSupport.isSupportedMediaFile($0.url)
                }
                if !validItems.isEmpty,
                   let index = PlaylistMutation.indexPreservingCurrentIdentity(
                       currentURL: url,
                       fallbackIndex: session.playlistIndex,
                       in: validItems
                   )
                {
                    beginSourceTransaction(
                        item: validItems[index],
                        playlist: validItems,
                        folder: nil,
                        playlistIndex: index,
                        origin: .restoredSession,
                        restoreTarget: .file(url)
                    )
                } else {
                    open(url: url, origin: .restoredSession)
                }
                return true
            case .remoteStream:
                // Never reconnect to a remote origin silently after launch.
                pendingPlaybackRestore = nil
                return false
            }
        }

        guard let target = prepared.target else { return false }

        guard prepared.exists else {
            if case .folder = target {
                reportUnavailableRestore(target.url, isFolder: true)
            } else {
                reportUnavailableRestore(target.url, isFolder: false)
            }
            return false
        }

        switch target {
        case let .file(url):
            guard !prepared.isDirectory, MediaFileSupport.isSupportedMediaFile(url) else {
                persistence.setLastOpenedMedia(nil)
                return false
            }
            open(url: url, origin: .restoredSession)
        case let .folder(url):
            guard prepared.isDirectory else {
                persistence.setLastOpenedMedia(nil)
                return false
            }
            openFolder(url: url, origin: .restoredSession)
        }
        return true
    }

    public var capabilities: PlaybackCapabilities { backend?.capabilities ?? [] }
    public var capabilityModel: PlayerCapabilityModel {
        PlayerCapabilityModel(capabilities: capabilities)
    }

    public func supports(_ operation: PlayerOperation) -> Bool {
        capabilityModel.supports(operation)
    }
    public var videoViewportSize: CGSize { surfaceHost?.videoViewportSize ?? .zero }

    public func makeVideoSurfaceHost() throws -> any PlaybackSurfaceHost {
        if let surfaceHost { return surfaceHost }
        guard let backend else {
            throw UnsupportedPlaybackCapabilityError("video presentation")
        }
        let host = try backend.makeSurfaceHost()
        host.setPlaybackPhase(state.phase)
        surfaceHost = host
        return host
    }

    public func updateVideoSurfaceCallbacks(
        onOpenURLs: (([URL], PlaylistOpenMode) -> Void)?,
        onUserActivity: (() -> Void)?,
        onInteraction: ((PlaybackSurfaceInteraction) -> Void)?,
        contextMenuProvider: (() -> NSMenu?)?
    ) {
        surfaceHost?.onOpenURLs = onOpenURLs
        surfaceHost?.onUserActivity = onUserActivity
        surfaceHost?.onInteraction = onInteraction
        surfaceHost?.contextMenuProvider = contextMenuProvider
    }

    public func updateDisplay(screen: NSScreen?) {
        surfaceHost?.updateDisplay(screen: screen)
    }

    public func refreshDisplayPolicy() {
        surfaceHost?.updateDisplay(screen: surfaceHost?.view.window?.screen)
    }

    public func systemWillSleep() {
        activeAutomationID = nil
        saveCurrentProgress()
        _ = runtimeDriver?.systemWillSleep()
    }

    public func systemDidWake() {
        _ = runtimeDriver?.systemDidWake()
        refreshDisplayPolicy()
    }

    public func shutdown() async {
        let timing = LifecyclePerformance.begin("controller-shutdown")
        defer { LifecyclePerformance.end("controller-shutdown", since: timing) }
        guard !isShuttingDown else { return }
        isShuttingDown = true
        activeAutomationID = nil
        // A final checkpoint must not wait for the interactive save debounce.
        // If a flush already started, join it before the final authoritative flush.
        let terminatingCheckpointFlush = checkpointFlushTask
        terminatingCheckpointFlush?.cancel()
        invalidateTimelineThumbnails()
        folderScanGeneration = UUID()
        queuedSourceOpens.removeAll()
        sourceOpenGeneration = nil
        let terminatingFolderScans = Array(folderScanTasks.values)
        folderScanTasks.removeAll()
        for task in terminatingFolderScans {
            task.cancel()
        }
        for task in terminatingFolderScans {
            await task.value
        }
        pendingSourceTransaction = nil
        eventGate.activate(nil)
        saveCurrentProgress()
        surfaceHost?.shutdown()
        surfaceHost = nil
        let terminatingBackend = backend
        let terminatingDriver = runtimeDriver
        backend = nil
        runtimeDriver = nil
        if let terminatingDriver {
            await terminatingDriver.shutdown()
        } else {
            await terminatingBackend?.shutdown()
        }
        let checkpointTiming = LifecyclePerformance.begin("shutdown-checkpoint-wait")
        await terminatingCheckpointFlush?.value
        checkpointFlushTask = nil
        LifecyclePerformance.end("shutdown-checkpoint-wait", since: checkpointTiming)
        if !(await flushPlaybackPersistence()) {
            shutdownPersistenceError = state.shellError ?? "Could not save playback progress."
        }
    }

    @discardableResult
    private func saveCurrentProgress() -> Bool {
        guard remembersPlaybackHistory, !persistence.hasUnreadableHistory else { return true }
        guard let source = state.currentSource else { return false }
        guard hasCurrentPlaybackAuthority else { return true }
        guard progressClearedAtPosition == nil else { return true }
        guard canPersistCurrentMediaHistory else { return true }
        guard canCheckpointCurrentPosition else {
            checkpointWhenSettled = true
            historyCheckpointWhenSettled = true
            return true
        }
        historyCheckpointWhenSettled = false
        if case let .localFile(currentURL) = source {
            if state.duration > 0 {
                persistence.setPlaybackProgress(
                    position: state.position,
                    duration: state.duration,
                    for: currentURL
                )
            } else {
                persistence.setPlaybackPosition(state.position, for: currentURL)
            }
            if let folder = state.currentFolder,
               let index = state.currentPlaylistIndex,
               state.playlist.indices.contains(index),
               state.playlist[index].url == currentURL
            {
                persistence.setLastWatchedFile(currentURL, for: folder)
            }
        }
        return checkpointSession()
    }

    @discardableResult
    private func checkpointSession() -> Bool {
        guard remembersPlaybackHistory, !persistence.hasUnreadableHistory else { return true }
        guard let source = state.currentSource else { return false }
        guard hasCurrentPlaybackAuthority else { return true }
        guard progressClearedAtPosition == nil else { return true }
        guard canPersistCurrentMediaHistory else { return true }
        guard canCheckpointCurrentPosition else { checkpointWhenSettled = true; return true }
        if state.isShuffleEnabled {
            unshuffledPlaylistIDs = PlaylistMutation.restoringOrder(
                state.playlist, ids: unshuffledPlaylistIDs ?? []
            ).map(\.id)
        }
        checkpointWhenSettled = false
        checkpointWriter.submit(.save(PlaybackCheckpoint(
            source: source, folder: state.currentFolder, playlist: state.playlist,
            index: state.currentPlaylistIndex, position: state.position,
            wasPaused: state.isPauseDesired,
            unshuffledPlaylistIDs: state.isShuffleEnabled ? unshuffledPlaylistIDs : nil
        )))
        sessionRestoreWasCleared = false
        lastCheckpointedPosition = state.position
        checkpointRevision &+= 1
        scheduleCheckpointFlush()
        return true
    }

    private var hasCurrentPlaybackAuthority: Bool {
        guard let source = state.currentSource,
              let snapshot = runtimeDriver?.currentSnapshot else { return false }
        // The playlist and last source survive Stop, while the idle projection
        // resets position to zero. Never save that placeholder over the final
        // checkpoint captured before stopping the actual session.
        return snapshot.sessionID != nil && snapshot.source == Self.coreSourceIdentity(source)
    }

    private func scheduleCheckpointFlush() {
        guard !isShuttingDown else { return }
        if checkpointFlushTask == nil {
            checkpointFlushTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self, !isShuttingDown else { return }
                _ = await flushPlaybackPersistence()
                checkpointFlushTask = nil
            }
        }
    }

    private func flushPlaybackPersistence() async -> Bool {
        let timing = LifecyclePerformance.begin("persistence-flush")
        defer { LifecyclePerformance.end("persistence-flush", since: timing) }
        let revision = checkpointRevision
        let historyResult = await persistence.flush()
        let sessionResult = await checkpointWriter.flush()
        for result in [historyResult, sessionResult] {
            if case let .failure(error) = result {
                if revision == checkpointRevision {
                    state.setShellError("Could not save playback progress: \(error.localizedDescription)")
                    lastCheckpointedPosition = -.infinity
                }
                return false
            }
        }
        return true
    }

    private func handle(_ event: PlaybackRuntimeEvent) {
        let acceptedByProduction = eventGate.accepts(event)
        guard acceptedByProduction else {
            recordDiagnostic(
                "[backend] Discarded stale event from generation \(event.identity?.generation ?? 0).",
                code: "backend.staleEventDiscarded"
            )
            return
        }

        switch event.payload {
        case .effectResult:
            break
        case .started, .prerollReady:
            break
        case .seekCompleted:
            completeBenchmarkSeek()
        case let .mediaVersionObserved(version):
            applyMediaVersion(version)
        case .loaded:
            invalidateTimelineThumbnails()
            videoColorStore.reset()
            // Apply speed before the explicit transport/seek restore so a
            // preference change cannot overwrite that newer command intent.
            applyCurrentMediaSpeed()
            restorePositionAndExternalSubtitles()
            hasLoadedCurrentSource = true
            pendingRestoredAudioDelay = currentMediaSettings.effectiveAudioDelay
            drainMediaRestore()
            checkpointSession()
            if let snapshot = runtimeDriver?.currentSnapshot { observeSettledProductState(snapshot) }
        case .firstFrameSubmitted:
            recordDiagnostic(
                "[native] First frame submitted to the renderer.",
                code: "backend.firstFrameSubmitted"
            )
        case let .positionChanged(value):
            if let clearedPosition = progressClearedAtPosition,
               value.isFinite, abs(value - clearedPosition) > 0.001 {
                progressClearedAtPosition = nil
            }
            if abs(state.position - lastCheckpointedPosition) >= 10 {
                saveCurrentProgress()
            }
        case let .durationChanged(value):
            _ = value
        case let .pauseChanged(value):
            guard state.currentSource != nil else { return }
            completeBenchmarkTransport(isPaused: value)
            checkpointSession()
        case let .bufferingChanged(status):
            state.updateBufferTelemetry(
                cacheDuration: status.cacheDuration,
                cachePercent: status.cachePercent
            )
        case .synchronization:
            break
        case let .tracksChanged(snapshot):
            hasReceivedCurrentCatalog = true
            state.updateTrackCatalog(snapshot.tracks)
            if let currentSnapshot = runtimeDriver?.currentSnapshot {
                applyCoreSnapshot(currentSnapshot)
            }
            drainMediaRestore()
            observeAcknowledgedExternalSubtitle()
            applyDeferredMediaAudioDelay()
        case let .decoderChanged(status):
            state.updateActiveDecoder(
                status.name,
                isHardwareDecoded: status.isHardwareDecoded,
                didFallbackToSoftware: status.didFallbackToSoftware
            )
        case let .videoChanged(status, aspectRatio):
            state.updateVideoOutput { $0 = status }
            if let aspectRatio { state.updateVideoAspectRatio(aspectRatio) }
            refreshDisplayPolicy()
        case let .videoColorSampleChanged(sample):
            videoColorStore.publish(sample)
        case let .displayChanged(status):
            state.updateDisplayOutput(status)
        case let .volumeChanged(value):
            state.setVolume(value)
        case let .muteChanged(value):
            state.setMuted(value)
        case let .speedChanged(value):
            state.setPlaybackSpeed(value)
        case let .audioOutputSelectionFailed(message):
            state.setShellError(message)
        case let .audioDevicesChanged(devices):
            let previousSelection = state.audioOutputDevice
            state.updateAudioOutputDevices(devices)
            if let preferredAudioOutputDeviceID,
               let preferredDevice = devices.first(where: {
                   $0.id == preferredAudioOutputDeviceID
               }),
               !preferredDevice.isSelected
            {
                backend?.selectAudioOutputDevice(preferredDevice.id)
                break
            }
            if let previousSelection,
               previousSelection.id != "auto",
               !devices.contains(where: { $0.id == previousSelection.id })
            {
                recordDiagnostic(
                    "[audio] Output \(previousSelection.name) disappeared; using System Default.",
                    code: "audio.outputDeviceDisappeared"
                )
                backend?.selectAudioOutputDevice(nil)
            }
        case let .chaptersChanged(chapters, currentID):
            state.updateChapters(chapters, currentID: currentID)
        case let .audioDelayChanged(value):
            state.setAudioDelay(value)
            scheduleMediaRestoreDrain()
        case .subtitleDelayChanged:
            break
        case let .videoAdjustmentsChanged(adjustments):
            state.updateVideoAdjustments { $0 = adjustments }
        case let .pictureInPictureChanged(pictureInPicture):
            state.updatePictureInPicture(pictureInPicture)
        case .transportRequested, .relativeSeekRequested, .audioOutputChanged:
            break
        case .endOfFile:
            break
        case .stopped:
            cancelPendingBenchmarkControls(reason: "stopped")
            eventGate.activate(nil)
            state.updateVideoAspectRatio(nil)
            videoColorStore.reset()
        case .typedFailure:
            break
        case let .failed(message):
            cancelPendingBenchmarkControls(reason: "failed")
            eventGate.activate(nil)
            videoColorStore.reset()
            recordDiagnostic(message, code: "backend.legacyFailure")
        case let .diagnostic(message):
            recordDiagnostic(message, code: "backend.diagnostic")
        case .shutdownCompleted:
            cancelPendingBenchmarkControls(reason: "shutdown")
            videoColorStore.reset()
            recordDiagnostic(
                "[backend] Shutdown completed.",
                code: "backend.shutdownCompleted"
            )
        }
    }

    private func applyCoreTransition(_ transition: PlaybackTransition) {
        let committedSource = settlePendingSourceTransaction(using: transition.snapshot)
        applyCoreSnapshot(transition.snapshot)
        if committedSource { checkpointSession() }
        observeSettledProductState(transition.snapshot)
    }

    private func settlePendingSourceTransaction(
        using snapshot: PlaybackUISnapshot
    ) -> Bool {
        guard let pending = pendingSourceTransaction else { return false }
        let requestedSource = Self.coreSourceIdentity(pending.request.source)
        // The old session can have the same URL after a replacement fails.
        // Commit only when the core has installed a new session.
        if snapshot.source == requestedSource, snapshot.pendingSource == nil,
           snapshot.sessionID != pending.previousSessionID {
            invalidateTimelineThumbnails()
            pendingSourceTransaction = nil
            retainsCompletedFrame = false
            dismissRecovery()
            discardFailedTraversalForPlaylistChange()
            state.configurePlaylist(
                folder: pending.folder,
                items: pending.playlist,
                selectedIndex: pending.playlistIndex
            )
            state.prepareLoadMetadata(
                request: pending.request,
                playlistIndex: pending.playlistIndex
            )
            pendingExternalSubtitles = pending.externalSubtitleURLs
            currentMediaSettings = pending.mediaSettings?.sanitized() ?? MediaPlaybackSettings()
            pendingMediaSettingFields = currentMediaSettings.overriddenFields.intersection([.audio, .subtitles, .subtitleDelay])
            hasReceivedCurrentCatalog = false
            pendingPositionRestore = nil
            pendingExternalInstallURL = nil
            restoreDrainTask?.cancel()
            restoreDrainTask = nil
            pendingExternalSubtitleRestore = nil
            pendingExternalPreferenceURL = nil
            installedExternalSubtitleURL = nil
            pendingRestoredAudioDelay = nil
            hasLoadedCurrentSource = false
            checkpointWhenSettled = false
            historyCheckpointWhenSettled = false
            lastSettledSession = nil
            interruptedRecoverySession = nil
            currentContentVersion = nil
            ignoresSavedPositionForCurrentSource = false
            canPersistCurrentMediaHistory = true
            progressClearedAtPosition = nil
            lastCheckpointedPosition = 0
            eventGate.activate(pending.identity)
            if !pending.request.source.isRemote {
                if let folder = pending.folder {
                    persistence.setLastWatchedFile(
                        pending.request.source.url,
                        for: folder
                    )
                }
                persistence.setLastOpenedMedia(
                    pending.restoreTarget ?? .file(pending.request.source.url)
                )
            }
            return true
        } else if snapshot.pendingSource == nil {
            pendingSourceTransaction = nil
            failedSourceTransaction = pending
            let canSkip = pending.traversalStep.map {
                pending.playlist.indices.contains(pending.playlistIndex + $0)
            } ?? false
            state.setRecoveryIssue(PlaybackRecoveryIssue(
                kind: .failedSource(canSkip: canSkip),
                message: "Could not open \(pending.request.source.url.lastPathComponent). "
                    + (pending.request.source.isRemote
                        ? "Check the address and connection, then retry."
                        : "Check that the file and its drive are accessible, retry, or locate the file."),
                source: pending.request.source.url, diagnosticCode: snapshot.failureCode
            ))
        }
        return false
    }

    private static func coreSourceIdentity(
        _ source: MediaSource
    ) -> MediaSourceIdentity {
        switch source {
        case let .localFile(url):
            .init(rawValue: "local:\(url.absoluteURL.standardized.path)")
        case let .remoteStream(url):
            .init(rawValue: "remote:\(url.absoluteString)")
        }
    }

    private func applyCoreSnapshot(_ snapshot: PlaybackUISnapshot) {
        let phase: PlaybackPhase
        switch snapshot.lifecycle {
        case .shuttingDown, .terminated:
            phase = .shuttingDown
        case .invariantFailed:
            phase = .failed
        case .running:
            phase = switch snapshot.phase {
            case .idle, .ended, .stopped: .idle
            case .opening, .probing, .configuring: .loading
            case .prerolling, .ready, .seeking: .preparing
            case .buffering: .buffering
            case .playing: .playing
            case .paused: .paused
            case .draining, .stopping: .stopping
            case .failed: .failed
            }
        }
        timelineThumbnailGenerator.setDecodingSuspended(
            phase.isLoading || phase == .stopping || phase == .shuttingDown
        )
        state.applyAuthorityProjection(PlaybackAuthorityProjection(
            phase: phase,
            position: seconds(snapshot.position) ?? 0,
            duration: seconds(snapshot.duration) ?? 0,
            isBuffering: snapshot.isBuffering,
            selectedAudioID: snapshot.selectedAudioTrackID?.mediaTrackID,
            selectedSubtitleID: snapshot.selectedSubtitleTrackID?.mediaTrackID,
            subtitleDelay: Double(snapshot.subtitleDelayMicroseconds) / 1_000_000,
            failureCode: snapshot.failureCode,
            isPauseDesired: snapshot.desiredTransport != .playing
        ))
        surfaceHost?.setPlaybackPhase(phase)
    }

    private func seconds(_ timestamp: MediaTimestamp) -> TimeInterval? {
        guard case let .valid(time) = timestamp, time.timescale > 0 else { return nil }
        return Double(time.value) / Double(time.timescale)
    }

    private func applyMediaVersion(_ version: MediaContentVersion?) {
        guard let url = state.currentURL, url.isFileURL else { return }
        let locatedSource = pendingLocatedHistorySource
        pendingLocatedHistorySource = nil
        currentContentVersion = version
        canPersistCurrentMediaHistory = version != nil
        var changed = false
        if let version {
            if let locatedSource,
               persistence.copyHistoryForLocatedMedia(from: locatedSource, to: url, version: version) {
                currentMediaSettings = persistence.mediaSettings(for: url) ?? MediaPlaybackSettings()
                pendingMediaSettingFields = currentMediaSettings.overriddenFields.intersection([.audio, .subtitles, .subtitleDelay])
            } else if let locatedSource, let previousVersion = persistence.mediaVersion(for: locatedSource) {
                changed = previousVersion != version
            }
            changed = persistence.acceptMediaVersion(version, for: url) == .changed || changed
        }
        guard changed || version == nil else { return }
        // Preserve the requested paused state, but discard inapplicable seek
        // positions and per-file track/delay choices before loaded/catalog.
        ignoresSavedPositionForCurrentSource = true
        pendingMediaSettingFields.removeAll()
        currentMediaSettings = MediaPlaybackSettings()
        if let restore = pendingPlaybackRestore {
            pendingPlaybackRestore = PendingPlaybackRestore(source: restore.source,
                position: restore.positionIsExplicit ? restore.position : 0,
                wasPaused: restore.wasPaused, playlistIndex: restore.playlistIndex,
                positionIsExplicit: restore.positionIsExplicit)
        }
        state.setRecoveryIssue(PlaybackRecoveryIssue(
            kind: .message,
            message: changed ? "This file has changed. Playback starts at the beginning; its previous history is retained."
                : "This file could not be verified. Playback starts at the beginning and new progress will not be saved for this session.",
            source: url
        ))
    }

    private func restorePositionAndExternalSubtitles() {
        let pendingRestore = pendingPlaybackRestore
        let matchingRestore: PendingPlaybackRestore? = if let pendingRestore,
                                                          let currentSource = state.currentSource,
                                                          pendingRestore.source.representsSameResource(
                                                              as: currentSource
                                                          )
        {
            pendingRestore
        } else {
            nil
        }
        let savedPosition: TimeInterval? = if let matchingRestore {
            matchingRestore.position
        } else if ignoresSavedPositionForCurrentSource || !remembersPlaybackHistory {
            nil
        } else {
            state.currentURL.flatMap { persistence.playbackPosition(for: $0) }
        }
        pendingPlaybackRestore = nil
        guard let source = state.currentSource else { return }
        let paused = matchingRestore?.wasPaused == true
            || (restoresSessionPaused && state.currentSourceOrigin == .restoredSession)
        pendingPositionRestore = PendingPlaybackRestore(source: source,
            position: savedPosition ?? 0, wasPaused: paused || state.isPauseDesired, playlistIndex: state.currentPlaylistIndex,
            positionIsExplicit: matchingRestore?.positionIsExplicit == true)
        if paused { _ = runtimeDriver?.pause() }
        if currentMediaSettings.overrides(.subtitles),
           let subtitle = currentMediaSettings.externalSubtitleURL,
           currentMediaSettings.areSubtitlesVisible {
            pendingExternalInstallURL = subtitle
        } else if let subtitle = pendingExternalSubtitles.first,
                  !currentMediaSettings.overrides(.subtitles) || currentMediaSettings.areSubtitlesVisible {
            pendingExternalInstallURL = subtitle
        }
        pendingExternalSubtitles = []
    }

    private func cancelFolderScans() {
        activeAutomationID = nil
        queuedSourceOpens.removeAll()
        sourceOpenGeneration = nil
        folderScanGeneration = UUID()
        for task in folderScanTasks.values {
            task.cancel()
        }
    }

    private func supersedePendingRestore(ifNeededFor origin: MediaSourceOrigin) {
        if origin != .restoredSession {
            pendingLocatedHistorySource = nil
            pendingPlaybackRestore = nil
        }
    }

    private func normalizedRestorePosition(
        _ position: TimeInterval,
        for source: MediaSource
    ) -> TimeInterval {
        guard case let .localFile(url) = source,
              let progress = persistence.playbackProgress(for: url)
        else {
            return max(0, position)
        }
        // A watched badge describes history, not the current rewatch session.
        // Only a checkpoint at the end should restart from the beginning.
        if progress.duration > 0,
           progress.duration - position <= 5
        {
            return 0
        }
        return max(0, position)
    }

    private func updateCurrentMediaSettings(
        _ update: (inout MediaPlaybackSettings) -> Void
    ) {
        guard hasLoadedCurrentSource, hasCurrentPlaybackAuthority,
              let currentURL = state.currentURL else { return }
        // Remote playback also has session-local track/delay intent. Only
        // verified local files may persist that intent across sessions.
        update(&currentMediaSettings)
        currentMediaSettings = currentMediaSettings.sanitized()
        if currentURL.isFileURL, canPersistCurrentMediaHistory {
            persistence.setMediaSettings(currentMediaSettings.isEmpty ? nil : currentMediaSettings, for: currentURL)
        }
    }

    private func applyPendingMediaSettings() {
        guard hasReceivedCurrentCatalog, runtimeDriver?.hasPendingTrackSelection != true else { return }
        let settings = currentMediaSettings
        if pendingMediaSettingFields.remove(.audio) != nil {
            if !settings.overrides(.audio) || (settings.audioTrack == nil && settings.audioLanguage == nil) {
                _ = runtimeDriver?.selectAudioTrack(nil)
            } else if let track = settings.audioTrack?.bestMatch(in: state.audioTracks)
                ?? preferredMediaTrack(language: settings.audioLanguage, kind: .audio) {
                _ = runtimeDriver?.selectAudioTrack(track.id)
            }
        }
        guard runtimeDriver?.hasPendingTrackSelection != true else { return }
        if pendingMediaSettingFields.remove(.subtitles) != nil {
            if settings.subtitleTrack?.isExternal == true || settings.externalSubtitleURL != nil {
                pendingExternalSubtitleRestore = (settings.subtitleTrack, settings.areSubtitlesVisible)
            }
            if !settings.overrides(.subtitles) {
                _ = runtimeDriver?.selectAutomaticSubtitle()
            } else if !settings.areSubtitlesVisible {
                pendingExternalInstallURL = nil
                _ = runtimeDriver?.selectSubtitleTrack(nil)
            } else if settings.subtitleTrack?.isExternal != true, settings.externalSubtitleURL == nil,
                      let track = settings.subtitleTrack?.bestMatch(in: state.subtitleTracks)
                        ?? preferredMediaTrack(language: settings.subtitleLanguage, kind: .subtitle) {
                _ = runtimeDriver?.selectSubtitleTrack(track.id)
            }
        }
        guard runtimeDriver?.hasPendingTrackSelection != true else { return }
        if pendingMediaSettingFields.remove(.subtitleDelay) != nil {
            _ = runtimeDriver?.setSubtitleDelay(settings.overrides(.subtitleDelay) ? settings.subtitleDelay : 0)
        }
    }

    private func applyPendingExternalSubtitleRestore() {
        guard runtimeDriver?.hasPendingTrackSelection != true,
              let restore = pendingExternalSubtitleRestore else { return }
        let tracks = state.subtitleTracks.filter { track in
            track.isExternal && (restore.preference?.externalFilename == nil
                || track.externalFilename == restore.preference?.externalFilename)
        }
        guard !tracks.isEmpty else { return }
        pendingExternalSubtitleRestore = nil
        if !restore.visible { _ = runtimeDriver?.selectSubtitleTrack(nil) }
        else if let matched = restore.preference?.bestMatch(in: tracks) {
            _ = runtimeDriver?.selectSubtitleTrack(matched.id)
        }
    }

    nonisolated private static func prepareOpenPlan(
        _ urls: [URL], expandsFolders: Bool = true, checkCancellation: @Sendable () throws -> Void
    ) throws -> PreparedOpenPlan {
        var items: [FolderPlaylistItem] = []
        var subtitleURLs: [URL] = []
        var onlyFolder: URL?
        var sourceFolders: [URL] = []

        for originalURL in urls {
            try checkCancellation()
            guard let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) else { continue }
            try checkCancellation()
            let isDirectory = (
                try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory
            ) == true
            if isDirectory {
                if !expandsFolders { sourceFolders.append(url); continue }
                if urls.count == 1 { onlyFolder = url }
                if let playlist = try? FolderPlaylistDiscovery.discover(in: url, checkCancellation: checkCancellation) {
                    items.append(contentsOf: playlist.items)
                }
            } else if MediaFileSupport.isSupportedMediaFile(url) {
                items.append(FolderPlaylistItem(url: url, dateAdded: FolderPlaylistItem.metadataDate(for: url)))
            } else if MediaFileSupport.isSupportedSubtitleFile(url) {
                subtitleURLs.append(url)
            }
        }

        items = PlaylistMutation.deduplicated(items)
        let associations = ExternalSubtitleMatcher.associate(
            subtitleURLs: subtitleURLs,
            with: items.map(\.url)
        )
        items = items.map { item in
            FolderPlaylistItem(
                url: item.url,
                externalSubtitleURLs: PlaylistMutation.deduplicatedSubtitleURLs(
                    item.externalSubtitleURLs + associations[item.url, default: []]
                ),
                dateAdded: item.dateAdded
            )
        }
        items = PlaylistMutation.sorted(items, by: .dateAdded, ascending: false)
        return PreparedOpenPlan(
            items: items,
            subtitleURLs: NaturalFilenameOrdering.sort(subtitleURLs),
            folderURL: onlyFolder, sourceFolders: sourceFolders
        )
    }

    private func applyOpenPlan(_ plan: PreparedOpenPlan, mode: PlaylistOpenMode) {
        if plan.items.isEmpty {
            guard state.currentSource != nil, !plan.subtitleURLs.isEmpty else {
                state.setShellError("No supported media files or subtitles were dropped.")
                return
            }
            loadExternalSubtitle(plan.subtitleURLs[0])
            if plan.subtitleURLs.count > 1 {
                state.setShellError(
                    "Native playback currently supports one external subtitle at a time; "
                        + "loaded \(plan.subtitleURLs[0].lastPathComponent)."
                )
            }
            return
        }

        let items = mode == .append
            ? PlaylistMutation.deduplicated((pendingSourceTransaction?.playlist ?? state.playlist) + plan.items)
            : plan.items
        if mode == .append, let pending = pendingSourceTransaction,
           let index = items.firstIndex(where: { $0.url == pending.request.source.url }) {
            beginSourceTransaction(item: items[index], playlist: items, folder: nil,
                playlistIndex: index, origin: pending.request.origin, restoreTarget: .file(items[index].url))
            return
        }
        let currentURL = state.currentURL
        let selectedIndex = PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: currentURL,
            fallbackIndex: nil,
            in: items
        )
        let preservedCurrent = currentURL.flatMap { current in
            items.firstIndex {
                NormalizedFileURL.representsSameFile($0.url, current)
            }
        }
        // Stop/window-close retains playlist metadata, but retires playback
        // authority. An explicit replacement open must create a fresh session
        // even when its URL matches that retained selection.
        let reopensStoppedSelection = mode == .replace && eventGate.activeIdentity == nil
        if preservedCurrent == nil || reopensStoppedSelection, let selectedIndex {
            let folder = mode == .replace ? plan.folderURL : nil
            beginSourceTransaction(
                item: items[selectedIndex],
                playlist: items,
                folder: folder,
                playlistIndex: selectedIndex,
                origin: .userSelected,
                restoreTarget: folder.map(PlaybackRestoreTarget.folder)
                    ?? .file(items[selectedIndex].url)
            )
        } else {
            discardFailedTraversalForPlaylistChange()
            state.configurePlaylist(
                folder: mode == .replace ? plan.folderURL : nil,
                items: items,
                selectedIndex: selectedIndex
            )
            if let folderURL = plan.folderURL, mode == .replace {
                persistence.setLastOpenedMedia(.folder(folderURL))
            }
            checkpointSession()
        }
    }

    @discardableResult
    private func supports(_ playerOperation: PlayerOperation, operation: String) -> Bool {
        guard capabilityModel.supports(playerOperation) else {
            state.setShellError(UnsupportedPlaybackCapabilityError(operation).localizedDescription)
            return false
        }
        return true
    }

    private func executeCapabilityCommand(
        _ command: IlliquidCore.PlaybackCommand,
        requiring operation: PlayerOperation
    ) {
        guard supports(operation, operation: String(describing: command)), let backend else { return }
        Task {
            do {
                try await backend.execute(command)
            } catch {
                state.setShellError(error.localizedDescription)
            }
        }
    }

    private func applyEffectiveHardwareDecodingPolicy() {
        let requested = state.hardwareDecodingStatus.policy
        let effective: HardwareDecodingPolicy = if requested == .automatic,
                                                   !state.activeVideoFilters.isEmpty
        {
            .compatibility
        } else {
            requested
        }
        backend?.setHardwareDecodingPolicy(effective)
    }

    private func recordDiagnostic(_ message: String, code: String) {
        _ = code
        state.recordDiagnostic(message)
        guard Bundle.main.bundleIdentifier == "com.example.IlliquidBenchmark",
              ProcessInfo.processInfo.environment[
                "ILLIQUID_ENABLE_BENCHMARK_OVERRIDES"
              ] == "1"
        else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func isValidBenchmarkControlToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private func writeBenchmarkControlDiagnostic(
        session: String,
        id: String,
        action: PlaybackBenchmarkControlAction,
        fields: String
    ) {
        let line = "[benchmark-control] session=\(session) id=\(id) "
            + "action=\(action.diagnosticName) \(fields)\n"
        benchmarkDiagnosticHandler?(String(line.dropLast()))
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func supersedeBenchmarkControl(_ pending: PendingBenchmarkControl?) {
        guard let pending else { return }
        writeBenchmarkControlDiagnostic(
            session: pending.session,
            id: pending.id,
            action: pending.action,
            fields: "phase=completed accepted=no result=superseded"
        )
    }

    private func completeBenchmarkTransport(isPaused: Bool) {
        guard let pending = pendingBenchmarkTransport else { return }
        let matches = switch pending.action {
        case .play: !isPaused
        case .pause: isPaused
        case .seekExact, .snapshot, .rendererMetrics: false
        }
        guard matches else { return }
        pendingBenchmarkTransport = nil
        writeBenchmarkCompletionDiagnostic(
            pending: pending,
            fields: "phase=completed accepted=yes result=transport-confirmed "
                + "paused=\(isPaused ? "yes" : "no") "
                + "elapsed-ms=\(benchmarkElapsedMilliseconds(since: pending.requestedUptime))"
        )
    }

    private func completeBenchmarkSeek() {
        guard let pending = pendingBenchmarkSeek else { return }
        pendingBenchmarkSeek = nil
        writeBenchmarkCompletionDiagnostic(
            pending: pending,
            fields: "phase=completed accepted=yes result=seek-pipeline-completed "
                + "elapsed-ms=\(benchmarkElapsedMilliseconds(since: pending.requestedUptime))"
        )
    }

    private func writeBenchmarkCompletionDiagnostic(
        pending: PendingBenchmarkControl,
        fields: String
    ) {
        guard !defersBenchmarkCompletionDiagnostics else {
            deferredBenchmarkCompletionDiagnostics.append((pending, fields))
            return
        }
        writeBenchmarkControlDiagnostic(
            session: pending.session,
            id: pending.id,
            action: pending.action,
            fields: fields
        )
    }

    private func flushDeferredBenchmarkCompletionDiagnostics() {
        let diagnostics = deferredBenchmarkCompletionDiagnostics
        deferredBenchmarkCompletionDiagnostics.removeAll(keepingCapacity: true)
        for (pending, fields) in diagnostics {
            writeBenchmarkCompletionDiagnostic(pending: pending, fields: fields)
        }
    }

    private func cancelPendingBenchmarkControls(reason: String) {
        for pending in [pendingBenchmarkTransport, pendingBenchmarkSeek].compactMap({ $0 }) {
            writeBenchmarkControlDiagnostic(
                session: pending.session,
                id: pending.id,
                action: pending.action,
                fields: "phase=completed accepted=no result=\(reason)"
            )
        }
        pendingBenchmarkTransport = nil
        pendingBenchmarkSeek = nil
    }

    private func benchmarkElapsedMilliseconds(since start: TimeInterval) -> String {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000
        return String(format: "%.3f", elapsed)
    }
}

/// Source-compatible name retained while application call sites migrate to
/// the production coordinator terminology.
public typealias PlaybackController = PlaybackCoordinator

// MARK: - Settled recovery, sparse overrides and caption navigation

extension PlaybackCoordinator {
    private var hasSettledPlaybackPosition: Bool {
        guard hasLoadedCurrentSource, hasCurrentPlaybackAuthority,
              runtimeDriver?.hasPendingSeek != true,
              let snapshot = runtimeDriver?.currentSnapshot else { return false }
        switch snapshot.phase {
        case .playing, .paused, .ready, .buffering, .draining, .ended:
            return state.position.isFinite && state.position >= 0
        default: return false
        }
    }

    private var canCheckpointCurrentPosition: Bool {
        // Metadata and resume completion gate the position, not transport-rate
        // acknowledgement. A new file at zero or a valid accepted clock remains
        // saveable while the presentation executor is acknowledging Play.
        (hasSettledPlaybackPosition || (hasLoadedCurrentSource && hasCurrentPlaybackAuthority
            && runtimeDriver?.hasPendingSeek != true
            && runtimeDriver?.currentSnapshot.phase == .prerolling
            && state.position.isFinite && state.position >= 0))
            && automationCheckpointOwner == nil && pendingPositionRestore == nil
            && pendingMediaSettingFields.isEmpty && pendingExternalInstallURL == nil
            && runtimeDriver?.hasPendingTrackSelection != true
    }

    private func flushSettledCheckpoint() {
        if historyCheckpointWhenSettled { saveCurrentProgress() }
        else { checkpointSession() }
    }

    private func observeSettledProductState(_ snapshot: PlaybackUISnapshot) {
        observeAcknowledgedExternalSubtitle()
        if hasSettledPlaybackPosition, pendingPositionRestore == nil {
            if lastSettledSession?.source == state.currentSource {
                lastSettledSession?.position = state.position
                lastSettledSession?.wasPaused = state.isPauseDesired
            } else if let source = state.currentSource, !source.isRemote {
                lastSettledSession = PlaybackSessionRecord(source: source,
                    collectionFolder: state.currentFolder, playlistItems: state.playlist,
                    playlistIndex: state.currentPlaylistIndex, position: state.position,
                    wasPaused: state.isPauseDesired)
            }
        }
        if snapshot.phase == .failed, failedSourceTransaction == nil,
           interruptedRecoverySession == nil, var saved = lastSettledSession {
            // The failed runtime may reset its projection. Recover from the last
            // accepted clock, not its failure/seek placeholder. Queue edits are
            // copied once here, not deduplicated on every high-frequency tick.
            saved.playlistItems = state.playlist
            saved.playlistIndex = state.currentPlaylistIndex
            saved.collectionFolder = state.currentFolder
            interruptedRecoverySession = saved
            state.setRecoveryIssue(PlaybackRecoveryIssue(kind: .interruptedSource,
                message: "Playback was interrupted. Check the file and its drive, then retry or locate the file. Your last settled position is retained.",
                source: saved.source.url, diagnosticCode: snapshot.failureCode))
        }
        if checkpointWhenSettled, canCheckpointCurrentPosition { flushSettledCheckpoint() }
        scheduleMediaRestoreDrain()
    }

    private func scheduleMediaRestoreDrain() {
        guard restoreDrainTask == nil, !isDrainingMediaRestore, !isShuttingDown,
              !pendingMediaSettingFields.isEmpty || pendingPositionRestore != nil
                || pendingExternalInstallURL != nil || pendingRestoredAudioDelay != nil
                || pendingExternalSubtitleRestore != nil else { return }
        let generation = playbackGeneration
        restoreDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            restoreDrainTask = nil
            guard !Task.isCancelled, generation == playbackGeneration, !isShuttingDown else { return }
            drainMediaRestore()
        }
    }

    /// The core accepts a single track transaction at a time. Keep the product's
    /// remaining explicit fields until acknowledgement, and restore position
    /// last so a track replacement cannot retire an in-flight resume seek.
    private func drainMediaRestore() {
        guard !isDrainingMediaRestore, !isShuttingDown, hasLoadedCurrentSource,
              hasCurrentPlaybackAuthority, pendingSourceTransaction == nil,
              runtimeDriver?.hasPendingSeek != true,
              runtimeDriver?.currentSnapshot.phase != .failed else { return }
        isDrainingMediaRestore = true
        defer { isDrainingMediaRestore = false }
        applyPendingMediaSettings()
        guard runtimeDriver?.hasPendingTrackSelection != true,
              pendingMediaSettingFields.isEmpty else { return }
        if let url = pendingExternalInstallURL {
            pendingExternalInstallURL = nil
            if runtimeDriver?.selectExternalSubtitle(url) != true {
                pendingExternalPreferenceURL = nil
            }
        }
        guard runtimeDriver?.hasPendingTrackSelection != true else { return }
        applyPendingExternalSubtitleRestore()
        guard runtimeDriver?.hasPendingTrackSelection != true else { return }
        if let restore = pendingPositionRestore {
            pendingPositionRestore = nil
            guard state.currentSource?.representsSameResource(as: restore.source) == true else { return }
            if restore.wasPaused { _ = runtimeDriver?.pause() }
            if restore.position > 1 || restore.positionIsExplicit {
                checkpointWhenSettled = true
                historyCheckpointWhenSettled = true
                _ = runtimeDriver?.seek(to: restore.position, mode: .exact)
            }
        }
        applyDeferredMediaAudioDelay()
        if checkpointWhenSettled, canCheckpointCurrentPosition { flushSettledCheckpoint() }
    }

    private func updatePendingRestoreTransport(paused: Bool) {
        func updated(_ value: PendingPlaybackRestore?) -> PendingPlaybackRestore? {
            value.map { PendingPlaybackRestore(source: $0.source, position: $0.position,
                wasPaused: paused, playlistIndex: $0.playlistIndex, positionIsExplicit: $0.positionIsExplicit) }
        }
        pendingPositionRestore = updated(pendingPositionRestore)
        pendingPlaybackRestore = updated(pendingPlaybackRestore)
    }

    public var defaultPlaybackSpeed: Double { persistence.loadPreferences().playbackSpeed }
    public var mediaSettingsForCurrentFile: MediaPlaybackSettings { currentMediaSettings }
    public var canEditCurrentMediaSettings: Bool {
        hasLoadedCurrentSource && pendingSourceTransaction == nil && !isShuttingDown
            && state.currentURL?.isFileURL == true && hasCurrentPlaybackAuthority
    }

    public func setDefaultPlaybackSpeed(_ speed: Double) {
        guard speed.isFinite, supports(.changePlaybackSpeed) else { return }
        persistence.setPlaybackSpeed(speed)
        if !currentMediaSettings.overrides(.playbackSpeed) { applyCurrentMediaSpeed() }
    }

    private func applyCurrentMediaSpeed() {
        guard supports(.changePlaybackSpeed) else { return }
        let speed = currentMediaSettings.effectivePlaybackSpeed(default: defaultPlaybackSpeed)
        state.setPlaybackSpeed(speed)
        _ = runtimeDriver?.setPlaybackSpeed(speed)
        backend?.setPlaybackSpeed(speed)
    }

    private func applyDeferredMediaAudioDelay() {
        guard hasSettledPlaybackPosition, !hasUnsettledNativeReplacement, pendingPositionRestore == nil,
              pendingMediaSettingFields.isEmpty, pendingExternalInstallURL == nil,
              runtimeDriver?.hasPendingTrackSelection != true,
              let delay = pendingRestoredAudioDelay else { return }
        pendingRestoredAudioDelay = nil
        guard supports(.changeAudioDelay), !state.audioTracks.isEmpty else { return }
        backend?.setAudioDelay(delay)
    }

    private func preferredMediaTrack(language: String?, kind: MediaTrackKind) -> MediaTrack? {
        guard let language = TrackSelectionPreferences.normalizedLanguage(language) else { return nil }
        let tracks = (kind == .audio ? state.audioTracks : state.subtitleTracks).filter {
            TrackSelectionPreferences.normalizedLanguage($0.languageCode) == language
        }
        return tracks.first(where: \.isDefault) ?? tracks.min { $0.id < $1.id }
    }

    public func setMediaLanguage(_ language: String?, kind: MediaTrackKind) {
        guard canEditCurrentMediaSettings else { return }
        guard let normalized = TrackSelectionPreferences.normalizedLanguage(language) else {
            resetCurrentMediaSetting(kind == .audio ? .audio : .subtitles)
            return
        }
        let field: MediaPlaybackSetting = kind == .audio ? .audio : .subtitles
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(field)
            if kind == .audio { settings.audioLanguage = normalized; settings.audioTrack = nil }
            else {
                settings.subtitleLanguage = normalized; settings.subtitleTrack = nil
                settings.externalSubtitleURL = nil; settings.areSubtitlesVisible = true
            }
        }
        if kind == .subtitle {
            pendingExternalSubtitleRestore = nil
            pendingExternalInstallURL = nil
            pendingExternalPreferenceURL = nil
        }
        pendingMediaSettingFields.insert(field)
        drainMediaRestore()
    }

    public func resetCurrentMediaSetting(_ field: MediaPlaybackSetting) {
        guard canEditCurrentMediaSettings else { return }
        updateCurrentMediaSettings { $0.inherit(field) }
        switch field {
        case .playbackSpeed: applyCurrentMediaSpeed()
        case .audioDelay:
            pendingRestoredAudioDelay = 0
            applyDeferredMediaAudioDelay()
        case .audio, .subtitles, .subtitleDelay:
            if field == .subtitles {
                pendingExternalSubtitleRestore = nil
                pendingExternalInstallURL = nil
                pendingExternalPreferenceURL = nil
            }
            pendingMediaSettingFields.insert(field)
            drainMediaRestore()
        }
    }

    public func resetCurrentMediaSettings() {
        guard canEditCurrentMediaSettings else { return }
        updateCurrentMediaSettings { $0 = MediaPlaybackSettings() }
        pendingExternalSubtitleRestore = nil
        pendingExternalInstallURL = nil
        pendingExternalPreferenceURL = nil
        pendingMediaSettingFields = [.audio, .subtitles, .subtitleDelay]
        pendingRestoredAudioDelay = 0
        applyCurrentMediaSpeed()
        drainMediaRestore()
    }

    private func observeAcknowledgedExternalSubtitle() {
        guard let url = runtimeDriver?.acknowledgedExternalSubtitleURL else { return }
        installedExternalSubtitleURL = url
        guard pendingExternalPreferenceURL == url else { return }
        pendingExternalPreferenceURL = nil
        updateCurrentMediaSettings { settings in
            settings.overriddenFields.insert(.subtitles)
            settings.areSubtitlesVisible = true
            settings.externalSubtitleURL = url
            settings.subtitleLanguage = nil
            settings.subtitleTrack = nil
        }
    }

    /// An immutable source/track token. UI tasks compare it again before using an
    /// index or issuing a jump; identical names in another session are not enough.
    public var captionSourceRequest: CaptionSourceRequest? {
        guard hasLoadedCurrentSource, hasCurrentPlaybackAuthority,
              pendingSourceTransaction == nil, state.currentURL?.isFileURL == true,
              runtimeDriver?.hasPendingTrackSelection != true, pendingExternalInstallURL == nil,
              let url = state.currentURL, let track = state.selectedSubtitleTrack else { return nil }
        let externalURL = track.isExternal ? installedExternalSubtitleURL : nil
        return CaptionSourceRequest(mediaURL: url, subtitleTrack: track,
            externalURL: externalURL, fallbackEncoding: state.subtitleFallbackEncoding,
            sourceRevision: playbackGeneration, mediaVersion: currentContentVersion)
    }

    public func readCaptions(for request: CaptionSourceRequest) async throws -> CaptionIndex {
        guard captionSourceRequest == request else { throw PlaybackAutomationError.superseded }
        let index: CaptionIndex
        if request.subtitleTrack.isExternal, let native = backend as? NativePlaybackRuntime {
            guard let document = native.externalCaptionDocument, document.url == request.externalURL else {
                if ["idx", "dvd_subtitle", "hdmv_pgs_subtitle", "dvb_subtitle"].contains(request.subtitleTrack.codec ?? "") {
                    throw CaptionReadError.textTrackRequired
                }
                throw CaptionReadError.trackUnavailable
            }
            index = try await NativeCaptionReader.read(document)
        } else {
            index = try await NativeCaptionReader.read(request)
        }
        try Task.checkCancellation()
        guard captionSourceRequest == request else { throw PlaybackAutomationError.superseded }
        return index
    }

    @discardableResult
    public func jumpToCaption(_ cueID: Int, in index: CaptionIndex, source: CaptionSourceRequest) -> Bool {
        guard captionSourceRequest == source,
              let target = index.target(for: cueID, subtitleDelay: state.subtitleDelay, duration: state.duration) else { return false }
        seek(to: target)
        return true
    }

    @discardableResult
    public func replayPreviousCaption(in index: CaptionIndex, source: CaptionSourceRequest, sentence: Bool) -> Bool {
        guard captionSourceRequest == source,
              let cue = sentence ? index.previousSentence(at: state.position, subtitleDelay: state.subtitleDelay)
                : index.previousCue(at: state.position, subtitleDelay: state.subtitleDelay) else { return false }
        guard jumpToCaption(cue.id, in: index, source: source) else { return false }
        play()
        return true
    }
}

// MARK: - Acknowledged, ordered native automation

extension PlaybackCoordinator {
    private struct PreparedAutomationFile: Sendable {
        let item: FolderPlaylistItem
        let version: MediaContentVersion
    }

    /// Completes after the requested source and exact seek are acknowledged by
    /// the playback core. This is not a claim that a physical display was read.
    public func openMedia(at url: URL, position: Double, paused: Bool = false) async throws -> PlaybackReference {
        try PlaybackAutomationPolicy.validateTimestamp(position)
        let urls = try PlaybackAutomationPolicy.orderedLocalURLs([url])
        return try await automationQueue.perform { [weak self] in
            guard let self else { throw PlaybackAutomationError.noPlayback }
            return try await performAutomationOpen(urls: urls, position: position, paused: paused, expectedVersion: nil)
        }
    }

    public func openPlaybackReference(_ reference: PlaybackReference, paused: Bool = false) async throws -> PlaybackReference {
        let urls = try PlaybackAutomationPolicy.orderedLocalURLs([reference.url])
        return try await automationQueue.perform { [weak self] in
            guard let self else { throw PlaybackAutomationError.noPlayback }
            return try await performAutomationOpen(urls: urls, position: reference.position,
                paused: paused, expectedVersion: reference.contentVersion)
        }
    }

    /// Retains caller order, deduplicates by canonical local identity and does
    /// not sort by date added. If no source is loaded, the first item is opened
    /// paused so the queue has a valid, recoverable session; otherwise playback
    /// is untouched. All paths are checked before any queue mutation.
    @discardableResult
    public func enqueueOrderedMedia(_ urls: [URL]) async throws -> [URL] {
        let urls = try PlaybackAutomationPolicy.orderedLocalURLs(urls)
        return try await automationQueue.perform { [weak self] in
            guard let self, !isShuttingDown, pendingSourceTransaction == nil, !isPreparingSource else {
                throw PlaybackAutomationError.busy
            }
            let operation = UUID()
            activeAutomationID = operation
            defer { finishAutomationOwnership(operation) }
            let prepared = try await prepareAutomationFiles(urls)
            try requireAutomationOwnership(operation)
            let existing = Set(state.playlist.map(\.id))
            let additions = prepared.filter { !existing.contains($0.item.id) }
            guard !additions.isEmpty else { return [] }
            let items = PlaylistMutation.deduplicated(state.playlist + additions.map(\.item))
            finishShuffleForExplicitOrder()
            if state.currentSource == nil {
                // There may already be an idle queue; opening its first newly
                // requested file is explicit and does not reorder that queue.
                let first = additions[0]
                let index = items.firstIndex(where: { $0.id == first.item.id }) ?? 0
                pendingPlaybackRestore = PendingPlaybackRestore(source: .localFile(first.item.url),
                    position: 0, wasPaused: true, playlistIndex: index, positionIsExplicit: true)
                guard beginSourceTransaction(item: first.item, playlist: items, folder: nil,
                    playlistIndex: index, origin: .userSelected, restoreTarget: .file(first.item.url),
                    automationID: operation) else { throw PlaybackAutomationError.failed("The player rejected the queued source.") }
                do {
                    _ = try await awaitAutomationOpen(first, operation: operation, position: 0, paused: true)
                } catch {
                    if activeAutomationID == operation { stop() }
                    throw error
                }
            } else {
                finishShuffleForExplicitOrder()
                discardFailedTraversalForPlaylistChange()
                state.configurePlaylist(folder: nil, items: items,
                    selectedIndex: PlaylistMutation.indexPreservingCurrentIdentity(currentURL: state.currentURL,
                        fallbackIndex: state.currentPlaylistIndex, in: items))
                checkpointSession()
            }
            return additions.map { $0.item.url }
        }
    }

    private var hasUnsettledNativeReplacement: Bool {
        (backend as? NativePlaybackRuntime)?.hasPendingMediaReplacement == true
    }

    public func currentPlaybackReference() throws -> PlaybackReference {
        guard automationCheckpointOwner == nil else { throw PlaybackAutomationError.noPlayback }
        return try makeSettledPlaybackReference()
    }

    private func makeSettledPlaybackReference() throws -> PlaybackReference {
        guard pendingSourceTransaction == nil, !isPreparingSource, hasSettledPlaybackPosition, !hasUnsettledNativeReplacement, pendingPositionRestore == nil,
              pendingMediaSettingFields.isEmpty, pendingExternalInstallURL == nil,
              pendingRestoredAudioDelay == nil,
              runtimeDriver?.hasPendingTrackSelection != true,
              let url = state.currentURL, url.isFileURL, let version = currentContentVersion else {
            throw PlaybackAutomationError.noPlayback
        }
        return try PlaybackReference(url: url, position: state.position, contentVersion: version)
    }

    private func performAutomationOpen(urls: [URL], position: Double, paused: Bool,
                                       expectedVersion: MediaContentVersion?) async throws -> PlaybackReference {
        guard !isShuttingDown else { throw PlaybackAutomationError.noPlayback }
        cancelFolderScans()
        let operation = UUID()
        activeAutomationID = operation
        var started = false
        defer { finishAutomationOwnership(operation) }
        do {
            let prepared = try await prepareAutomationFiles(urls)
            try requireAutomationOwnership(operation)
            guard let first = prepared.first else { throw PlaybackAutomationError.invalidFile }
            if let expectedVersion, first.version != expectedVersion { throw PlaybackAutomationError.changedFile }
            pendingPlaybackRestore = PendingPlaybackRestore(source: .localFile(first.item.url),
                position: position, wasPaused: paused, playlistIndex: 0, positionIsExplicit: true)
            pendingLocatedHistorySource = nil
            started = beginSourceTransaction(item: first.item, playlist: prepared.map(\.item), folder: nil,
                playlistIndex: 0, origin: .userSelected, restoreTarget: .file(first.item.url), automationID: operation)
            guard started else { throw PlaybackAutomationError.failed("The player rejected the open request.") }
            return try await awaitAutomationOpen(first, operation: operation, position: position, paused: paused)
        } catch {
            // Never stop a newer UI/automation session. While this action still
            // owns the load its candidate checkpoint is suppressed, including
            // the save performed by Stop on timeout/cancellation/failure.
            if started, activeAutomationID == operation { stop() }
            throw error
        }
    }

    private func prepareAutomationFiles(_ urls: [URL]) async throws -> [PreparedAutomationFile] {
        try await sourcePreparation.perform { check in
            var result: [PreparedAutomationFile] = []
            var seen = Set<String>()
            for url in urls {
                try check()
                guard let resolved = NormalizedFileURL.resolveFilesystemIdentity(url),
                      MediaFileSupport.isSupportedMediaFile(resolved),
                      let version = NativeMediaInspection.contentVersion(of: resolved),
                      let key = NormalizedFileURL.persistenceKey(for: resolved) else {
                    throw PlaybackAutomationError.invalidFile
                }
                try check()
                if seen.insert(key).inserted {
                    result.append(PreparedAutomationFile(item: FolderPlaylistItem(url: resolved), version: version))
                }
            }
            return result
        }
    }

    private func requireAutomationOwnership(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard !isShuttingDown, activeAutomationID == operation else { throw PlaybackAutomationError.superseded }
    }

    private func awaitAutomationOpen(_ file: PreparedAutomationFile, operation: UUID,
                                     position: Double, paused: Bool) async throws -> PlaybackReference {
        let deadline = ProcessInfo.processInfo.systemUptime + automationTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireAutomationOwnership(operation)
            if let failed = failedSourceTransaction, failed.identity.generation == playbackGeneration {
                throw PlaybackAutomationError.failed(state.recoveryIssue?.message ?? "The source could not be opened.")
            }
            let snapshot = runtimeDriver?.currentSnapshot
            if snapshot?.phase == .failed {
                throw PlaybackAutomationError.failed(state.recoveryIssue?.message ?? "Playback could not be prepared.")
            }
            if hasLoadedCurrentSource, state.currentURL == file.item.url {
                guard currentContentVersion == file.version else { throw PlaybackAutomationError.changedFile }
                if state.duration > 0, position > state.duration { throw PlaybackAutomationError.invalidTimestamp }
                let transportMatches = paused ? snapshot?.actualTransport == .paused : snapshot?.actualTransport == .playing
                let phaseMatches = paused ? snapshot?.phase == .paused : snapshot?.phase == .playing
                if transportMatches, phaseMatches, state.isPauseDesired == paused, !hasUnsettledNativeReplacement,
                   runtimeDriver?.hasPendingSeek != true, pendingPositionRestore == nil, pendingMediaSettingFields.isEmpty,
                   pendingExternalInstallURL == nil, pendingRestoredAudioDelay == nil,
                   runtimeDriver?.hasPendingTrackSelection != true {
                    if !state.audioTracks.isEmpty,
                       abs(state.audioDelay - currentMediaSettings.effectiveAudioDelay) > 0.000_1 {
                        throw PlaybackAutomationError.failed("The saved audio delay could not be applied. Open the file directly to review its preferences.")
                    }
                    let reference = try makeSettledPlaybackReference()
                    // Only an acknowledged, validated action may replace the
                    // previous crash checkpoint, including explicit timestamp 0.
                    automationCheckpointOwner = nil
                    saveCurrentProgress()
                    return reference
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PlaybackAutomationError.timedOut
    }

    private func finishAutomationOwnership(_ operation: UUID) {
        if activeAutomationID == operation { activeAutomationID = nil }
        if automationCheckpointOwner == operation { automationCheckpointOwner = nil }
    }
}
