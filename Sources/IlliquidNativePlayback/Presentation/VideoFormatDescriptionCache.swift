import CoreMedia
import CoreVideo
import Foundation

/// Retains at most one immutable format description, never a decoded image buffer.
/// CoreMedia checks the current dimensions, pixel format, row stride, and common
/// attachments on every lookup, including when a pooled pixel buffer is reused.
final class VideoFormatDescriptionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: CMVideoFormatDescription?

    /// The factory runs synchronously under the lock only on a miss. It must
    /// describe imageBuffer and must not reenter this cache.
    func description(
        for imageBuffer: CVPixelBuffer,
        create: () throws -> CMVideoFormatDescription
    ) rethrows -> CMVideoFormatDescription {
        try lock.withLock {
            if let cached,
               CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: imageBuffer) {
                return cached
            }
            // Keep the previous entry if creation fails. A returned description
            // remains alive independently of later replacement or removeAll().
            let created = try create()
            cached = created
            return created
        }
    }

    func removeAll() {
        lock.withLock { cached = nil }
    }
}
