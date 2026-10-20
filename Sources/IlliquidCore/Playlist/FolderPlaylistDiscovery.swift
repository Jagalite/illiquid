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
            // Dates are only needed for accepted media, not every directory entry.
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var metadataDates: [URL: Date] = [:]
        let regularFiles = try directChildren.compactMap { originalURL -> URL? in
            try checkCancellation()
            // Classify ordinary unsupported entries before resolving their paths.
            // Extensionless/misnamed symlinks can still lead to supported targets.
            // Unknown link status must fall through to the existing resolution path.
            if !MediaFileSupport.isSupportedMediaFile(originalURL),
               !MediaFileSupport.isSupportedSubtitleFile(originalURL),
               (try? originalURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            {
                return nil
            }
            let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) ?? originalURL
            try checkCancellation()
            let isMedia = MediaFileSupport.isSupportedMediaFile(url)
            guard isMedia || MediaFileSupport.isSupportedSubtitleFile(url) else { return nil }
            let regular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            if regular, isMedia, let date = FolderPlaylistItem.metadataDate(for: url) {
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
        let mediaSortLocale = normalizedMediaURLs.count > 2 ? Locale.current : nil
        let sortedMediaURLs = NaturalFilenameOrdering.sort(normalizedMediaURLs)
        let associations = ExternalSubtitleMatcher.associate(
            subtitleURLs: normalizedSubtitleURLs,
            with: sortedMediaURLs
        )

        let preparedItems = sortedMediaURLs.map { mediaURL in
            FolderPlaylistItem(
                url: mediaURL,
                externalSubtitleURLs: associations[mediaURL, default: []],
                dateAdded: metadataDates[mediaURL]
            )
        }
        let items = PlaylistMutation.deduplicated(preparedItems)

        // Normalization during item construction can expose new path segments.
        // Skip the second sort only when the exact URL representations survived;
        // deduplication then leaves a sorted subsequence. A changed locale or URL
        // takes the original sorting path. Tiny lists need no extra checks.
        if items.count > 2, let mediaSortLocale, mediaSortLocale == Locale.current,
           zip(sortedMediaURLs, preparedItems).allSatisfy({ original, item in
               original.absoluteString.utf8.elementsEqual(item.url.absoluteString.utf8)
           }) {
            return FolderPlaylist(folderURL: folderURL, sortedItems: items)
        }

        return FolderPlaylist(folderURL: folderURL, items: items)
    }
}
