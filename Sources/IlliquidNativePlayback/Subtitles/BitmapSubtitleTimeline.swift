import CoreGraphics
import Foundation

enum PGSSubtitlePacket {
    static func isAcquisition(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
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
}

enum DVBSubtitlePacket {
    /// FFmpeg supplies DVB segments without the PES data-identifier prefix.
    /// Only a matching composition page in acquisition/mode-change state can
    /// replace decoder history; ancillary pages must not reset a selected page.
    static func isAcquisition(_ data: Data, compositionPageID: UInt16?) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
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
}

struct NativeBitmapSubtitleRegion: Sendable {
    let pixels: Data
    let frame: CGRect
    let isForced: Bool
}

/// A display set replaces the previous set, including an empty clear event.
/// A nil duration remains active until the next set (PGS semantics).
struct NativeBitmapSubtitleComposition: Sendable {
    let regions: [NativeBitmapSubtitleRegion]
    let canvasSize: CGSize
    let duration: Double?
    let memoryLease: SubtitleMemoryBudget.Lease?

    var byteCount: Int { regions.reduce(0) { $0 + $1.pixels.count } }

    func renderedRegions(in viewport: CGRect, forcedOnly: Bool = false) -> [ASSRenderedRegion] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        let scaleX = viewport.width / canvasSize.width
        let scaleY = viewport.height / canvasSize.height
        return regions.filter { !forcedOnly || $0.isForced }.map { region in
            ASSRenderedRegion(bitmap: region.pixels, color: 0,
                frame: CGRect(x: viewport.minX + region.frame.minX * scaleX,
                              y: viewport.minY + region.frame.minY * scaleY,
                              width: region.frame.width * scaleX, height: region.frame.height * scaleY),
                stride: Int(region.frame.width) * 4, bitmapSize: region.frame.size,
                isPremultipliedBGRA: true, memoryLease: memoryLease)
        }
    }
}

struct BitmapSubtitleTimeline: Sendable {
    private struct Entry: Sendable {
        let start: Double
        let composition: NativeBitmapSubtitleComposition
    }

    private var entries: [Entry] = []
    private(set) var generation = 0
    private(set) var revision: UInt64 = 0
    private(set) var retainedBytes = 0
    let maximumEntries: Int
    let maximumBytes: Int

    init(maximumEntries: Int = 128, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    mutating func reset(generation: Int? = nil) {
        entries.removeAll()
        retainedBytes = 0
        if let generation { self.generation = generation }
        revision &+= 1
    }

    @discardableResult
    mutating func insert(_ composition: NativeBitmapSubtitleComposition, at start: Double, generation: Int) -> Bool {
        guard generation == self.generation else { return true } // Retired delivery is harmless.
        guard start.isFinite, composition.canvasSize.width > 0, composition.canvasSize.height > 0,
              composition.canvasSize.width.isFinite, composition.canvasSize.height.isFinite,
              composition.duration.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
        let previous = entries.firstIndex { $0.start == start }
        let nextBytes = retainedBytes - (previous.map { entries[$0].composition.byteCount } ?? 0) + composition.byteCount
        guard nextBytes <= maximumBytes,
              previous != nil || entries.count < maximumEntries else { return false }
        if let previous { entries.remove(at: previous) }
        entries.append(Entry(start: start, composition: composition))
        entries.sort { $0.start < $1.start }
        retainedBytes = nextBytes
        revision &+= 1
        return true
    }

    func composition(at seconds: Double) -> (start: Double, value: NativeBitmapSubtitleComposition)? {
        guard seconds.isFinite, let entry = entries.last(where: { $0.start <= seconds }) else { return nil }
        if let duration = entry.composition.duration, seconds >= entry.start + duration { return nil }
        return (entry.start, entry.composition)
    }

    mutating func prune(before seconds: Double) {
        // Keep the final set preceding the cutoff: an indefinite PGS display
        // can span an arbitrarily long silent interval before its clear event.
        guard let lastPastIndex = entries.lastIndex(where: { $0.start <= seconds }), lastPastIndex > 0 else { return }
        for entry in entries[..<lastPastIndex] { retainedBytes -= entry.composition.byteCount }
        entries.removeFirst(lastPastIndex)
    }
}
