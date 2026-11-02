import CFFmpeg
import Foundation

extension PGSSubtitlePacket {
    /// Inspect acquisition headers without copying the compressed pixel payload.
    /// The result is a value; no packet pointer or payload storage escapes.
    static func isAcquisition(_ packet: FFmpegPacket) -> Bool {
        guard let pointer = packet.pointer,
              let bytes = pointer.pointee.data,
              pointer.pointee.size > 0 else { return false }
        return withExtendedLifetime(packet) {
            isAcquisition(UnsafeBufferPointer(start: bytes, count: Int(pointer.pointee.size)))
        }
    }
}

extension DVBSubtitlePacket {
    /// The demux packet owns the borrowed bytes until this synchronous scan ends.
    static func isAcquisition(_ packet: FFmpegPacket, compositionPageID: UInt16?) -> Bool {
        guard let pointer = packet.pointer,
              let bytes = pointer.pointee.data,
              pointer.pointee.size > 0 else { return false }
        return withExtendedLifetime(packet) {
            isAcquisition(UnsafeBufferPointer(start: bytes, count: Int(pointer.pointee.size)),
                          compositionPageID: compositionPageID)
        }
    }
}
