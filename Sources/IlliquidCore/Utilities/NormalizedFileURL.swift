import Foundation

/// Pure path identities for prepared local URLs. Filesystem resolution belongs
/// at bounded preparation boundaries, never in UI comparison or persistence keys.
public enum NormalizedFileURL {
    /// Standardizes URL path segments and Unicode without querying the filesystem.
    /// Call `resolveFilesystemIdentity` during preparation before storing new URLs.
    public static func normalize(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let lexical = url.absoluteURL.standardized
        return URL(fileURLWithPath: lexical.path.precomposedStringWithCanonicalMapping,
                   isDirectory: lexical.hasDirectoryPath)
    }

    /// May block on mounted storage. Use only inside bounded background preparation.
    /// No alias cache is used: a symlink may point elsewhere on the next open.
    public static func resolveFilesystemIdentity(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return normalize(url.resolvingSymlinksInPath())
    }

    public static func persistenceKey(for url: URL) -> String? { normalize(url)?.path }

    /// Prepared aliases compare by canonical path; raw URLs compare lexically.
    public static func representsSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsKey = persistenceKey(for: lhs),
              let rhsKey = persistenceKey(for: rhs) else { return false }
        return lhsKey == rhsKey
    }
}
