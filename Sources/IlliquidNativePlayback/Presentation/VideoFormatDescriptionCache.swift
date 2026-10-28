import CoreMedia
import CoreVideo
import Foundation

/// Retains one format description without retaining its image buffer.
/// Core Media revalidates the format on every lookup, including when the same
/// pixel buffer is reused with different format attachments.
final class VideoFormatDescriptionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: CMVideoFormatDescription?

    /// The creation closure runs under the cache lock. A failed creation leaves
    /// the previous description available for a later buffer that matches it.
    func formatDescription(
        for buffer: CVPixelBuffer,
        create: () throws -> CMVideoFormatDescription
    ) rethrows -> CMVideoFormatDescription {
        try lock.withLock {
            if let cached,
               CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: buffer) {
                return cached
            }
            let description = try create()
            cached = description
            return description
        }
    }

    func reset() {
        lock.withLock { cached = nil }
    }
}
