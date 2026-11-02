import Foundation

/// Localized Finder-style filename ordering (`Episode 2` before `Episode 10`).
public enum NaturalFilenameOrdering {
    public static func areInIncreasingOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsName = lhs.lastPathComponent
        let rhsName = rhs.lastPathComponent

        switch lhsName.localizedStandardCompare(rhsName) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            // Supply a stable total ordering for names that compare equally under
            // the user's locale (for example, case-only filename differences).
            return lhs.path.compare(rhs.path, options: [.literal]) == .orderedAscending
        }
    }

    public static func sort(_ urls: [URL]) -> [URL] {
        sort(urls, by: { $0 })
    }

    /// Extract each filename once while retaining the original values. Folder
    /// playlists use this path too, so their dates and subtitle arrays survive
    /// sorting without reconstructing any items.
    static func sort<Element>(_ elements: [Element], by url: (Element) -> URL) -> [Element] {
        guard elements.count > 1 else { return elements }
        // Two elements need only one comparison: caching cannot save filename
        // extraction and would add an unnecessary temporary array.
        guard elements.count > 2 else {
            return elements.sorted { areInIncreasingOrder(url($0), url($1)) }
        }

        // Keep names and complete elements stationary while the sort moves only
        // integer indices through its temporary merge buffers.
        let names = elements.map { url($0).lastPathComponent }
        var order = Array(elements.indices)
        order.sort { lhs, rhs in
            switch names[lhs].localizedStandardCompare(names[rhs]) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                // Keep the same literal, original-path tie-break as the public
                // comparator. Most names differ, so do not precompute paths.
                return url(elements[lhs]).path.compare(
                    url(elements[rhs]).path, options: [.literal]
                ) == .orderedAscending
            }
        }
        return order.map { elements[$0] }
    }
}
