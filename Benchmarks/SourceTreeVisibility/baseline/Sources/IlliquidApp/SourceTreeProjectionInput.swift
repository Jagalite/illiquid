import Foundation
import IlliquidCore

/// Immutable values copied from UI state. Sorting and recursive row construction
/// execute on the existing browser actor, with no SwiftUI/AppModel access.
struct SourceTreeProjectionInput: Equatable, Sendable {
    let items: [SourceTabItem]
    let visibility: SourceVisibilityConfiguration
    let roots: [URL]
    let directoryContents: [String: [SourceTreeEntry]]
    let directoryErrors: [String: String]
    let recursiveMediaEntries: [SourceTreeEntry]
    let expandedFolderIDs: Set<String>
    let sortConfiguration: SourceTreeSortConfiguration
    var mediaPresence: [String: Bool] = [:]

    func rows() -> [SourceTreeDisplayRow] {
        if visibility.viewMode.scansRecursively {
            return makeFlatFileRows()
        }

        var rows: [SourceTreeDisplayRow] = []
        let flattensSingleFolder =
            items.count == 1 && items.first?.kind == .folder

        for item in items {
            guard !Task.isCancelled else { return [] }
            switch item.kind {
            case .file:
                rows.append(SourceTreeDisplayRow(
                    id: "media:\(SourceTreeIdentity.fileID(for: item.url))",
                    folderID: "",
                    url: item.url,
                    displayName: item.url.deletingPathExtension().lastPathComponent,
                    visibilityPath: SourceVisibilityPath.normalized(item.url),
                    depth: 0,
                    ancestorIDs: [],
                    kind: .media(dateAdded: nil)
                ))
            case .folder:
                if flattensSingleFolder {
                    appendActiveFolderContents(item.url, to: &rows)
                } else {
                    appendFolder(
                        item.url,
                        depth: 0,
                        isRoot: true,
                        ancestors: [],
                        to: &rows
                    )
                }
            }
        }
        return rows
    }

    private func makeFlatFileRows() -> [SourceTreeDisplayRow] {
        let matcher = SourceVisibilityMatcher(
            configuration: visibility,
            roots: roots
        )
        var entries = recursiveMediaEntries
        let loadedPaths = Set(entries.map { SourceTreeIdentity.fileID(for: $0.url) })
        entries.append(contentsOf: items.compactMap { item in
            guard item.kind == .file, !loadedPaths.contains(SourceTreeIdentity.fileID(for: item.url)) else { return nil }
            return SourceTreeEntry(
                url: item.url,
                kind: .media,
                dateAdded: nil,
                creationDate: nil,
                visibilityPath: SourceVisibilityPath.normalized(item.url)
            )
        })

        var seenPaths: Set<String> = []
        return SourceTreeSorting.sorted(entries, using: sortConfiguration)
            .compactMap { entry -> SourceTreeDisplayRow? in
                guard !Task.isCancelled, let path = entry.visibilityPath
                    ?? SourceVisibilityPath.normalized(entry.url),
                      seenPaths.insert(path).inserted
                else {
                    return nil
                }
                let relativePath = matcher.relativePath(
                    normalizedPath: path
                )
                let parent = (relativePath as NSString).deletingLastPathComponent
                let recognition: RecognizedMediaName? = visibility.viewMode == .media
                    ? entry.recognizedMedia ?? MediaNameRecognition.recognize(relativePath: entry.url.path)
                    : nil
                let context = recognition.map { media in
                    [media.variant, media.metadataSources.isEmpty ? nil : media.metadataSources.joined(separator: ", "), parent.isEmpty ? nil : parent].compactMap { $0 }.joined(separator: " · ")
                } ?? parent
                return SourceTreeDisplayRow(
                    id: "media:\(SourceTreeIdentity.fileID(for: entry.url))",
                    folderID: entry.url.deletingLastPathComponent().path,
                    url: entry.url,
                    displayName: recognition?.displayName ?? entry.url.deletingPathExtension().lastPathComponent,
                    contextLabel: context.isEmpty ? nil : context,
                    recognizedMedia: recognition,
                    visibilityPath: path,
                    depth: 0,
                    ancestorIDs: [],
                    kind: .media(dateAdded: entry.dateAdded)
                )
            }
    }

