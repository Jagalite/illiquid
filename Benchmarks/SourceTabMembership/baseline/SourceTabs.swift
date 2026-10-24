import Foundation
import IlliquidCore

struct SourceTabItem: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case folder
    }

    let kind: Kind
    let path: String

    init(kind: Kind, url: URL) {
        self.kind = kind
        path = (
            NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized
        ).path
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: kind == .folder)
    }
}

struct SourceTab: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var items: [SourceTabItem]
    var visibility: SourceVisibilityConfiguration?

    var displayName: String {
        if let folder = items.first(where: { $0.kind == .folder }) {
            return folder.url.lastPathComponent
        }
        if let file = items.first(where: { $0.kind == .file }) {
            return file.url.deletingPathExtension().lastPathComponent
        }
        return "New Tab"
    }

    init(
        id: String,
        items: [SourceTabItem],
        visibility: SourceVisibilityConfiguration? = nil
    ) {
        self.id = id
        self.items = items
        self.visibility = visibility
    }
}

enum SourceVisibilityViewMode: String, Codable, CaseIterable, Sendable {
    case tree
    case filesOnly
    case foldersOnly
    case media

    var scansRecursively: Bool { self == .filesOnly || self == .media }

    var title: String {
        switch self {
        case .tree:
            "Tree"
        case .filesOnly:
            "Files Only"
        case .foldersOnly:
            "Folders Only"
        case .media:
            "Media"
        }
    }

    var systemImage: String {
        switch self {
        case .tree:
            "list.bullet.indent"
        case .filesOnly:
            "doc"
        case .foldersOnly:
            "folder"
        case .media:
            "film.stack"
        }
    }
}

struct SourceVisibilityRegexRule: Codable, Equatable, Identifiable, Sendable {
    static let colorCount = 6

    let id: String
    let pattern: String
    let colorIndex: Int
    var isEnabled: Bool

    static func isValid(pattern: String) -> Bool {
        !pattern.isEmpty
            && pattern.count <= 512
            && (try? NSRegularExpression(pattern: pattern)) != nil
    }

    static func nextColorIndex(
        after rules: [SourceVisibilityRegexRule]
    ) -> Int {
        guard let last = rules.last else { return 0 }
        return (last.colorIndex + 1) % colorCount
    }
}

struct SourceVisibilityConfiguration: Codable, Equatable, Sendable {
    static let `default` = Self(
        viewMode: .tree,
        showsHiddenItems: false,
        manuallyHiddenPaths: [],
        alwaysShownPaths: [],
        regexRules: []
    )

    var viewMode: SourceVisibilityViewMode
    var showsHiddenItems: Bool
    var manuallyHiddenPaths: Set<String>
    var alwaysShownPaths: Set<String>
    var regexRules: [SourceVisibilityRegexRule]

    var isDefault: Bool {
        self == .default
    }

    mutating func normalize() {
        manuallyHiddenPaths = SourceVisibilityPath.normalized(
            manuallyHiddenPaths
        )
        alwaysShownPaths = SourceVisibilityPath.normalized(alwaysShownPaths)
        alwaysShownPaths.subtract(manuallyHiddenPaths)

        var seenIDs: Set<String> = []
        var seenPatterns: Set<String> = []
        regexRules = regexRules.compactMap { rule in
            let pattern = rule.pattern.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !rule.id.isEmpty,
                  seenIDs.insert(rule.id).inserted,
                  seenPatterns.insert(pattern).inserted,
                  SourceVisibilityRegexRule.isValid(pattern: pattern)
            else {
                return nil
            }
            return SourceVisibilityRegexRule(
                id: rule.id,
                pattern: pattern,
                colorIndex: min(
                    max(rule.colorIndex, 0),
                    SourceVisibilityRegexRule.colorCount - 1
                ),
                isEnabled: rule.isEnabled
            )
        }
    }
}

enum SourceVisibilityPath {
    static func normalized(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return (NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized).path
    }

    static func normalized(_ paths: Set<String>) -> Set<String> {
        Set(paths.compactMap { path in
            guard path.hasPrefix("/") else { return nil }
            return normalized(URL(fileURLWithPath: path, isDirectory: false))
        })
    }
}

enum SourceTabItems {
    /// File-heavy tabs must not compare every parent against every prior parent
    /// on the UI actor. URL normalization here is lexical, with no filesystem IO.
    static func watchRoots(for items: [SourceTabItem]) -> [URL] {
        var seen: Set<String> = []
        return items.compactMap { item in
            let root = item.kind == .folder ? item.url : item.url.deletingLastPathComponent()
            let normalized = NormalizedFileURL.normalize(root) ?? root.absoluteURL.standardized
            guard seen.insert(normalized.path).inserted else { return nil }
            return normalized
        }
    }

    static func merging(
        _ existing: [SourceTabItem],
        with additions: [URL],
        kind: SourceTabItem.Kind
    ) -> [SourceTabItem] {
        merging(
            existing,
            with: additions
                .filter(\.isFileURL)
                .map { SourceTabItem(kind: kind, url: $0) }
        )
    }

