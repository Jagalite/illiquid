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

    /// Ordinary ASCII identities do not need an intermediate file URL. Preserve
    /// Foundation's filesystem representation for Unicode and unusual path forms.
    public static func persistenceKey(for url: URL) -> String? {
        guard isSupportedLocalFileURL(url) else { return nil }
        let lexical = url.absoluteURL.standardized
        let path = lexical.path.precomposedStringWithCanonicalMapping
        if isSimpleASCIIPath(path) { return path }
        return URL(fileURLWithPath: path, isDirectory: lexical.hasDirectoryPath).path
    }

    private static func isSimpleASCIIPath(_ path: String) -> Bool {
        guard path.utf8.first == 0x2F else { return false }
        var previous: UInt8 = 0
        for byte in path.utf8 {
            // Foundation can decompose Unicode and truncate at NUL during the
            // file-URL round trip. Keep it for control bytes and path forms
            // that can acquire new meaning after percent decoding as well.
            guard byte >= 0x20, byte < 0x7F,
                  !(previous == 0x2F && (byte == 0x2F || byte == 0x2E))
            else { return false }
            previous = byte
        }
        return previous != 0x2F || path == "/"
    }

    /// Prepared aliases compare by canonical path; raw URLs compare lexically.
    public static func representsSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsKey = persistenceKey(for: lhs),
              let rhsKey = persistenceKey(for: rhs) else { return false }
        return lhsKey == rhsKey
    }
}
