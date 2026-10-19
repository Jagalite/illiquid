import Foundation

/// A per-trim snapshot that produces victims in the disk cache's existing order.
/// Heapification is linear in eligible entries; removing a small prefix does
/// not require sorting the rest of a full cache.
struct ThumbnailDiskEvictionHeap {
    struct Entry: Equatable {
        let filename: String
        let used: Date
        let background: Bool
    }

    private var entries: [Entry]

    init(_ entries: [Entry]) {
        self.entries = entries
        guard entries.count > 1 else { return }
        for parent in stride(from: entries.count / 2 - 1, through: 0, by: -1) {
            siftDown(from: parent)
        }
    }

    mutating func popFirst() -> Entry? {
        guard !entries.isEmpty else { return nil }
        let last = entries.removeLast()
        guard !entries.isEmpty else { return last }
        let first = entries[0]
        entries[0] = last
        siftDown(from: 0)
        return first
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while parent < entries.count / 2 {
            let left = parent * 2 + 1
            let right = left + 1
            var child = left
            if right < entries.count, Self.precedes(entries[right], entries[left]) {
                child = right
            }
            guard Self.precedes(entries[child], entries[parent]) else { return }
            entries.swapAt(parent, child)
            parent = child
        }
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.background != rhs.background { return lhs.background }
        if lhs.used != rhs.used { return lhs.used < rhs.used }
        return lhs.filename < rhs.filename
    }
}
