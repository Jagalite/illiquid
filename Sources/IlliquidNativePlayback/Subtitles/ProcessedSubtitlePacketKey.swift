import Foundation

/// Semantic identity of an embedded ASS cue, independent of FFmpeg ReadOrder.
struct ProcessedSubtitlePacketKey: Hashable, Sendable {
    let presentationMilliseconds: Int64
    let durationMilliseconds: Int64
    let data: Data

    init(presentationMilliseconds: Int64, durationMilliseconds: Int64, packetData: Data) {
        self.presentationMilliseconds = presentationMilliseconds
        self.durationMilliseconds = durationMilliseconds
        guard let comma = packetData.firstIndex(of: UInt8(ascii: ",")) else {
            data = packetData
            return
        }

        // FFmpeg can assign a new ReadOrder when a seek decodes the same cue.
        // Only the bytes following that first field belong to its identity.
        let payload = packetData[packetData.index(after: comma)...]
        if packetData.startIndex == 0, payload.startIndex <= 32, payload.count >= 64 {
            // The decoder creates a complete, owned Data for each ASS packet.
            // Retaining its slice lets the main and PiP dedupers share those
            // bytes; Data(payload) would allocate and copy them per pipeline.
            // Zero-based indexing cannot reveal spare capacity or a hidden
            // trailing slice: recheck this provenance if event producers change.
            data = payload
        } else {
            // Keep tiny bodies compact and avoid pinning a large discarded
            // prefix or an already-offset input's backing storage.
            data = Data(payload)
        }
    }
}
