import Foundation

/// Mount/unmount notifications affect sources on the volume and sources that
/// contain its mount point. The relationship must remain available offline.
enum SourceVolumeChangePolicy {
    static func affectedRoots(at volumePath: String, roots: [URL]) -> [URL] {
        let volumePath = normalized(URL(fileURLWithPath: volumePath, isDirectory: true))
        return roots.filter { root in
            let rootPath = normalized(root)
            return contains(rootPath, within: volumePath)
                || contains(volumePath, within: rootPath)
        }
    }

    private static func normalized(_ url: URL) -> String {
        // Do not resolve symlinks or query storage in a volume notification.
        url.absoluteURL.standardized.path
    }

    private static func contains(_ path: String, within rootPath: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
    }
}
