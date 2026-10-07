import Foundation

/// The native subtitle source is explicit so `nil` never has to mean both
/// "automatic embedded selection" and "no embedded packet ingress".
enum NativeSubtitleSource: Equatable, Sendable {
    case off
    case automaticEmbedded
    case embedded(streamIndex: Int32)
    case external(url: URL)
    case externalBitmap(url: URL, streamIndex: Int32)

    var acceptsEmbeddedPackets: Bool {
        switch self {
        case .automaticEmbedded, .embedded:
            true
        case .off, .external, .externalBitmap:
            false
        }
    }

    func resolve(in mediaInfo: FFmpegMediaInfo) -> FFmpegStreamInfo? {
        let requestedIndex: Int32?
        switch self {
        case .off, .external, .externalBitmap:
            return nil
        case .automaticEmbedded:
            requestedIndex = mediaInfo.selectedSubtitleIndex
        case let .embedded(streamIndex):
            requestedIndex = streamIndex
        }
        guard let requestedIndex else { return nil }
        return mediaInfo.subtitleStreams.first {
            $0.index == requestedIndex && $0.subtitleCapability?.isPlayable == true
        }
    }
}
