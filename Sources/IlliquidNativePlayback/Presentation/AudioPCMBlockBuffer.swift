import CoreMedia
import Foundation

/// Gives CoreMedia ownership of immutable PCM without a second payload copy.
/// The returned block is for read-only presentation; callers must not modify it
/// through CoreMedia's mutable byte APIs.
enum AudioPCMBlockBuffer {
    static func make(_ data: Data) throws -> CMBlockBuffer {
        guard !data.isEmpty else {
            throw PresentationError("Audio block buffer cannot be empty")
        }

        // NSData guarantees that its immutable bytes stay valid for its entire
        // lifetime. A pointer borrowed from Data.withUnsafeBytes cannot escape
        // that closure, even when another Data value retains the same storage.
        let owner = data as NSData
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: { context, length in
                guard let context else { return nil }
                let owner = Unmanaged<NSData>.fromOpaque(context).takeUnretainedValue()
                guard length == owner.length else { return nil }
                // Acquire the reference only when CoreMedia acquires the
                // memory. Failure before allocation has no retain to unwind;
                // every acquired block is balanced by FreeBlock.
                _ = Unmanaged.passRetained(owner)
                return UnsafeMutableRawPointer(mutating: owner.bytes)
            },
            FreeBlock: { context, _, _ in
                guard let context else { return }
                Unmanaged<NSData>.fromOpaque(context).release()
            },
            refCon: Unmanaged.passUnretained(owner).toOpaque()
        )
        var blockBuffer: CMBlockBuffer?
        let status = withExtendedLifetime(owner) {
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: owner.length,
                blockAllocator: nil,
                customBlockSource: &source,
                offsetToData: 0,
                dataLength: owner.length,
                // The borrowed refCon is valid during this call. AllocateBlock
                // must run now and retain it before the local owner can expire.
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )
        }
        try checkOSStatus(status, operation: "Create audio block buffer")
        guard let blockBuffer else {
            throw PresentationError("Audio block buffer was not created")
        }
        return blockBuffer
    }
}
