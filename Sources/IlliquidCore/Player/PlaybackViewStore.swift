import Foundation
import Observation

/// Immutable UI projection. Runtime callbacks publish a whole value; SwiftUI,
/// Now Playing, PiP, and power policy never mutate playback authority.
public struct PlaybackViewSnapshot: Equatable, Sendable {
    public let currentSource: MediaSource?
    public let currentSourceOrigin: MediaSourceOrigin?
    public let currentFolder: URL?
    public let playlist: [FolderPlaylistItem]
    public let currentPlaylistIndex: Int?
    public let phase: PlaybackPhase
    public let isPauseDesired: Bool
    public let position: TimeInterval
    public let duration: TimeInterval
    public let videoAspectRatio: Double?
    public let volume: Double
    public let isMuted: Bool
    public let playbackSpeed: Double
    public let audioTracks: [MediaTrack]
    public let subtitleTracks: [MediaTrack]
    public let selectedAudioTrack: MediaTrack?
    public let selectedSubtitleTrack: MediaTrack?
    public let chapters: [Chapter]
    public let currentChapterID: Int64?
    public let audioDelay: TimeInterval
    public let subtitleDelay: TimeInterval
    public let bufferStatus: BufferStatus
    public let videoOutputStatus: VideoOutputStatus
    public let displayOutputStatus: DisplayOutputStatus
    public let hardwareDecodingStatus: HardwareDecodingStatus
    public let audioOutputDevice: AudioOutputDevice?
    public let audioOutputDevices: [AudioOutputDevice]
    public let videoAdjustments: VideoAdjustmentState
    public let activeVideoFilters: [VideoFilterPreset]
    public let recentDiagnosticMessages: [String]
    public let isFullscreen: Bool
    public let pictureInPicture: PictureInPictureState
    public let isSidebarVisible: Bool
    public let repeatMode: PlaybackRepeatMode
    public let isShuffleEnabled: Bool
    public let coreFailureCode: String?
    public let shellError: String?
    public let recoveryIssue: PlaybackRecoveryIssue?
    public let trackSelectionPreferences: TrackSelectionPreferences
    public let subtitleFallbackEncoding: SubtitleFallbackEncoding
    public let lastError: String?

    @MainActor
    public init(state: PlaybackState) {
        currentSource = state.currentSource
        currentSourceOrigin = state.currentSourceOrigin
        currentFolder = state.currentFolder
        playlist = state.playlist
        currentPlaylistIndex = state.currentPlaylistIndex
        phase = state.phase
        isPauseDesired = state.isPauseDesired
        position = state.position
        duration = state.duration
        videoAspectRatio = state.videoAspectRatio
        volume = state.volume
        isMuted = state.isMuted
        playbackSpeed = state.playbackSpeed
        audioTracks = state.audioTracks
        subtitleTracks = state.subtitleTracks
        selectedAudioTrack = state.selectedAudioTrack
        selectedSubtitleTrack = state.selectedSubtitleTrack
        chapters = state.chapters
        currentChapterID = state.currentChapterID
        audioDelay = state.audioDelay
        subtitleDelay = state.subtitleDelay
        bufferStatus = state.bufferStatus
        videoOutputStatus = state.videoOutputStatus
        displayOutputStatus = state.displayOutputStatus
        hardwareDecodingStatus = state.hardwareDecodingStatus
        audioOutputDevice = state.audioOutputDevice
        audioOutputDevices = state.audioOutputDevices
        videoAdjustments = state.videoAdjustments
        activeVideoFilters = state.activeVideoFilters
        recentDiagnosticMessages = state.recentDiagnosticMessages
        isFullscreen = state.isFullscreen
        pictureInPicture = state.pictureInPicture
        isSidebarVisible = state.isSidebarVisible
        repeatMode = state.repeatMode
        isShuffleEnabled = state.isShuffleEnabled
        coreFailureCode = state.coreFailureCode
        shellError = state.shellError
        recoveryIssue = state.recoveryIssue
        trackSelectionPreferences = state.trackSelectionPreferences
        subtitleFallbackEncoding = state.subtitleFallbackEncoding
        lastError = state.lastError
    }
}

@MainActor
@Observable
public final class PlaybackViewStore {
    // Keep the complete immutable projection available for non-view consumers,
    // but do not make it the single observation dependency for every UI field.
    // Otherwise a position-only update invalidates controls that only read
    // tracks, playlist, output, or preferences.
    @ObservationIgnored private var snapshotStorage: PlaybackViewSnapshot

