import CFFmpeg
import Foundation
import IlliquidCore

public enum CaptionReadError: Error, LocalizedError, Equatable {
    case localFileRequired, textTrackRequired, externalFileUnavailable, sourceChanged, trackUnavailable, decoderUnavailable

    public var errorDescription: String? {
        switch self {
        case .localFileRequired: "Caption navigation requires a local media file."
        case .textTrackRequired: "This subtitle track contains images, not searchable text. OCR is not enabled."
        case .externalFileUnavailable: "The external subtitle file is unavailable. Load it again, then retry."
        case .sourceChanged: "The media or subtitle file changed while its captions were being read. Retry to rebuild the index."
        case .trackUnavailable: "The selected subtitle track is no longer available."
        case .decoderUnavailable: "This text subtitle format cannot be decoded for caption navigation."
        }
    }
}

/// Separate, on-demand input: never seeks the playback demuxer or decodes video.
/// The shared preparation executor retains physical admission after cancellation
/// until a blocked filesystem operation actually exits. Partial indexes are
/// explicitly labeled; bitmap subtitles never trigger OCR or network requests.
public struct NativeCaptionDocument: Sendable {
    public let url: URL
    public let assData: Data
    public init(url: URL, assData: Data) { self.url = url; self.assData = assData }
}

public enum NativeCaptionReader {
    /// Search the actual loaded sidecar bytes, not a possibly edited disk copy.
    public static func read(_ document: NativeCaptionDocument) async throws -> CaptionIndex {
        try await SourcePreparationExecutor.shared.performWhenAvailable { check in
            try check()
            let result = CaptionText.parseASSDocument(document.assData)
            try check()
            return result
        }
    }

    public static func read(_ request: CaptionSourceRequest) async throws -> CaptionIndex {
        let signal = FFmpegInputCancellationSignal()
        return try await withTaskCancellationHandler {
            do {
                return try await SourcePreparationExecutor.shared.performWhenAvailable { check in
                    try check()
                    try signal.checkCancellation()
                    guard request.mediaURL.isFileURL else { throw CaptionReadError.localFileRequired }
                    guard request.subtitleTrack.kind == .subtitle else { throw CaptionReadError.trackUnavailable }
                    let source = request.subtitleTrack.isExternal ? request.externalURL : request.mediaURL
                    guard let source, source.isFileURL else { throw CaptionReadError.externalFileUnavailable }
                    guard let before = NativeFileContentVersion.read(source) else {
                        throw CaptionReadError.externalFileUnavailable
                    }
                    if !request.subtitleTrack.isExternal, let expected = request.mediaVersion, before != expected {
                        throw CaptionReadError.sourceChanged
                    }
                    let index: CaptionIndex
                    if request.subtitleTrack.isExternal {
                        guard ["srt", "vtt", "ass", "ssa"].contains(source.pathExtension.lowercased()) else {
                            throw CaptionReadError.textTrackRequired
                        }
                        let data = try SubtitlePipeline.prepareExternalData(url: source,
                            maximumBytes: 16 * 1_024 * 1_024, fallbackEncoding: request.fallbackEncoding)
                        try check()
                        index = CaptionText.parseASSDocument(data)
                    } else {
                        index = try readEmbedded(request, signal: signal, check: check)
                    }
                    try check()
                    try signal.checkCancellation()
                    guard NativeFileContentVersion.read(source) == before else { throw CaptionReadError.sourceChanged }
                    return index
                }
            } catch {
                // Logical timeouts must also interrupt a native read. Its input
                // remains owned by the worker until that read returns.
                signal.requestCancellation()
                throw error
            }
        } onCancel: { signal.requestCancellation() }
    }

    private static func readEmbedded(_ request: CaptionSourceRequest,
                                     signal: FFmpegInputCancellationSignal,
                                     check: @Sendable () throws -> Void) throws -> CaptionIndex {
        let input = try FFmpegInputExecutor(url: request.mediaURL, openTimeout: 8, cancellationSignal: signal)
        let registration = signal.register { [weak input] in _ = input?.cancelActiveOperation() }
        defer { signal.unregister(registration) }
        guard request.subtitleTrack.id > 0,
              let streamIndex = Int32(exactly: request.subtitleTrack.id - 1),
              let stream = input.mediaInfo.streams.first(where: { $0.index == streamIndex && $0.kind == .subtitle }) else {
            throw CaptionReadError.trackUnavailable
        }
        guard stream.subtitleCapability == .text else { throw CaptionReadError.textTrackRequired }
        guard let parameters = try input.copyCodecParameters(streamIndex: streamIndex) else {
            throw CaptionReadError.trackUnavailable
        }
        guard let decoder = try parameters.withUnsafePointer({ try SubtitleDecoder(parameters: $0, stream: stream) }) else {
            throw CaptionReadError.decoderUnavailable
        }
        let origin = input.mediaInfo.startTime
        guard origin.isFinite else { throw CaptionReadError.sourceChanged }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var cues: [CaptionCue] = []
        var packetBytes = 0
        var textBytes = 0
        var packetCount = 0
        var complete = true
        scan: while true {
            try check()
            try signal.checkCancellation()
            // Bound CPU, storage traffic and output independently. No timeout is
            // presented as a guarantee that a blocked OS call has been stopped.
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  packetCount < 2_000_000, packetBytes < 2 * 1_024 * 1_024 * 1_024 else {
                complete = false
                break
            }
            guard let packet = try input.readPacket(generation: 0) else { break }
            packetCount += 1
            packetBytes += max(0, packet.byteCount)
            guard packet.streamIndex == streamIndex else { continue }
            for event in try decoder.decode(packet) {
                guard event.assData.count <= 65_536,
                      let value = String(data: event.assData, encoding: .utf8) else {
                    complete = false
                    continue
                }
                let text = CaptionText.fromASSPacket(value)
                let start = event.presentationSeconds - origin
                guard let cue = CaptionCue(id: cues.count, start: start,
                    end: start + event.durationSeconds, text: text) else { continue }
                guard cues.count < CaptionIndex.maximumCues,
                      text.utf8.count <= CaptionIndex.maximumTextBytes - textBytes else {
                    complete = false
                    break scan
                }
                textBytes += text.utf8.count
                cues.append(cue)
            }
        }
        return CaptionIndex(cues: cues, isComplete: complete)
    }
}

/// Cheap local identity inspection shared by acknowledged automation requests.
/// Call only from a bounded preparation worker, never from a UI projection.
public enum NativeMediaInspection {
    public static func contentVersion(of url: URL) -> MediaContentVersion? {
        NativeFileContentVersion.read(url)
    }
}
