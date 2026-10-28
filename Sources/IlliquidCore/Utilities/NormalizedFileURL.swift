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
        if canUsePathIdentityDirectly(path) { return path }

        // Preserve normalize()'s URL round trip for Unicode and unusual paths.
        // On Darwin it can change Unicode bytes or interpret file references.
        return URL(fileURLWithPath: path.precomposedStringWithCanonicalMapping,
                   isDirectory: lexical.hasDirectoryPath).path
    }

    /// Ordinary ASCII components need neither Unicode mapping nor a new URL.
    /// Keep ambiguous separators, decoded dot segments and file references on
    /// Foundation's existing path so persisted identities remain byte-compatible.
    private static func canUsePathIdentityDirectly(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("/.file/") else { return false }
        var previous: UInt8 = 0
        var componentLength = 0
        var dots = 0
        for byte in path.utf8 {
            guard byte >= 0x20, byte < 0x7f else { return false }
            if byte == 0x2f {
                guard previous != 0x2f,
                      componentLength == 0 || dots != componentLength || componentLength > 2
                else { return false }
                componentLength = 0
                dots = 0
            } else {
                componentLength += 1
                if byte == 0x2e { dots += 1 }
            }
            previous = byte
        }
        if previous == 0x2f { return path == "/" }
        return dots != componentLength || componentLength > 2
    }

    /// Prepared aliases compare by canonical path; raw URLs compare lexically.
    public static func representsSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsKey = persistenceKey(for: lhs),
              let rhsKey = persistenceKey(for: rhs) else { return false }
        return lhsKey == rhsKey
    }
}