    static func merging(
        _ existing: [SourceTabItem],
        with additions: [SourceTabItem]
    ) -> [SourceTabItem] {
        var result: [SourceTabItem] = []
        var seen: Set<SourceTabItem> = []
        result.reserveCapacity(existing.count + additions.count)
        for item in existing + additions {
            guard !item.path.isEmpty else { continue }
            // Decoded items may contain noncanonical paths. Normalize once and
            // retain the first occurrence of each (kind, canonical path) pair.
            let canonical = SourceTabItem(kind: item.kind, url: item.url)
            guard seen.insert(canonical).inserted else { continue }
            result.append(canonical)
        }
        return result
    }
}

enum SourceTabStore {
    static func restore(from data: Data?) -> [SourceTab]? {
        guard let data else { return nil }
        guard let decoded = try? JSONDecoder().decode([SourceTab].self, from: data)
        else {
            return nil
        }
        var restored: [SourceTab] = []
        for tab in decoded {
            guard !tab.id.isEmpty,
                  !restored.contains(where: { $0.id == tab.id })
            else {
                continue
            }
            restored.append(SourceTab(
                id: tab.id,
                items: SourceTabItems.merging([], with: tab.items),
                visibility: normalizedVisibility(tab.visibility)
            ))
        }
        return restored
    }

    static func encode(_ tabs: [SourceTab]) -> Data? {
        try? JSONEncoder().encode(tabs)
    }

    private static func normalizedVisibility(
        _ stored: SourceVisibilityConfiguration?
    ) -> SourceVisibilityConfiguration? {
        guard var stored else { return nil }
        stored.normalize()
        return stored.isDefault ? nil : stored
    }
}

enum SourceTabDirection: Sendable {
    case previous
    case next
}

enum SourceTabs {
    static func migratedTabID(forFolderID folderID: String) -> String {
        "folder:\(folderID)"
    }

    static func migrating(_ folders: [URL]) -> [SourceTab] {
        folders.map { folder in
            let folderID = (
                NormalizedFileURL.normalize(folder) ?? folder.absoluteURL.standardized
            ).path
            return SourceTab(
                id: migratedTabID(forFolderID: folderID),
                items: [SourceTabItem(kind: .folder, url: folder)]
            )
        }
    }

    static func resolvedSelection(
        _ selectedID: String?,
        in tabs: [SourceTab]
    ) -> String? {
        if let selectedID,
           tabs.contains(where: { $0.id == selectedID })
        {
            return selectedID
        }
        return tabs.first?.id
    }

    static func activeTab(
        selectedID: String?,
        in tabs: [SourceTab]
    ) -> SourceTab? {
        guard let resolvedID = resolvedSelection(selectedID, in: tabs) else {
            return nil
        }
        return tabs.first { $0.id == resolvedID }
    }

    static func selectionAfterClosing(
        _ closedID: String,
        selectedID: String?,
        from tabs: [SourceTab]
    ) -> String? {
        guard let closedIndex = tabs.firstIndex(where: { $0.id == closedID })
        else {
            return resolvedSelection(selectedID, in: tabs)
        }

        let remaining = tabs.enumerated().compactMap { index, tab in
            index == closedIndex ? nil : tab
        }
        guard selectedID == closedID
                || activeTab(selectedID: selectedID, in: tabs) == nil
        else {
            return resolvedSelection(selectedID, in: remaining)
        }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(closedIndex, remaining.count - 1)].id
    }

    static func adjacentSelection(
        from selectedID: String?,
        direction: SourceTabDirection,
        in tabs: [SourceTab]
    ) -> String? {
        guard !tabs.isEmpty else { return nil }
        let resolvedID = resolvedSelection(selectedID, in: tabs)
        let currentIndex = tabs.firstIndex { $0.id == resolvedID } ?? 0
        let offset = switch direction {
        case .previous:
            tabs.count - 1
        case .next:
            1
        }
        let nextIndex = (currentIndex + offset) % tabs.count
        return tabs[nextIndex].id
    }

    static func contains(_ candidate: URL, in tab: SourceTab) -> Bool {
        tab.items.contains { item in
            switch item.kind {
            case .file:
                NormalizedFileURL.representsSameFile(candidate, item.url)
            case .folder:
                contains(candidate, inside: item.url)
            }
        }
    }

    private static func contains(_ candidate: URL, inside folder: URL) -> Bool {
        guard candidate.isFileURL, folder.isFileURL else { return false }
        let candidateComponents = (
            NormalizedFileURL.normalize(candidate) ?? candidate.absoluteURL.standardized
        ).pathComponents
        let folderComponents = (
            NormalizedFileURL.normalize(folder) ?? folder.absoluteURL.standardized
        ).pathComponents
        return candidateComponents.starts(with: folderComponents)
    }
}
