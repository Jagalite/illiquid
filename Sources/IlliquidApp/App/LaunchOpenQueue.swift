import Foundation
import IlliquidCore

struct LaunchOpenRequest: Equatable {
    let urls: [URL]
    let mode: PlaylistOpenMode
}

/// Holds Launch Services URL events until the first player window has connected
/// the application shell to the playback runtime.
struct LaunchOpenQueue {
    private(set) var isReady = false
    private var pending: [LaunchOpenRequest] = []

    mutating func receive(
        urls: [URL],
        mode: PlaylistOpenMode = .replace
    ) -> [LaunchOpenRequest] {
        guard !urls.isEmpty else { return [] }
        let request = LaunchOpenRequest(urls: urls, mode: mode)
        guard !isReady else { return [request] }

        // One Finder event is one request, regardless of window readiness.
        // Multiple URLs delivered together still form one playlist.
        pending.append(request)
        return []
    }

    mutating func markReady() -> [LaunchOpenRequest] {
        guard !isReady else { return [] }
        isReady = true
        defer { pending.removeAll(keepingCapacity: false) }
        return pending
    }
}

/// Filesystem classification runs only inside SourcePreparationExecutor. The UI
/// captures the destination tab before awaiting and rejects closed-tab results.
enum SourceItemPreparation {
    nonisolated static func prepare(
        _ urls: [URL], kind: SourceTabItem.Kind?,
        checkCancellation: @Sendable () throws -> Void
    ) throws -> [SourceTabItem] {
        var items: [SourceTabItem] = []
        for originalURL in urls {
            try checkCancellation()
            guard let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) else { continue }
            try checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true, kind != .file {
                items.append(SourceTabItem(kind: .folder, url: url))
            } else if values?.isRegularFile == true, kind != .folder,
                      MediaFileSupport.isSupportedMediaFile(url) {
                items.append(SourceTabItem(kind: .file, url: url))
            }
        }
        try checkCancellation()
        return SourceTabItems.merging([], with: items)
    }
}
