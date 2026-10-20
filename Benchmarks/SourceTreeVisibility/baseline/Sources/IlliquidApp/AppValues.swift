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

