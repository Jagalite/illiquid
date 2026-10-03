import Foundation

public enum FolderPlaylistDiscoveryError: Error, Equatable, LocalizedError {
    case notDirectory(URL)

    public var errorDescription: String? {
        switch self {
        case let .notDirectory(url):
            return "The selected URL is not a folder: \(url.path)"
        }
    }
}

public enum FolderPlaylistDiscovery {
    /// Scans only the selected directory. Nested directories are never traversed.
    public static func discover(
        in folderURL: URL,
        fileManager: FileManager = .default,
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> FolderPlaylist {
        try checkCancellation()
        let folderURL = NormalizedFileURL.resolveFilesystemIdentity(folderURL) ?? folderURL
        try checkCancellation()
        let values = try folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw FolderPlaylistDiscoveryError.notDirectory(folderURL)
        }

        let directChildren = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .addedToDirectoryDateKey,
                .creationDateKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )

        var metadataDates: [URL: Date] = [:]
        let regularFiles = try directChildren.compactMap { originalURL -> URL? in
            try checkCancellation()
            let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) ?? originalURL
            try checkCancellation()
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            if regular, let date = FolderPlaylistItem.metadataDate(for: url) {
                metadataDates[NormalizedFileURL.normalize(url) ?? url] = date
            }
            return regular ? url : nil
        }

        try checkCancellation()
        let playlist = makePlaylist(
            folderURL: folderURL,
            mediaURLs: regularFiles.filter(MediaFileSupport.isSupportedMediaFile),
            subtitleURLs: regularFiles.filter(MediaFileSupport.isSupportedSubtitleFile),
            metadataDates: metadataDates
        )
        try checkCancellation()
        return playlist
    }

    /// Builds a pure model from a listing whose filesystem identities are already resolved.
    /// This is useful for responding to filesystem change notifications later.
    public static func makePlaylist(
        folderURL: URL,
        mediaURLs: [URL],
        subtitleURLs: [URL],
        metadataDates: [URL: Date] = [:]
    ) -> FolderPlaylist {
        let normalizedMediaURLs = mediaURLs.compactMap(NormalizedFileURL.normalize)
        let normalizedSubtitleURLs = subtitleURLs.compactMap(NormalizedFileURL.normalize)
        let sortedMediaURLs = NaturalFilenameOrdering.sort(normalizedMediaURLs)
        let associations = ExternalSubtitleMatcher.associate(
            subtitleURLs: normalizedSubtitleURLs,
            with: sortedMediaURLs
        )

        let items = PlaylistMutation.deduplicated(sortedMediaURLs.map { mediaURL in
            FolderPlaylistItem(
                url: mediaURL,
                externalSubtitleURLs: associations[mediaURL, default: []],
                dateAdded: metadataDates[mediaURL]
            )
        })

        return FolderPlaylist(folderURL: folderURL, items: items)
    }
}
