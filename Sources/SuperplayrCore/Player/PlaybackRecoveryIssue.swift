import Foundation

/// Persistent product recovery context, independent of transient OSD messages.
public struct PlaybackRecoveryIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message
        case unavailableRestore(isFolder: Bool)
        case failedSource(canSkip: Bool)
    }

    public let kind: Kind
    public let message: String
    public let source: URL?
    public let diagnosticCode: String?

    public init(kind: Kind, message: String, source: URL? = nil) {
        self.kind = kind
        self.message = message
        self.source = source
        diagnosticCode = nil
    }

    public init(coreFailureCode code: String) {
        kind = .message
        source = nil
        diagnosticCode = code
        switch code {
        case "nativeSubtitleReadFailed", "subtitlePipelinePreparationFailed", "subtitlePipelineAdmissionTimedOut":
            message = "Subtitles could not be read. Try another subtitle track or file."
        case "nativeSeekFailed":
            message = "The player could not seek to that position."
        case "videoDecodeFailed", "softwareVideoDecoderNoProgress":
            message = "Video decoding could not continue."
        case "nativeDemuxReadFailed":
            message = "The media file could not be read. Check that it is still available."
        default:
            message = "Playback encountered a problem. Copy the details for troubleshooting."
        }
    }

    public var diagnosticText: String {
        [message, diagnosticCode.map { "Code: \($0)" }, source?.absoluteString]
            .compactMap { $0 }.joined(separator: "\n")
    }
}
