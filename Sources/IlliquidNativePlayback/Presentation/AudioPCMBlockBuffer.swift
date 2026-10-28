import CoreMedia
import Foundation

/// Transfers immutable PCM ownership to a read-only audio presentation buffer.
/// Callers must not write through the block buffer's mutable CoreMedia APIs.
enum AudioPCMBlockBuffer {
    static func make(
        _ data: Data,
        allocator: CFAllocator? = kCFAllocatorDefault
    ) throws -> CMBlockBuffer {
        guard !data.isEmpty else {
            throw PresentationError("PCM block must not be empty")
        }

        // Immutable NSData supplies a stable pointer for the owner's lifetime.
        // Heap-backed Data normally shares storage; Foundation materializes tiny
        // inline values safely. No Data.withUnsafeBytes pointer escapes a borrow.
        let owner = data as NSData
        var source = CMBlockBufferCustomBlockSource()
        source.version = kCMBlockBufferCustomBlockSourceVersion
        source.refCon = Unmanaged.passUnretained(owner).toOpaque()
        source.AllocateBlock = { refCon, size in
            guard let refCon else { return nil }
            let reference = Unmanaged<NSData>.fromOpaque(refCon)
            let owner = reference.takeUnretainedValue()
            guard size == owner.length else { return nil }
            // Acquire ownership only when CoreMedia acquires the memory block.
            // A creation failure before this callback has nothing to release.
            _ = reference.retain()
            return UnsafeMutableRawPointer(mutating: owner.bytes)
        }
        source.FreeBlock = { refCon, _, _ in
            guard let refCon else { return }
            Unmanaged<NSData>.fromOpaque(refCon).release()
        }

        var buffer: CMBlockBuffer?
        let status = withExtendedLifetime(owner) {
            CMBlockBufferCreateWithMemoryBlock(
                allocator: allocator,
                memoryBlock: nil,
                blockLength: owner.length,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: &source,
                offsetToData: 0,
                dataLength: owner.length,
                // AllocateBlock must retain the owner before its local lifetime
                // ends; deferred allocation would leave refCon dangling.
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &buffer
            )
        }
        try checkOSStatus(status, operation: "Create audio block buffer")
        guard let buffer else {
            throw PresentationError("Audio block buffer was not created")
        }
        return buffer
    }
}
