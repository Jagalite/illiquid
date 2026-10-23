import Foundation

/// Validates a libass alpha mask and describes its compact, Swift-owned copy.
/// libass guarantees only `sourceStride * (height - 1) + width` source bytes:
/// the last row need not have padding, and padding in other rows may be uninitialized.
struct ASSBitmapCopyLayout: Equatable, Sendable {
    let width: Int
    let height: Int
    let sourceStride: Int
    let byteCount: Int
    let sourceByteCount: Int

    init?(width: Int, height: Int, sourceStride: Int) {
        guard width > 0, height > 0, sourceStride >= width else { return nil }
        let (byteCount, destinationOverflow) = width.multipliedReportingOverflow(by: height)
        let (lastRowOffset, offsetOverflow) = sourceStride.multipliedReportingOverflow(by: height - 1)
        let (sourceByteCount, sourceOverflow) = lastRowOffset.addingReportingOverflow(width)
        guard !destinationOverflow, !offsetOverflow, !sourceOverflow else { return nil }
        self.width = width
        self.height = height
        self.sourceStride = sourceStride
        self.byteCount = byteCount
        self.sourceByteCount = sourceByteCount
    }

    /// The caller keeps at least `sourceByteCount` readable source bytes alive
    /// until this method returns. The result owns its bytes independently.
    func copy(from source: UnsafeRawPointer) -> Data {
        if sourceStride == width || height == 1 {
            return Data(bytes: source, count: byteCount)
        }
        let destination = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<UInt8>.alignment
        )
        for row in 0..<height {
            destination.advanced(by: row * width).copyMemory(
                from: source.advanced(by: row * sourceStride),
                byteCount: width
            )
        }
        return Data(bytesNoCopy: destination, count: byteCount, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })
    }
}
