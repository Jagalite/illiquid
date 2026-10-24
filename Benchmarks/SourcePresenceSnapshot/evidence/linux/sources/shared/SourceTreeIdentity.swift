import Foundation

enum SourceTreeIdentity {
    static func folderID(for url: URL) -> String {
        normalizedPath(for: url)
    }

    static func fileID(for url: URL) -> String {
        normalizedPath(for: url)
    }

    static func path(fromFolderID id: String) -> String {
        id
    }

    static func isFolderID(_ id: String, inside root: URL) -> Bool {
        contains(id, within: normalizedPath(for: root))
    }

    static func contains(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private static func normalizedPath(for url: URL) -> String {
        (NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized).path
    }
}
