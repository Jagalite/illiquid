import CoreMedia
import CoreVideo
import Foundation

/// Keeps one immutable format description, never the image buffer or a sample.
/// Core Media validates the complete image-buffer compatibility contract on each
/// lookup, including attachment additions/removals and applicable row stride.
/// The lock also serializes reset against enqueue on another presentation queue.
final class VideoFormatDescriptionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: CMVideoFormatDescription?

    /// The synchronous factory must not reenter this cache.
    func resolve(
        for imageBuffer: CVPixelBuffer,
        create: () throws -> CMVideoFormatDescription
    ) rethrows -> CMVideoFormatDescription {
        lock.lock()
        defer { lock.unlock() }
        if let cached,
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: imageBuffer) {
            return cached
        }
        // Publish only a successfully created description. A failed creation
        // leaves the previous entry available for a later compatible frame.
        let next = try create()
        cached = next
        return next
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}
