import Foundation

/// Decode-worker observations, excluding actor debounce and queue wait.
/// A caller deadline may precede this record if native work is still returning.
struct ThumbnailDecodeObservation: Codable, Sendable {
    var target: Double
    var reusedContext = false
    var continuedForward = false
    var packets = 0
    var frames = 0
    var discardedBeforeOutput = 0
    var usedEOFFallback = false
    var selectedFrameSeconds: Double?
    var openMilliseconds: Double = 0
    var seekMilliseconds: Double = 0
    var decodeMilliseconds: Double = 0
    var imageMilliseconds: Double = 0
    var totalMilliseconds: Double = 0
    var imageCreated = false
    var cancelled = false
    var failure: String?

    var summary: String {
        "target=\(target) reused=\(reusedContext) forward=\(continuedForward) "
            + "packets=\(packets) output-frames=\(frames) discarded-before-output=\(discardedBeforeOutput) open-ms=\(openMilliseconds) "
            + "seek-ms=\(seekMilliseconds) decode-ms=\(decodeMilliseconds) "
            + "image-ms=\(imageMilliseconds) total-ms=\(totalMilliseconds) "
            + "image=\(imageCreated) cancelled=\(cancelled) failure=\(failure ?? "none")"
    }
}
