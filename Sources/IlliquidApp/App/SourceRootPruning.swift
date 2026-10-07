import Foundation

/// Lexical root pruning for normalized absolute folder paths. Check only each
/// path's ancestors, rather than comparing every pair of library folders.
enum SourceRootPruning {
    static func minimal(_ paths: [String]) -> [String] {
        let candidates = Set(paths)
        if candidates.contains("/") { return ["/"] }
        return candidates.filter { path in
            var ancestor = path[...]
            while let slash = ancestor.lastIndex(of: "/"), slash != ancestor.startIndex {
                ancestor = ancestor[..<slash]
                if candidates.contains(String(ancestor)) { return false }
            }
            return true
        }.sorted()
    }
}