    private func appendActiveFolderContents(
        _ folderURL: URL,
        to rows: inout [SourceTreeDisplayRow]
    ) {
        guard !Task.isCancelled else { return }
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        if let error = directoryErrors[folderID] {
            rows.append(SourceTreeDisplayRow(
                id: "message:\(folderID)",
                folderID: folderID,
                url: folderURL,
                displayName: error,
                depth: 0,
                ancestorIDs: [],
                kind: .message(error)
            ))
            return
        }
        guard let entries = directoryContents[folderID] else { return }
        if entries.isEmpty {
            rows.append(SourceTreeDisplayRow(
                id: "message:\(folderID)",
                folderID: folderID,
                url: folderURL,
                displayName: "No supported media",
                depth: 0,
                ancestorIDs: [],
                kind: .message("No supported media")
            ))
            return
        }

        for entry in SourceTreeSorting.sorted(
            entries,
            using: sortConfiguration
        ) {
            guard !Task.isCancelled else { return }
            switch entry.kind {
            case .folder:
                appendFolder(
                    entry.url,
                    depth: 0,
                    isRoot: false,
                    ancestors: [],
                    visitedFolderIDs: [folderID],
                    to: &rows
                )
            case .media:
                rows.append(SourceTreeDisplayRow(
                    id: "media:\(SourceTreeIdentity.fileID(for: entry.url))",
                    folderID: folderID,
                    url: entry.url,
                    displayName: entry.url.deletingPathExtension().lastPathComponent,
                    visibilityPath: entry.visibilityPath
                        ?? SourceVisibilityPath.normalized(entry.url),
                    depth: 0,
                    ancestorIDs: [],
                    kind: .media(dateAdded: entry.dateAdded)
                ))
            }
        }
    }

    private func appendFolder(
        _ folderURL: URL,
        depth: Int,
        isRoot: Bool,
        ancestors: [String],
        visitedFolderIDs: Set<String> = [],
        to rows: inout [SourceTreeDisplayRow]
    ) {
        guard !Task.isCancelled else { return }
        let folderID = SourceTreeIdentity.folderID(for: folderURL)
        guard !visitedFolderIDs.contains(folderID) else { return }
        let visitedFolderIDs = visitedFolderIDs.union([folderID])
        rows.append(SourceTreeDisplayRow(
            id: "folder:\(folderID)",
            folderID: folderID,
            url: folderURL,
            displayName: folderURL.lastPathComponent,
            visibilityPath: SourceVisibilityPath.normalized(folderURL),
            depth: depth,
            ancestorIDs: ancestors,
            kind: .folder(isRoot: isRoot),
            containsSupportedMedia: mediaPresence[folderID]
        ))
        guard expandedFolderIDs.contains(folderID) else { return }

        let childAncestors = ancestors + ["folder:\(folderID)"]
        if let error = directoryErrors[folderID] {
            rows.append(SourceTreeDisplayRow(
                id: "message:\(folderID)",
                folderID: folderID,
                url: folderURL,
                displayName: error,
                depth: depth + 1,
                ancestorIDs: childAncestors,
                kind: .message(error)
            ))
            return
        }
        guard let entries = directoryContents[folderID] else { return }
        if entries.isEmpty {
            rows.append(SourceTreeDisplayRow(
                id: "message:\(folderID)",
                folderID: folderID,
                url: folderURL,
                displayName: "No supported media",
                depth: depth + 1,
                ancestorIDs: childAncestors,
                kind: .message("No supported media")
            ))
            return
        }

        for entry in SourceTreeSorting.sorted(
            entries,
            using: sortConfiguration
        ) {
            guard !Task.isCancelled else { return }
            switch entry.kind {
            case .folder:
                appendFolder(
                    entry.url,
                    depth: depth + 1,
                    isRoot: false,
                    ancestors: childAncestors,
                    visitedFolderIDs: visitedFolderIDs,
                    to: &rows
                )
            case .media:
                rows.append(SourceTreeDisplayRow(
                    id: "media:\(SourceTreeIdentity.fileID(for: entry.url))",
                    folderID: folderID,
                    url: entry.url,
                    displayName: entry.url.deletingPathExtension().lastPathComponent,
                    visibilityPath: entry.visibilityPath
                        ?? SourceVisibilityPath.normalized(entry.url),
                    depth: depth + 1,
                    ancestorIDs: childAncestors,
                    kind: .media(dateAdded: entry.dateAdded)
                ))
            }
        }
    }

}
