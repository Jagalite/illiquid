import Foundation

/// Pure path identities for prepared local URLs. Filesystem resolution belongs
/// at bounded preparation boundaries, never in UI comparison or persistence keys.
public enum NormalizedFileURL {
    /// Standardizes URL path segments and Unicode without querying the filesystem.
    /// Call `resolveFilesystemIdentity` during preparation before storing new URLs.
    public static func normalize(_ url: URL) -> URL? {
        guard isSupportedLocalFileURL(url) else { return nil }
        let lexical = url.absoluteURL.standardized
        return URL(fileURLWithPath: lexical.path.precomposedStringWithCanonicalMapping,
                   isDirectory: lexical.hasDirectoryPath)
    }

    /// May block on mounted storage. Use only inside bounded background preparation.
    /// No alias cache is used: a symlink may point elsewhere on the next open.
    public static func resolveFilesystemIdentity(_ url: URL) -> URL? {
        guard isSupportedLocalFileURL(url) else { return nil }
        return normalize(url.resolvingSymlinksInPath())
    }

    /// A path-only identity cannot retain a remote authority, credentials or a
    /// port. Accept only explicit local authorities without DNS/network lookups;
    /// mounted shares remain supported through their local /Volumes paths.
    /// Validate before symlink resolution, which may discard URL authority.
    private static func isSupportedLocalFileURL(_ url: URL) -> Bool {
        let absolute = url.absoluteURL
        guard absolute.isFileURL, absolute.path.hasPrefix("/"),
              absolute.user == nil, absolute.password == nil, absolute.port == nil
        else { return false }
        let host = absolute.host ?? ""
        return host.isEmpty || host.lowercased() == "localhost"
    }

    public static func persistenceKey(for url: URL) -> String? {
        guard isSupportedLocalFileURL(url) else { return nil }
        let lexical = url.absoluteURL.standardized
        let path = lexical.path
        // Ordinary printable ASCII paths survive the file-URL round trip unchanged.
        // Preserve Foundation's filesystem representation and file-reference
        // behavior for Unicode, NULs, and unusual path forms.
        if path.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }),
           path.hasPrefix("/"),
           !path.contains("//"),
           path == "/" || !path.hasSuffix("/"),
           !path.hasPrefix("/.file/id=") {
            return path
        }
        return URL(fileURLWithPath: path.precomposedStringWithCanonicalMapping,
                   isDirectory: lexical.hasDirectoryPath).path
    }

    /// Prepared aliases compare by canonical path; raw URLs compare lexically.
    public static func representsSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsKey = persistenceKey(for: lhs),
              let rhsKey = persistenceKey(for: rhs) else { return false }
        return lhsKey == rhsKey
    }
}
