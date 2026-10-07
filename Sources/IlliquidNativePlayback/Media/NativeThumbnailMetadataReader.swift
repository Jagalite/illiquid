import Foundation

/// One physical metadata probe; a blocked mount cannot accumulate native workers
/// or hold callers/old folder snapshots after cancellation or timeout.
public final class NativeThumbnailMetadataReader: Sendable {
    private let worker = ThumbnailBlockingReader<Double>()
    public init() {}
    public func duration(of url: URL) async -> Double? {
        let interrupt = FFmpegInterruptState()
        let token = FFmpegInputEffectToken(rawValue: 1)
        defer { _ = interrupt.requestCancellation(for: token) }
        return await withTaskCancellationHandler {
            await worker.read {
                interrupt.begin(token)
                defer { interrupt.end(token) }
                guard let input = try? FFmpegDemuxer(url: url, interruptState: interrupt),
                      !interrupt.shouldInterrupt(), !input.mediaInfo.videoStreams.isEmpty,
                      input.mediaInfo.duration.isFinite, input.mediaInfo.duration > 0 else { return nil }
                return input.mediaInfo.duration
            }
        } onCancel: { _ = interrupt.requestCancellation(for: token) }
    }
}
