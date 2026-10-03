import Foundation
import SuperplayrPlaybackCore

/// Converts framework failures into stable typed facts. It deliberately owns
/// no retry counters, revisions, or recovery decisions; those live only in the
/// deterministic core's `RecoveryMachineState`.
struct NativeRecoveryController: Sendable {
    func videoFailure(
        error: Error,
        stream: FFmpegStreamInfo,
        hardwareWasConfigured: Bool,
        hardwareOutputWasObserved: Bool,
        consecutiveCount: Int = 1
    ) -> PlaybackFailure {
        if let poolError = error as? SoftwarePixelBufferPoolError {
            let classification: (String, Int64?, PlaybackFailure.Recoverability) =
                switch poolError {
                case let .creation(status):
                    ("softwarePixelBufferPoolCreationFailed", Int64(status), .fatal)
                case .exhausted:
                    ("softwarePixelBufferPoolExhausted", nil, .fatal)
                case .cancelled:
                    ("softwarePixelBufferPoolCancelled", nil, .cancelled)
                case let .allocation(status):
                    ("softwarePixelBufferAllocationFailed", Int64(status), .fatal)
                }
            return PlaybackFailure(
                domain: .resource,
                stage: .convert,
                stableCode: classification.0,
                nativeCode: classification.1,
                recoverability: classification.2,
                streamID: PlaybackStreamID(kind: .video, demuxIndex: stream.index),
                codecName: stream.codecName,
                hardwareWasConfigured: hardwareWasConfigured,
                hardwareOutputWasObserved: hardwareOutputWasObserved
            )
        }
        if let noProgress = error as? SoftwareVideoDecoderNoProgressError {
            return PlaybackFailure(
                domain: .videoDecode,
                stage: .receiveFrame,
                stableCode: "softwareVideoDecoderNoProgress",
                recoverability: .fallbackAvailable,
                streamID: PlaybackStreamID(kind: .video, demuxIndex: stream.index),
                codecName: stream.codecName,
                hardwareWasConfigured: false,
                hardwareOutputWasObserved: hardwareOutputWasObserved,
                consecutiveCount: noProgress.consecutiveErrors
            )
        }
        return PlaybackFailure(
            domain: .videoDecode,
            stage: .receiveFrame,
            stableCode: "videoDecodeFailed",
            nativeCode: (error as? FFmpegError).map { Int64($0.code) },
            recoverability: hardwareWasConfigured ? .fallbackAvailable : .fatal,
            streamID: PlaybackStreamID(kind: .video, demuxIndex: stream.index),
            codecName: stream.codecName,
            hardwareWasConfigured: hardwareWasConfigured,
            hardwareOutputWasObserved: hardwareOutputWasObserved,
            consecutiveCount: max(1, consecutiveCount)
        )
    }

    func presentationFailure(error: Error) -> PlaybackFailure {
        PlaybackFailure(
            domain: .presentation,
            stage: .enqueue,
            stableCode: error is PresentationRecoveryRequiredError
                ? "requiresFlushToResumeDecoding"
                : "videoPresentationFailed",
            nativeCode: (error as NSError).domain == NSOSStatusErrorDomain
                ? Int64((error as NSError).code)
                : nil,
            recoverability: .retryable
        )
    }
}
