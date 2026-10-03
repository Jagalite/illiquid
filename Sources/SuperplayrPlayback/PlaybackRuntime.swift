import AppKit
import Foundation
import SuperplayrCore
import SuperplayrPlaybackCore

public typealias PictureInPictureRestoreRequestHandler =
    @MainActor @Sendable (@escaping @Sendable (Bool) -> Void) -> Void

@MainActor
public protocol PlaybackRuntime: AnyObject {
    var capabilities: PlaybackCapabilities { get }
    var eventHandler: (@MainActor @Sendable (PlaybackRuntimeEvent) -> Void)? { get set }

    func makeSurfaceHost() throws -> any PlaybackSurfaceHost
    /// Executes one core-issued operation. Every fallible asynchronous request
    /// must finish by publishing `.effectResult` with the unchanged context.
    func execute(_ request: PlaybackRuntimeEffectRequest)
    func frameStepTarget(direction: Int) async throws -> TimeInterval?
    func setVolume(_ value: Double)
    func setMuted(_ value: Bool)
    func setPlaybackSpeed(_ value: Double)
    func selectAudioOutputDevice(_ id: String?)
    func setAudioDelay(_ value: TimeInterval)
    func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences)
    func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding)
    func setHardwareDecodingPolicy(_ policy: HardwareDecodingPolicy)
    func setVideoScaleMode(_ mode: VideoScaleMode)
    func setVideoAspect(_ aspect: String?)
    func setVideoCrop(_ crop: String?)
    func setVideoRotation(_ rotation: Int)
    func setDeinterlace(_ enabled: Bool)
    func setVideoEqualizer(_ adjustments: VideoAdjustmentState)
    func setPictureInPictureActive(_ active: Bool)
    func setVideoColorSamplingEnabled(_ enabled: Bool)
    func setPictureInPictureRestoreRequestHandler(
        _ handler: PictureInPictureRestoreRequestHandler?
    )
    func execute(_ command: SuperplayrCore.PlaybackCommand) async throws
    func shutdown() async
}

public extension PlaybackRuntime {
    func frameStepTarget(direction: Int) async throws -> TimeInterval? {
        throw UnsupportedPlaybackCapabilityError("frame stepping")
    }
    func setVideoScaleMode(_ mode: VideoScaleMode) {}
    func setTrackSelectionPreferences(_ preferences: TrackSelectionPreferences) {}
    func setSubtitleFallbackEncoding(_ encoding: SubtitleFallbackEncoding) {}
    func setVideoColorSamplingEnabled(_ enabled: Bool) {}

    func setPictureInPictureRestoreRequestHandler(
        _ handler: PictureInPictureRestoreRequestHandler?
    ) {}
}
