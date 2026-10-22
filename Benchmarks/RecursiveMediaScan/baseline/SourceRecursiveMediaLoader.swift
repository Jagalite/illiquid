enum SourceRecursiveMediaLoader {
    static func load(_ roots: [URL], files: [URL] = [], readsMetadata: Bool = false) async -> Result<[SourceTreeEntry], Error> {
        do {
            return .success(try await SourcePreparationExecutor.shared.performWhenAvailable { check in
                read(roots, files: files, readsMetadata: readsMetadata, checkCancellation: check)
            })
        } catch { return .failure(error) }
    }

    nonisolated static func read(
        _ roots: [URL], files: [URL] = [], readsMetadata: Bool = false,
        checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) -> [SourceTreeEntry] {
        var entries: [SourceTreeEntry] = []
        var seenPaths: Set<String> = []
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]

        for originalRoot in roots {
            guard (try? checkCancellation()) != nil else { return [] }
            let root = NormalizedFileURL.resolveFilesystemIdentity(originalRoot) ?? originalRoot
            guard (try? checkCancellation()) != nil,
                  let enumerator = FileManager.default.enumerator(
                      at: root,
                      includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsPackageDescendants],
                      errorHandler: { _, _ in true }
                  )
            else {
                continue
            }

            while let originalURL = enumerator.nextObject() as? URL {
                guard (try? checkCancellation()) != nil else { return [] }
                let url = NormalizedFileURL.resolveFilesystemIdentity(originalURL) ?? originalURL
                guard (try? checkCancellation()) != nil else { return [] }
                let values = try? originalURL.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if values?.isSymbolicLink == true || values?.isPackage == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true,
                      MediaFileSupport.isSupportedMediaFile(url),
                      let path = SourceVisibilityPath.normalized(url),
                      seenPaths.insert(path).inserted
                else {
                    continue
                }
                entries.append(SourceTreeEntry(
                    url: url,
                    kind: .media,
                    dateAdded: values?.addedToDirectoryDate
                        ?? values?.creationDate
                        ?? values?.contentModificationDate,
                    creationDate: values?.creationDate
                        ?? values?.addedToDirectoryDate
                        ?? values?.contentModificationDate,
                    visibilityPath: path
                ))
            }
        }
        for file in files {
            guard (try? checkCancellation()) != nil else { return [] }
            let url = NormalizedFileURL.resolveFilesystemIdentity(file) ?? file
            guard let path = SourceVisibilityPath.normalized(url), seenPaths.insert(path).inserted else { continue }
            entries.append(SourceTreeEntry(url: url, kind: .media, dateAdded: nil,
                creationDate: nil, visibilityPath: path))
        }
        if readsMetadata {
            let reader = MediaSidecarReader()
            let metadataRoots = roots.map { NormalizedFileURL.resolveFilesystemIdentity($0) ?? $0 }
                .sorted { $0.path.count < $1.path.count }
            for index in entries.indices {
                guard (try? checkCancellation()) != nil else { return [] }
                let file = entries[index].url
                let root = metadataRoots.first {
                    file.path != $0.path && SourceTreeIdentity.contains(file.path, within: $0.path)
                }
                    ?? file.deletingLastPathComponent()
                do {
                    entries[index].recognizedMedia = try reader.recognize(file, within: root, checkCancellation: checkCancellation)
                } catch { return [] }
            }
        }
        return entries
    }
}
