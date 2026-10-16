import Foundation
import Observation

/// Framework-free values projected from the deterministic playback authority.
/// Runtime telemetry is composed separately and cannot override these fields.
public struct PlaybackAuthorityProjection: Equatable, Sendable {
    public let phase: PlaybackPhase
    public let isPauseDesired: Bool
    public let position: TimeInterval
    public let duration: TimeInterval
    public let isBuffering: Bool
    public let selectedAudioID: Int64?
    public let selectedSubtitleID: Int64?
    public let subtitleDelay: TimeInterval
    public let failureCode: String?

    public init(
        phase: PlaybackPhase,
        position: TimeInterval,
        duration: TimeInterval,
        isBuffering: Bool,
        selectedAudioID: Int64?,
        selectedSubtitleID: Int64?,
        subtitleDelay: TimeInterval,
        failureCode: String?,
        isPauseDesired: Bool = true
    ) {
        self.phase = phase
        self.isPauseDesired = isPauseDesired
        self.position = position
        self.duration = duration
        self.isBuffering = isBuffering
        self.selectedAudioID = selectedAudioID
        self.selectedSubtitleID = selectedSubtitleID
        self.subtitleDelay = subtitleDelay
        self.failureCode = failureCode
    }
}

@MainActor
@Observable
public final class PlaybackState {
    /// Synchronous projection notification, not a command-acknowledgement stream.
    /// Compound setters coalesce their changes; unchanged values may be silent.
    @ObservationIgnored public var onMutation: (@MainActor () -> Void)?
    public internal(set) var currentSource: MediaSource? { didSet { notifyMutation() } }
    public internal(set) var currentSourceOrigin: MediaSourceOrigin? { didSet { notifyMutation() } }
    public internal(set) var currentFolder: URL? { didSet { notifyMutation() } }
    public internal(set) var playlist: [FolderPlaylistItem] = [] { didSet { notifyMutation() } }
    public internal(set) var currentPlaylistIndex: Int? { didSet { notifyMutation() } }
    public internal(set) var phase: PlaybackPhase = .idle { didSet { notifyMutation() } }
    public internal(set) var isPauseDesired = true { didSet { notifyMutation() } }
    public internal(set) var position: TimeInterval = 0 { didSet { notifyMutation() } }
    public internal(set) var duration: TimeInterval = 0 { didSet { notifyMutation() } }
    public internal(set) var videoAspectRatio: Double? { didSet { notifyMutation() } }
    public internal(set) var volume: Double { didSet { notifyMutation() } }
    public internal(set) var isMuted: Bool { didSet { notifyMutation() } }
    public internal(set) var playbackSpeed: Double { didSet { notifyMutation() } }
    public internal(set) var audioTracks: [MediaTrack] = [] { didSet { notifyMutation() } }
    public internal(set) var subtitleTracks: [MediaTrack] = [] { didSet { notifyMutation() } }
    public internal(set) var selectedAudioTrack: MediaTrack? { didSet { notifyMutation() } }
    public internal(set) var selectedSubtitleTrack: MediaTrack? { didSet { notifyMutation() } }
    public internal(set) var chapters: [Chapter] = [] { didSet { notifyMutation() } }
    public internal(set) var currentChapterID: Int64? { didSet { notifyMutation() } }
    public internal(set) var audioDelay: TimeInterval = 0 { didSet { notifyMutation() } }
    public internal(set) var subtitleDelay: TimeInterval = 0 { didSet { notifyMutation() } }
    public internal(set) var bufferStatus: BufferStatus = .empty { didSet { notifyMutation() } }
    public internal(set) var videoOutputStatus: VideoOutputStatus = .empty { didSet { notifyMutation() } }
    public internal(set) var displayOutputStatus: DisplayOutputStatus = .empty { didSet { notifyMutation() } }
    public internal(set) var hardwareDecodingStatus: HardwareDecodingStatus { didSet { notifyMutation() } }
    public internal(set) var audioOutputDevice: AudioOutputDevice? { didSet { notifyMutation() } }
    public internal(set) var audioOutputDevices: [AudioOutputDevice] = [] { didSet { notifyMutation() } }
    public internal(set) var videoAdjustments: VideoAdjustmentState = .standard { didSet { notifyMutation() } }
    public internal(set) var activeVideoFilters: [VideoFilterPreset] = [] { didSet { notifyMutation() } }
    public internal(set) var recentDiagnosticMessages: [String] = [] { didSet { notifyMutation() } }
    public internal(set) var isFullscreen = false { didSet { notifyMutation() } }
    public internal(set) var pictureInPicture: PictureInPictureState = .unavailable { didSet { notifyMutation() } }
    public internal(set) var isSidebarVisible: Bool { didSet { notifyMutation() } }
    public internal(set) var repeatMode: PlaybackRepeatMode { didSet { notifyMutation() } }
    public internal(set) var isShuffleEnabled: Bool { didSet { notifyMutation() } }
    public internal(set) var coreFailureCode: String? { didSet { notifyMutation() } }
    public internal(set) var shellError: String? { didSet { notifyMutation() } }
    public private(set) var recoveryIssue: PlaybackRecoveryIssue? { didSet { notifyMutation() } }
    public private(set) var trackSelectionPreferences: TrackSelectionPreferences { didSet { notifyMutation() } }
    public private(set) var subtitleFallbackEncoding: SubtitleFallbackEncoding { didSet { notifyMutation() } }

