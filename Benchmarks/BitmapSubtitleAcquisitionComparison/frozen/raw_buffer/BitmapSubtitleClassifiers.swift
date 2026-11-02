import CoreGraphics
import Foundation

enum PGSSubtitlePacket {
    static func isAcquisition(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            isAcquisition(raw.bindMemory(to: UInt8.self))
        }
    }

    static func isAcquisition(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var offset = 0
        while bytes.count - offset >= 3 {
            let kind = bytes[offset]
            let length = Int(bytes[offset + 1]) * 256 + Int(bytes[offset + 2])
            offset += 3
            guard length <= bytes.count - offset else { return false }
            if kind == 0x16, length >= 11, bytes[offset + 7] & 0xC0 != 0 { return true }
            offset += length
        }
        return false
    }
}

enum DVBSubtitlePacket {
    /// FFmpeg supplies DVB segments without the PES data-identifier prefix.
    /// Only a matching composition page in acquisition/mode-change state can
    /// replace decoder history; ancillary pages must not reset a selected page.
    static func isAcquisition(_ data: Data, compositionPageID: UInt16?) -> Bool {
        data.withUnsafeBytes { raw in
            isAcquisition(raw.bindMemory(to: UInt8.self), compositionPageID: compositionPageID)
        }
    }

    static func isAcquisition(_ bytes: UnsafeBufferPointer<UInt8>, compositionPageID: UInt16?) -> Bool {
        var offset = 0
        while bytes.count - offset >= 6 {
            guard bytes[offset] == 0x0F else { return false }
            let kind = bytes[offset + 1]
            let pageID = UInt16(bytes[offset + 2]) * 256 + UInt16(bytes[offset + 3])
            let length = Int(bytes[offset + 4]) * 256 + Int(bytes[offset + 5])
            offset += 6
            guard length <= bytes.count - offset else { return false }
            if kind == 0x10, length >= 2,
               compositionPageID == nil || compositionPageID == pageID {
                let state = (bytes[offset + 1] >> 2) & 3
                if state == 1 || state == 2 { return true }
            }
            offset += length
        }
        return false
    }
}