    public private(set) var currentSource: MediaSource?
    public private(set) var currentSourceOrigin: MediaSourceOrigin?
    public private(set) var currentFolder: URL?
    public private(set) var playlist: [FolderPlaylistItem]
    public private(set) var currentPlaylistIndex: Int?
    public private(set) var phase: PlaybackPhase
    public private(set) var isPauseDesired: Bool
    public private(set) var position: TimeInterval
    public private(set) var duration: TimeInterval
    public private(set) var videoAspectRatio: Double?
    public private(set) var volume: Double
    public private(set) var isMuted: Bool
    public private(set) var playbackSpeed: Double
    public private(set) var audioTracks: [MediaTrack]
    public private(set) var subtitleTracks: [MediaTrack]
    public private(set) var selectedAudioTrack: MediaTrack?
    public private(set) var selectedSubtitleTrack: MediaTrack?
    public private(set) var chapters: [Chapter]
    public private(set) var currentChapterID: Int64?
    public private(set) var audioDelay: TimeInterval
    public private(set) var subtitleDelay: TimeInterval
    public private(set) var bufferStatus: BufferStatus
    public private(set) var videoOutputStatus: VideoOutputStatus
    public private(set) var displayOutputStatus: DisplayOutputStatus
    public private(set) var hardwareDecodingStatus: HardwareDecodingStatus
    public private(set) var audioOutputDevice: AudioOutputDevice?
    public private(set) var audioOutputDevices: [AudioOutputDevice]
    public private(set) var videoAdjustments: VideoAdjustmentState
    public private(set) var activeVideoFilters: [VideoFilterPreset]
    public private(set) var recentDiagnosticMessages: [String]
    public private(set) var isFullscreen: Bool
    public private(set) var pictureInPicture: PictureInPictureState
    public private(set) var isSidebarVisible: Bool
    public private(set) var repeatMode: PlaybackRepeatMode
    public private(set) var isShuffleEnabled: Bool
    public private(set) var coreFailureCode: String?
    public private(set) var shellError: String?
    public private(set) var recoveryIssue: PlaybackRecoveryIssue?
    public private(set) var trackSelectionPreferences: TrackSelectionPreferences
    public private(set) var subtitleFallbackEncoding: SubtitleFallbackEncoding
    public private(set) var lastError: String?

    public var snapshot: PlaybackViewSnapshot { snapshotStorage }

    public init(snapshot: PlaybackViewSnapshot) {
        snapshotStorage = snapshot
        currentSource = snapshot.currentSource
        currentSourceOrigin = snapshot.currentSourceOrigin
        currentFolder = snapshot.currentFolder
        playlist = snapshot.playlist
        currentPlaylistIndex = snapshot.currentPlaylistIndex
        phase = snapshot.phase
        isPauseDesired = snapshot.isPauseDesired
        position = snapshot.position
        duration = snapshot.duration
        videoAspectRatio = snapshot.videoAspectRatio
        volume = snapshot.volume
        isMuted = snapshot.isMuted
        playbackSpeed = snapshot.playbackSpeed
        audioTracks = snapshot.audioTracks
        subtitleTracks = snapshot.subtitleTracks
        selectedAudioTrack = snapshot.selectedAudioTrack
        selectedSubtitleTrack = snapshot.selectedSubtitleTrack
        chapters = snapshot.chapters
        currentChapterID = snapshot.currentChapterID
        audioDelay = snapshot.audioDelay
        subtitleDelay = snapshot.subtitleDelay
        bufferStatus = snapshot.bufferStatus
        videoOutputStatus = snapshot.videoOutputStatus
        displayOutputStatus = snapshot.displayOutputStatus
        hardwareDecodingStatus = snapshot.hardwareDecodingStatus
        audioOutputDevice = snapshot.audioOutputDevice
        audioOutputDevices = snapshot.audioOutputDevices
        videoAdjustments = snapshot.videoAdjustments
        activeVideoFilters = snapshot.activeVideoFilters
        recentDiagnosticMessages = snapshot.recentDiagnosticMessages
        isFullscreen = snapshot.isFullscreen
        pictureInPicture = snapshot.pictureInPicture
        isSidebarVisible = snapshot.isSidebarVisible
        repeatMode = snapshot.repeatMode
        isShuffleEnabled = snapshot.isShuffleEnabled
        coreFailureCode = snapshot.coreFailureCode
        shellError = snapshot.shellError
        recoveryIssue = snapshot.recoveryIssue
        trackSelectionPreferences = snapshot.trackSelectionPreferences
        subtitleFallbackEncoding = snapshot.subtitleFallbackEncoding
        lastError = snapshot.lastError
    }

