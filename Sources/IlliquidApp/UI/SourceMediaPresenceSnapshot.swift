/// A repair cursor only consults cached directories beneath its scan root.
/// Retain that subset for the job instead of copying the entire source library.
/// Paths use the scanner's normalized folder-identity namespace.
enum SourceMediaPresenceSnapshot {
    static func reusableResults(
        under root: String,
        results: [String: Bool],
        isReusable: (String) -> Bool
    ) -> [String: Bool] {
        let prefix = root == "/" ? root : root + "/"
        return results.filter { entry in
            (entry.key == root || entry.key.hasPrefix(prefix)) && isReusable(entry.key)
        }
    }
}
