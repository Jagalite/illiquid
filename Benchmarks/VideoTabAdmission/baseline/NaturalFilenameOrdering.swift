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
        urls.sorted(by: areInIncreasingOrder)
    }
}