    public func publish(_ snapshot: PlaybackViewSnapshot) {
        guard snapshot != snapshotStorage else { return }
        snapshotStorage = snapshot
        if currentSource != snapshot.currentSource { currentSource = snapshot.currentSource }
        if currentSourceOrigin != snapshot.currentSourceOrigin {
            currentSourceOrigin = snapshot.currentSourceOrigin
        }
        if currentFolder != snapshot.currentFolder { currentFolder = snapshot.currentFolder }
        if playlist != snapshot.playlist { playlist = snapshot.playlist }
        if currentPlaylistIndex != snapshot.currentPlaylistIndex {
            currentPlaylistIndex = snapshot.currentPlaylistIndex
        }
        if phase != snapshot.phase { phase = snapshot.phase }
        if isPauseDesired != snapshot.isPauseDesired { isPauseDesired = snapshot.isPauseDesired }
        if position != snapshot.position { position = snapshot.position }
        if duration != snapshot.duration { duration = snapshot.duration }
        if videoAspectRatio != snapshot.videoAspectRatio {
            videoAspectRatio = snapshot.videoAspectRatio
        }
        if volume != snapshot.volume { volume = snapshot.volume }
        if isMuted != snapshot.isMuted { isMuted = snapshot.isMuted }
        if playbackSpeed != snapshot.playbackSpeed { playbackSpeed = snapshot.playbackSpeed }
        if audioTracks != snapshot.audioTracks { audioTracks = snapshot.audioTracks }
        if subtitleTracks != snapshot.subtitleTracks { subtitleTracks = snapshot.subtitleTracks }
        if selectedAudioTrack != snapshot.selectedAudioTrack {
            selectedAudioTrack = snapshot.selectedAudioTrack
        }
        if selectedSubtitleTrack != snapshot.selectedSubtitleTrack {
            selectedSubtitleTrack = snapshot.selectedSubtitleTrack
        }
        if chapters != snapshot.chapters { chapters = snapshot.chapters }
        if currentChapterID != snapshot.currentChapterID {
            currentChapterID = snapshot.currentChapterID
        }
        if audioDelay != snapshot.audioDelay { audioDelay = snapshot.audioDelay }
        if subtitleDelay != snapshot.subtitleDelay { subtitleDelay = snapshot.subtitleDelay }
        if bufferStatus != snapshot.bufferStatus { bufferStatus = snapshot.bufferStatus }
        if videoOutputStatus != snapshot.videoOutputStatus {
            videoOutputStatus = snapshot.videoOutputStatus
        }
        if displayOutputStatus != snapshot.displayOutputStatus {
            displayOutputStatus = snapshot.displayOutputStatus
        }
        if hardwareDecodingStatus != snapshot.hardwareDecodingStatus {
            hardwareDecodingStatus = snapshot.hardwareDecodingStatus
        }
        if audioOutputDevice != snapshot.audioOutputDevice {
            audioOutputDevice = snapshot.audioOutputDevice
        }
        if audioOutputDevices != snapshot.audioOutputDevices {
            audioOutputDevices = snapshot.audioOutputDevices
        }
        if videoAdjustments != snapshot.videoAdjustments {
            videoAdjustments = snapshot.videoAdjustments
        }
        if activeVideoFilters != snapshot.activeVideoFilters {
            activeVideoFilters = snapshot.activeVideoFilters
        }
        if recentDiagnosticMessages != snapshot.recentDiagnosticMessages {
            recentDiagnosticMessages = snapshot.recentDiagnosticMessages
        }
        if isFullscreen != snapshot.isFullscreen { isFullscreen = snapshot.isFullscreen }
        if pictureInPicture != snapshot.pictureInPicture {
            pictureInPicture = snapshot.pictureInPicture
        }
        if isSidebarVisible != snapshot.isSidebarVisible {
            isSidebarVisible = snapshot.isSidebarVisible
        }
        if repeatMode != snapshot.repeatMode { repeatMode = snapshot.repeatMode }
        if isShuffleEnabled != snapshot.isShuffleEnabled {
            isShuffleEnabled = snapshot.isShuffleEnabled
        }
        if coreFailureCode != snapshot.coreFailureCode {
            coreFailureCode = snapshot.coreFailureCode
        }
        if recoveryIssue != snapshot.recoveryIssue { recoveryIssue = snapshot.recoveryIssue }
        if trackSelectionPreferences != snapshot.trackSelectionPreferences {
            trackSelectionPreferences = snapshot.trackSelectionPreferences
        }
        if subtitleFallbackEncoding != snapshot.subtitleFallbackEncoding {
            subtitleFallbackEncoding = snapshot.subtitleFallbackEncoding
        }
        if shellError != snapshot.shellError { shellError = snapshot.shellError }
        if lastError != snapshot.lastError { lastError = snapshot.lastError }
    }
    public var isPaused: Bool { phase.isPaused }
    public var isLoading: Bool { phase.isLoading }
    public var currentURL: URL? { currentSource?.url }
    public var hasNextItem: Bool {
        guard let currentPlaylistIndex else { return false }
        return playlist.indices.contains(currentPlaylistIndex + 1)
    }
    public var hasPreviousItem: Bool {
        guard let currentPlaylistIndex else { return false }
        return playlist.indices.contains(currentPlaylistIndex - 1)
    }
}
