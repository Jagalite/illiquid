import Foundation
import SuperplayrCore
import SuperplayrPlaybackCore

public struct PlayerSessionIdentity: Hashable, Sendable {
    public let source: MediaSource
    public let generation: UInt64

    public init(source: MediaSource, generation: UInt64) {
        self.source = source
        self.generation = generation
    }
}

public struct PlaybackRuntimeLoadRequest: Equatable, Sendable {
    public let media: MediaLoadRequest
    public let identity: PlayerSessionIdentity

    public init(media: MediaLoadRequest, identity: PlayerSessionIdentity) {
        self.media = media
        self.identity = identity
    }
}

/// Core operation plus the product-only data needed by its native executor.
/// The deterministic effect remains the authority and the optional load value
/// only resolves its opaque source identity into an authorized media request.
public struct PlaybackRuntimeEffectRequest: Equatable, Sendable {
    public let effect: PlaybackEffect
    public let load: PlaybackRuntimeLoadRequest?
    public let externalResourceURL: URL?

    public init(
        effect: PlaybackEffect,
        load: PlaybackRuntimeLoadRequest? = nil,
        externalResourceURL: URL? = nil
    ) {
        self.effect = effect
        self.load = load
        self.externalResourceURL = externalResourceURL
    }
}

public struct PlayerTrackSnapshot: Equatable, Sendable {
    public let hasVideo: Bool
    public let tracks: [MediaTrack]
    public let selectedAudioID: Int64?
    public let selectedSubtitleID: Int64?

    public init(
        hasVideo: Bool,
        tracks: [MediaTrack],
        selectedAudioID: Int64?,
        selectedSubtitleID: Int64?
    ) {
        self.hasVideo = hasVideo
        self.tracks = tracks
        self.selectedAudioID = selectedAudioID
        self.selectedSubtitleID = selectedSubtitleID
    }
}

public struct PlayerDecoderStatus: Equatable, Sendable {
    public let name: String?
    public let isHardwareDecoded: Bool
    public let didFallbackToSoftware: Bool

    public init(
        name: String?,
        isHardwareDecoded: Bool,
        didFallbackToSoftware: Bool = false
    ) {
        self.name = name
        self.isHardwareDecoded = isHardwareDecoded
        self.didFallbackToSoftware = didFallbackToSoftware
    }
}

public enum PlaybackRuntimeEventPayload: Equatable, Sendable {
    case effectResult(PlaybackEffectResult)
    case started
    case loaded
    case mediaVersionObserved(MediaContentVersion?)
    case prerollReady
    case seekCompleted
    /// The first video sample was submitted to the renderer without an
    /// immediate failure. This does not prove that a frame became visible.
    case firstFrameSubmitted
    case positionChanged(TimeInterval)
    case durationChanged(TimeInterval)
    case pauseChanged(Bool)
    case bufferingChanged(BufferStatus)
    case synchronization(SynchronizationCoreEvent)
    case tracksChanged(PlayerTrackSnapshot)
    case decoderChanged(PlayerDecoderStatus)
    case videoChanged(VideoOutputStatus, aspectRatio: Double?)
    case videoColorSampleChanged(VideoColorSample)
    case displayChanged(DisplayOutputStatus)
    case volumeChanged(Double)
    case muteChanged(Bool)
    case speedChanged(Double)
    case audioDevicesChanged([AudioOutputDevice])
    case audioOutputSelectionFailed(String)
    /// The system discarded queued audio or changed its output configuration.
    /// Re-preroll from the current media clock under core seek authority.
    case audioOutputChanged(TimeInterval)
    case chaptersChanged([Chapter], currentID: Int64?)
    case audioDelayChanged(TimeInterval)
    case subtitleDelayChanged(TimeInterval)
    case videoAdjustmentsChanged(VideoAdjustmentState)
    case pictureInPictureChanged(PictureInPictureState)
    case transportRequested(playing: Bool)
    case relativeSeekRequested(TimeInterval)
    case endOfFile
    case stopped
    case typedFailure(PlaybackFailure)
    case failed(String)
    case diagnostic(String)
    case shutdownCompleted
}

public struct PlaybackRuntimeEvent: Equatable, Sendable {
    public let identity: PlayerSessionIdentity?
    public let payload: PlaybackRuntimeEventPayload

    public init(identity: PlayerSessionIdentity?, payload: PlaybackRuntimeEventPayload) {
        self.identity = identity
        self.payload = payload
    }
}

public struct PlaybackRuntimeEventGate: Sendable {
    public private(set) var activeIdentity: PlayerSessionIdentity?

    public init(activeIdentity: PlayerSessionIdentity? = nil) {
        self.activeIdentity = activeIdentity
    }

    public mutating func activate(_ identity: PlayerSessionIdentity?) {
        activeIdentity = identity
    }

    public func accepts(_ event: PlaybackRuntimeEvent) -> Bool {
        guard let eventIdentity = event.identity else {
            switch event.payload {
            case .effectResult, .diagnostic, .pictureInPictureChanged, .shutdownCompleted,
                 .audioDevicesChanged, .audioOutputSelectionFailed:
                return true
            default: return activeIdentity == nil
            }
        }
        return eventIdentity == activeIdentity
    }
}
