import Foundation

public enum NativeThumbnailDiskCache {
    public static let maximumEncodedImageBytes = 16 * 1024 * 1024
    public nonisolated static func readEncodedImage(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            // Reject existing oversized files before allocating their contents.
            let initialByteCount = try handle.seekToEnd()
            guard initialByteCount <= UInt64(maximumEncodedImageBytes) else { return nil }
            try handle.seek(toOffset: 0)
            var data = Data()
            // Multi-chunk reads can reserve their validated size rather than
            // repeatedly grow and copy storage. Keep one-chunk reads on the
            // existing path; reserving can round their capacity up needlessly.
            if initialByteCount > 64 * 1024 {
                data.reserveCapacity(Int(initialByteCount))
            }
            // Bound the read itself as well: the file may grow after the size
            // check. Small chunks avoid reserving 16 MiB for every tiny JPEG.
            while data.count <= maximumEncodedImageBytes {
                let count = min(64 * 1024, maximumEncodedImageBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
                data.append(chunk)
            }
            return nil
        } catch { return nil }
    }
}