    @ObservationIgnored private var mutationBatchDepth = 0
    @ObservationIgnored private var hasPendingMutation = false

    private func notifyMutation() {
        guard mutationBatchDepth == 0 else {
            hasPendingMutation = true
            return
        }
        #if ILLIQUID_STATE_SIGNPOSTS
        guard onMutation != nil else { return }
        let interval = NonDecodePerformance.begin("PlaybackStatePublish")
        defer { NonDecodePerformance.end(interval) }
        #endif
        onMutation?()
    }

    private func performMutationBatch(_ updates: () -> Void) {
        mutationBatchDepth += 1
        updates()
        mutationBatchDepth -= 1
        guard mutationBatchDepth == 0, hasPendingMutation else { return }
        hasPendingMutation = false
        #if ILLIQUID_STATE_SIGNPOSTS
        guard onMutation != nil else { return }
        let interval = NonDecodePerformance.begin("PlaybackStatePublish")
        defer { NonDecodePerformance.end(interval) }
        #endif
        onMutation?()
    }

    public init(preferences: PlaybackPreferences = .standard) {
        trackSelectionPreferences = preferences.trackSelection
        subtitleFallbackEncoding = preferences.subtitleFallbackEncoding
        volume = preferences.volume
        isMuted = preferences.isMuted
        playbackSpeed = preferences.playbackSpeed
        isSidebarVisible = preferences.isSidebarVisible
        repeatMode = preferences.repeatMode
        isShuffleEnabled = preferences.isShuffleEnabled
        hardwareDecodingStatus = HardwareDecodingStatus(policy: preferences.hardwareDecodingPolicy)
    }

    public var isPaused: Bool { phase.isPaused }

    public var isLoading: Bool { phase.isLoading }

    public var currentURL: URL? { currentSource?.url }

    /// Explicit composition of independently owned failure sources. Shell
    /// validation takes display precedence without replacing core authority.
    public var lastError: String? { shellError ?? coreFailureCode }

    public var diagnosticsSnapshot: PlaybackDiagnosticsSnapshot {
        PlaybackDiagnosticsSnapshot(
            source: currentSource,
            sourceOrigin: currentSourceOrigin,
            phase: phase,
            position: position,
            duration: duration,
            buffer: bufferStatus,
            video: videoOutputStatus,
            display: displayOutputStatus,
            audioDevice: audioOutputDevice,
            recentMessages: recentDiagnosticMessages
        )
    }

    public var hasNextItem: Bool {
        guard let currentPlaylistIndex else { return false }
        return playlist.indices.contains(currentPlaylistIndex + 1)
    }

    public var hasPreviousItem: Bool {
        guard let currentPlaylistIndex else { return false }
        return playlist.indices.contains(currentPlaylistIndex - 1)
    }

    public func configurePlaylist(
        folder: URL?,
        items: [FolderPlaylistItem],
        selectedIndex: Int?
    ) {
        performMutationBatch {
            currentFolder = folder
            playlist = items
            currentPlaylistIndex = selectedIndex.flatMap {
                items.indices.contains($0) ? $0 : nil
            }
        }
    }

    /// Resets shell-owned media metadata before the core accepts a load. The
    /// immediately following core projection owns lifecycle and logical state.
    public func prepareLoadMetadata(request: MediaLoadRequest, playlistIndex: Int?) {
        performMutationBatch {
            currentSource = request.source
            currentSourceOrigin = request.origin
            currentPlaylistIndex = playlistIndex
            videoAspectRatio = nil
            audioTracks = []
            subtitleTracks = []
            chapters = []
            currentChapterID = nil
            audioDelay = 0
            bufferStatus = BufferStatus(isBuffering: bufferStatus.isBuffering)
            videoOutputStatus = .empty
            shellError = nil
        }
    }

