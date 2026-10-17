import Foundation

/// Recompute each affected folder once, after its affected descendants. A batch
/// can contain many siblings; walking every sibling back to the root repeatedly
/// rescans the same child sets on the main actor.
enum SourceMediaPresenceRecomputation {
    static func orderedPaths<Paths: Sequence>(
        _ folders: Paths, roots: [String]
    ) -> [String] where Paths.Element == String {
        var affected: Set<String> = []
        for folder in folders {
            var path = folder
            while roots.contains(where: { root in
                path == root || path.hasPrefix(root == "/" ? root : root + "/")
            }) {
                // A previous walk already included this path and its watched
                // ancestors. Start with an empty set so this also holds when a
                // parent is itself one of the changed folders.
                guard affected.insert(path).inserted else { break }
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                guard parent != path else { break }
                path = parent
            }
        }
        // Swift path keys compare canonically equivalent Unicode spellings as
        // equal. Character counts preserve ancestor order even if a stored
        // parent uses a different normalization from its child. Cache the
        // counts so sorting does not repeatedly scan each path's graphemes.
        return affected.map { (path: $0, length: $0.count) }
            .sorted { $0.length > $1.length }
            .map { $0.path }
    }
}
