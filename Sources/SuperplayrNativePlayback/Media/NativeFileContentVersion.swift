import Darwin
import Foundation
import SuperplayrCore

enum NativeFileContentVersion {
    /// Called only within native session construction's bounded worker lifetime.
    /// stat follows symlinks, so retargeting cannot reuse the link's own metadata.
    static func read(_ url: URL) -> MediaContentVersion? {
        guard url.isFileURL else { return nil }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var information = stat()
            guard stat(path, &information) == 0,
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  information.st_size >= 0 else { return nil }
            return MediaContentVersion(
                fileIdentifier: UInt64(information.st_ino), byteCount: information.st_size,
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                creationSeconds: Int64(information.st_birthtimespec.tv_sec),
                creationNanoseconds: Int64(information.st_birthtimespec.tv_nsec)
            )
        }
    }

    static func verified(before: MediaContentVersion?, after: MediaContentVersion?) -> MediaContentVersion? {
        before == after ? before : nil
    }
}
