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
    private struct FolderSidecarPaths {
        let show: URL
        let plex: URL
    }
    private struct AncestorPathPlan {
        let root: String
        let parent: String
        // Discovery visits parent first; sidecar reads visit root first.
        let folders: [URL]
        let sidecars: [FolderSidecarPaths]
        let hints: MediaMetadataHints
    }
    private var cache: [String: Sidecar] = [:]
    // A missing or unusable sidecar needs only its path. Keeping those entries
    // out of the value dictionary avoids reserving the enum's metadata payload
    // for every file in a library without per-file sidecars.
    private var missingPaths: Set<String> = []
    // A metadata pass normally visits sibling files consecutively. Retain only
    // their last validated path plan, bounded by the existing 64-folder limit.
    private var ancestorPathPlan: AncestorPathPlan?
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
        guard Self.relativePath(parent.path, within: root.path) != nil else { return recognized }
        let rootKey = root.absoluteString
        let parentKey = parent.absoluteString
        let cachedPlan: AncestorPathPlan?
        // Canonically equivalent Swift strings can name different URL paths.
        // Reuse only the exact representations that passed the root walk.
        if let plan = ancestorPathPlan,
           plan.root.utf8.elementsEqual(rootKey.utf8),
           plan.parent.utf8.elementsEqual(parentKey.utf8) {
            cachedPlan = plan
        } else {
            cachedPlan = nil
        }
        var folders: [URL] = []
        if let cachedPlan {
            folders = cachedPlan.folders
            // Preserve the discovery checkpoints before any sidecar reads,
            // including on hits and when a check throws partway through them.
            for _ in folders { try checkCancellation() }
        } else {
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
        }
        var plannedSidecars: [FolderSidecarPaths] = []
        if cachedPlan == nil { plannedSidecars.reserveCapacity(folders.count) }
        var hints = cachedPlan?.hints ?? MediaMetadataHints()
        var foundSeriesPlex = false
        var mappedEpisode: MediaMetadataHints?
        for (offset, folder) in folders.reversed().enumerated() {
            try checkCancellation()
            let cachedPaths = cachedPlan?.sidecars[offset]
            let showURL = cachedPaths?.show ?? folder.appendingPathComponent("tvshow.nfo")
            if case let .nfo(nfo) = read(showURL), nfo.content == .show {
                if cachedPlan == nil { hints = nfo.overriding(hints) }
            }
            let plexURL = cachedPaths?.plex ?? folder.appendingPathComponent(".plexmatch")
            if case let .plex(plex) = read(plexURL) {
                if let relative = Self.relativePath(file.path, within: folder.path),
                   let mapping = plex.episodeHint(for: relative, inheritsDescendantMappings: !foundSeriesPlex) {
                    mappedEpisode = mapping
                }
                if cachedPlan == nil { hints = plex.metadata.overriding(hints) }
                foundSeriesPlex = true
            }
            if cachedPaths == nil {
                plannedSidecars.append(FolderSidecarPaths(show: showURL, plex: plexURL))
            }
        }
        if cachedPlan == nil {
            // Publish only after all ancestor reads. Later calls still perform
            // those reads, preserving negative caching and byte/entry budgets.
            // Cached sidecars do not change during this reader's lifetime, so
            // siblings can reuse their merged metadata. Per-file mappings and
            // NFO overrides must remain outside this ancestor-only snapshot.
            ancestorPathPlan = AncestorPathPlan(root: rootKey, parent: parentKey,
                folders: folders, sidecars: plannedSidecars, hints: hints)
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

    /// Use the same component boundary for containment and PlexMatch mapping keys.
    /// The filesystem root already includes its descendant separator.
    static func relativePath(_ path: String, within root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func read(_ url: URL) -> Sidecar {
        let path = url.path
        if let cached = cache[path] { return cached }
        if missingPaths.contains(path) { return .missing }
        // Bounds cover both parsed data and negative lookups in pathological trees.
        guard cache.count + missingPaths.count < 50_000, remainingBytes > 0 else { return .missing }
        var result: Sidecar = .missing
        if let data = readBoundedRegularFile(url) {
            remainingBytes -= data.count
            filesRead += 1
            if url.lastPathComponent == ".plexmatch", let text = String(data: data, encoding: .utf8),
               let hints = PlexMatchHints.parse(text) { result = .plex(hints) }
            else if url.pathExtension.lowercased() == "nfo", let hints = NFOMetadataHints.parse(data) { result = .nfo(hints) }
        }
        switch result {
        case .missing: missingPaths.insert(path)
        case .plex, .nfo: cache[path] = result
        }
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