    /// Clears shell metadata when the user closes the loaded media.
    /// Lifecycle, transport and timing remain projections of the playback core.
    public func clearMediaMetadata() {
        performMutationBatch {
            currentSource = nil
            currentSourceOrigin = nil
            currentFolder = nil
            playlist = []
            currentPlaylistIndex = nil
            videoAspectRatio = nil
            audioTracks = []
            subtitleTracks = []
            chapters = []
            currentChapterID = nil
            audioDelay = 0
            videoOutputStatus = .empty
            shellError = nil
            recoveryIssue = nil
        }
    }

    /// The only mutation entry point for core-owned playback fields.
    public func applyAuthorityProjection(_ projection: PlaybackAuthorityProjection) {
        performMutationBatch {
            if phase != projection.phase { phase = projection.phase }
            if isPauseDesired != projection.isPauseDesired {
                isPauseDesired = projection.isPauseDesired
            }
            if projection.position.isFinite,
               projection.position >= 0,
               position != projection.position
            {
                position = projection.position
            }
            if projection.duration.isFinite,
               projection.duration >= 0,
               duration != projection.duration
            {
                duration = projection.duration
            }
            if bufferStatus.isBuffering != projection.isBuffering {
                bufferStatus.isBuffering = projection.isBuffering
            }
            let audioTrack = audioTracks.first { $0.id == projection.selectedAudioID }
            if selectedAudioTrack != audioTrack { selectedAudioTrack = audioTrack }
            let subtitleTrack = subtitleTracks.first { $0.id == projection.selectedSubtitleID }
            if selectedSubtitleTrack != subtitleTrack { selectedSubtitleTrack = subtitleTrack }
            let delay = projection.subtitleDelay.isFinite ? projection.subtitleDelay : 0
            if subtitleDelay != delay { subtitleDelay = delay }
            if coreFailureCode != projection.failureCode {
                coreFailureCode = projection.failureCode
                if let code = projection.failureCode, recoveryIssue == nil {
                    recoveryIssue = PlaybackRecoveryIssue(coreFailureCode: code)
                }
            }
        }
    }

    public func setVolume(_ volume: Double) {
        guard self.volume != volume else { return }
        self.volume = volume
    }

    public func setMuted(_ isMuted: Bool) {
        guard self.isMuted != isMuted else { return }
        self.isMuted = isMuted
    }

    public func setPlaybackSpeed(_ playbackSpeed: Double) {
        guard self.playbackSpeed != playbackSpeed else { return }
        self.playbackSpeed = playbackSpeed
    }

    public func setFullscreen(_ isFullscreen: Bool) {
        guard self.isFullscreen != isFullscreen else { return }
        self.isFullscreen = isFullscreen
    }

    public func updatePictureInPicture(_ state: PictureInPictureState) {
        guard pictureInPicture != state else { return }
        pictureInPicture = state
    }

    public func setSidebarVisible(_ isSidebarVisible: Bool) {
        guard self.isSidebarVisible != isSidebarVisible else { return }
        self.isSidebarVisible = isSidebarVisible
    }

    public func setRepeatMode(_ repeatMode: PlaybackRepeatMode) {
        guard self.repeatMode != repeatMode else { return }
        self.repeatMode = repeatMode
    }

    public func setShuffleEnabled(_ isShuffleEnabled: Bool) {
        guard self.isShuffleEnabled != isShuffleEnabled else { return }
        self.isShuffleEnabled = isShuffleEnabled
    }

    public func setShellError(_ message: String?) {
        performMutationBatch {
            if shellError != message { shellError = message }
            // The issue can have been dismissed/replaced while the text stayed
            // equal. Preserve restoration of that context, even for equal text.
            if let message {
                let issue = PlaybackRecoveryIssue(kind: .message, message: message)
                if recoveryIssue != issue { recoveryIssue = issue }
            }
        }
    }

    public func setRecoveryIssue(_ issue: PlaybackRecoveryIssue?) {
        guard recoveryIssue != issue else { return }
        recoveryIssue = issue
    }

