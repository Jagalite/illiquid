import Foundation

/// The local file formats accepted by the player.
public enum MediaFileSupport {
    public static let videoFileExtensions: Set<String> = [
        "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg",
        "mpg", "mts", "ogm", "ogv", "ts", "vob", "webm", "wmv",
    ]

    public static let subtitleFileExtensions: Set<String> = ["ass", "idx", "srt", "ssa", "vtt"]

    public static func isSupportedMediaFile(_ url: URL) -> Bool {
        url.isFileURL && videoFileExtensions.contains(normalizedExtension(of: url))
    }

    public static func isSupportedSubtitleFile(_ url: URL) -> Bool {
        url.isFileURL && subtitleFileExtensions.contains(normalizedExtension(of: url))
    }

    private static func normalizedExtension(of url: URL) -> String {
        let pathExtension = url.pathExtension
        // Current supported extensions fit in four ASCII bytes. Bound the probe
        // so longer suffixes do not incur another full scan before lowercasing.
        var remaining = 4
        for byte in pathExtension.utf8 {
            guard remaining > 0,
                  byte < 0x80,
                  !(0x41...0x5A).contains(byte) else {
                return pathExtension.lowercased(with: Locale(identifier: "en_US_POSIX"))
            }
            remaining -= 1
        }
        return pathExtension
    }
}
