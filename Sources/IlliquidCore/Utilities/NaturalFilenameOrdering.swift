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
        guard urls.count > 1 else { return urls }
        // A single comparison already extracts each name only once.
        if urls.count == 2 { return urls.sorted(by: areInIncreasingOrder) }

        // URL name extraction is repeated for both operands of every comparison.
        // Retain each name only for this sort; paths are still read only on ties.
        var entries = urls.map { (url: $0, name: $0.lastPathComponent) }
        entries.sort { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.url.path.compare(rhs.url.path, options: [.literal]) == .orderedAscending
            }
        }
        return entries.map(\.url)
    }
}