    public func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences) {
        let normalized = preferences.sanitized()
        guard trackSelectionPreferences != normalized else { return }
        trackSelectionPreferences = normalized
    }

    public func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding) {
        guard subtitleFallbackEncoding != encoding else { return }
        subtitleFallbackEncoding = encoding
    }

    public func updateVideoAspectRatio(_ value: Double?) {
        let normalized = value.flatMap { ratio in
            ratio.isFinite && ratio > 0 ? ratio : nil
        }
        guard videoAspectRatio != normalized else { return }
        videoAspectRatio = normalized
    }

    public func updateBufferTelemetry(cacheDuration: TimeInterval, cachePercent: Double? = nil) {
        var status = bufferStatus
        if cacheDuration.isFinite {
            status.cacheDuration = max(cacheDuration, 0)
        }
        if let cachePercent, cachePercent.isFinite {
            status.cachePercent = min(max(cachePercent, 0), 100)
        }
        if bufferStatus != status { bufferStatus = status }
    }

    public func updateVideoOutput(_ update: (inout VideoOutputStatus) -> Void) {
        var status = videoOutputStatus
        update(&status)
        if videoOutputStatus != status { videoOutputStatus = status }
    }

    public func updateDisplayOutput(_ status: DisplayOutputStatus) {
        guard displayOutputStatus != status else { return }
        displayOutputStatus = status
    }

    public func updateAudioOutputDevices(_ devices: [AudioOutputDevice]) {
        let selected = devices.first(where: \.isSelected)
        performMutationBatch {
            audioOutputDevices = devices
            if audioOutputDevice != selected { audioOutputDevice = selected }
        }
    }

    public func updateChapters(_ chapters: [Chapter], currentID: Int64?) {
        performMutationBatch {
            // Do not add another full-array equality scan here. Observation's
            // setter and the view projection already compare catalogue values.
            self.chapters = chapters
            if currentChapterID != currentID { currentChapterID = currentID }
        }
    }

    public func setAudioDelay(_ delay: TimeInterval) {
        let normalized = delay.isFinite ? delay : 0
        guard audioDelay != normalized else { return }
        audioDelay = normalized
    }

    public func updateVideoAdjustments(_ update: (inout VideoAdjustmentState) -> Void) {
        var adjustments = videoAdjustments
        update(&adjustments)
        if videoAdjustments != adjustments { videoAdjustments = adjustments }
    }

    public func setVideoFilter(_ filter: VideoFilterPreset, enabled: Bool) {
        performMutationBatch {
            let currentlyEnabled = activeVideoFilters.contains(filter)
            guard currentlyEnabled != enabled else { return }

            if enabled {
                activeVideoFilters.append(filter)
                activeVideoFilters.sort {
                    guard let left = VideoFilterPreset.allCases.firstIndex(of: $0),
                          let right = VideoFilterPreset.allCases.firstIndex(of: $1)
                    else { return $0.rawValue < $1.rawValue }
                    return left < right
                }
            } else {
                activeVideoFilters.removeAll { $0 == filter }
            }
        }
    }

    public func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy) {
        guard hardwareDecodingStatus.policy != policy else { return }
        hardwareDecodingStatus.policy = policy
    }

    public func updateActiveDecoder(
        _ decoder: String?,
        isHardwareDecoded: Bool,
        didFallbackToSoftware: Bool
    ) {
        var hardwareStatus = hardwareDecodingStatus
        hardwareStatus.activeDecoder = decoder
        hardwareStatus.activeIsHardwareDecoded = isHardwareDecoded
        hardwareStatus.fallbackToSoftwareObserved = didFallbackToSoftware
        var videoStatus = videoOutputStatus
        videoStatus.decoder = decoder
        videoStatus.isHardwareDecoded = isHardwareDecoded
        performMutationBatch {
            if hardwareDecodingStatus != hardwareStatus {
                hardwareDecodingStatus = hardwareStatus
            }
            if videoOutputStatus != videoStatus {
                videoOutputStatus = videoStatus
            }
        }
    }

    public func recordDiagnostic(_ message: String) {
        performMutationBatch {
            guard !message.isEmpty else { return }
            recentDiagnosticMessages.append(message)
            if recentDiagnosticMessages.count > 100 {
                recentDiagnosticMessages.removeFirst(recentDiagnosticMessages.count - 100)
            }
        }
    }

    public func updateTrackCatalog(_ tracks: [MediaTrack]) {
        // Count first so both partitions allocate their exact required capacity.
        // Reserving tracks.count for both would retain unused catalogue memory.
        let audioCount = tracks.reduce(into: 0) { count, track in
            if track.kind == .audio { count += 1 }
        }
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        audio.reserveCapacity(audioCount)
        subtitles.reserveCapacity(tracks.count - audioCount)
        for track in tracks {
            switch track.kind {
            case .audio: audio.append(track)
            case .subtitle: subtitles.append(track)
            }
        }
        performMutationBatch {
            audioTracks = audio
            subtitleTracks = subtitles
        }
    }
}
