import Foundation
import Darwin

/// One instance per background scan. No process-wide cache or filesystem work
/// in the name recognizer / UI projection. Missing files are cached too.
public final class MediaSidecarReader {
    private enum Sidecar {
        case missing
        case plex(PlexMatchHints)
        case nfo(MediaMetadataHints)
    }
    private var cache: [String: Sidecar] = [:]
    private var remainingBytes = 16 * 1024 * 1024
    public private(set) var filesRead = 0
    public static let maximumFileBytes = 128 * 1024

    public init() {}

    public func recognize(_ file: URL, within root: URL,
                          checkCancellation: () throws -> Void = {}) throws -> RecognizedMediaName {
        var recognized = MediaNameRecognition.recognize(relativePath: file.path)
        guard recognized.kind != .extra else { return recognized }
        let root = root.standardizedFileURL
        let parent = file.deletingLastPathComponent().standardizedFileURL
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else { return recognized }
        var folders: [URL] = []
        var cursor = parent
        while folders.count < 64 {
            try checkCancellation()
            folders.append(cursor)
            if cursor == root { break }
            let next = cursor.deletingLastPathComponent()
            guard next != cursor else { return recognized }
            cursor = next
        }
        guard folders.last == root else { return recognized }
        var hints = MediaMetadataHints()
        var foundSeriesPlex = false
        var mappedEpisode: MediaMetadataHints?
        for folder in folders.reversed() {
            try checkCancellation()
            if case let .nfo(nfo) = read(folder.appendingPathComponent("tvshow.nfo")), nfo.content == .show {
                hints = nfo.overriding(hints)
            }
            if case let .plex(plex) = read(folder.appendingPathComponent(".plexmatch")) {
                let relative = String(file.path.dropFirst(folder.path.count + 1))
                if let mapping = plex.episodeHint(for: relative, inheritsDescendantMappings: !foundSeriesPlex) {
                    mappedEpisode = mapping
                }
                hints = plex.metadata.overriding(hints)
                foundSeriesPlex = true
            }
        }
        if var mapping = mappedEpisode {
            mapping.season = mapping.season ?? hints.season ?? directorySeason(parent.lastPathComponent) ?? 1
            hints = mapping.overriding(hints)
        }
        if recognized.kind != .episode, hints.content == nil,
           case let .nfo(nfo) = read(parent.appendingPathComponent("movie.nfo")), nfo.content == .movie {
            hints = nfo.overriding(hints)
        }
        try checkCancellation()
        let ownNFO = file.deletingPathExtension().appendingPathExtension("nfo")
        if case let .nfo(nfo) = read(ownNFO), nfo.content != .show {
            hints = nfo.overriding(hints)
        }
        if recognized.kind == .unknown, let title = hints.title,
           hints.content == .show || hints.content == .episode {
            let candidate = parent.appendingPathComponent(title + " - " + file.lastPathComponent)
            let inferred = MediaNameRecognition.recognize(relativePath: candidate.path)
            if inferred.kind == .episode { recognized = inferred }
        }
        if recognized.kind == .unknown, hints.content == .episode, hints.title == nil,
           let episode = hints.episode {
            let synthesized = parent.appendingPathComponent("S\(hints.season ?? 1)E\(episode).mkv")
            let inferred = MediaNameRecognition.recognize(relativePath: synthesized.path)
            // Use folder context for identity only; keep the original file's variant.
            if inferred.kind == .episode { hints.title = inferred.title; hints.year = hints.year ?? inferred.year }
            else { return recognized }
        }
        recognized = recognized.applying(hints)
        return recognized
    }

    private func read(_ url: URL) -> Sidecar {
        if let cached = cache[url.path] { return cached }
        // Bounds cover both parsed data and negative lookups in pathological trees.
        guard cache.count < 50_000, remainingBytes > 0 else { return .missing }
        var result: Sidecar = .missing
        if let data = readBoundedRegularFile(url) {
            remainingBytes -= data.count
            filesRead += 1
            if url.lastPathComponent == ".plexmatch", let text = String(data: data, encoding: .utf8),
               let hints = PlexMatchHints.parse(text) { result = .plex(hints) }
            else if url.pathExtension.lowercased() == "nfo", let hints = NFOMetadataHints.parse(data) { result = .nfo(hints) }
        }
        cache[url.path] = result
        return result
    }

    private func readBoundedRegularFile(_ url: URL) -> Data? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= min(Self.maximumFileBytes, remainingBytes) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: min(Self.maximumFileBytes, remainingBytes) + 1),
              data.count <= Self.maximumFileBytes, data.count <= remainingBytes else { return nil }
        return data
    }

    private func directorySeason(_ name: String) -> Int? {
        if name.lowercased() == "specials" { return 0 }
        guard name.lowercased().hasPrefix("season") else { return nil }
        return MediaMetadataHints.number(String(name.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: " ._-")), maximum: 999)
    }
}
