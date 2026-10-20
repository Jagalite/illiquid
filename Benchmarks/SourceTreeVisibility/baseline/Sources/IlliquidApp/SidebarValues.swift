import Foundation
import IlliquidCore

struct SourceTreeEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder
        case media
    }

    let url: URL
    let kind: Kind
    let dateAdded: Date?
    let creationDate: Date?
    let visibilityPath: String?
    var recognizedMedia: RecognizedMediaName? = nil

    init(
        url: URL,
        kind: Kind,
        dateAdded: Date?,
        creationDate: Date?,
        visibilityPath: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.dateAdded = dateAdded
        self.creationDate = creationDate
        self.visibilityPath = visibilityPath
    }
}

struct SourceVisibilityRegexMatch: Equatable, Sendable {
    let id: String
    let colorIndex: Int
}

enum SourceVisibilityHideMatch: Equatable, Sendable {
    case manual
    case noMedia
    case regex(SourceVisibilityRegexMatch)
}

struct SourceVisibilityEvaluation: Equatable, Sendable {
    let hiddenMatches: [SourceVisibilityHideMatch]
    let regexMatches: [SourceVisibilityRegexMatch]
}

struct SourceRowVisibility: Equatable, Sendable {
    let matches: [SourceVisibilityHideMatch]
    let isInherited: Bool

    var regexMatches: [SourceVisibilityRegexMatch] {
        matches.compactMap { match in
            guard case let .regex(regexMatch) = match else { return nil }
            return regexMatch
        }
    }

    var isManual: Bool {
        matches.contains(.manual)
    }
}

struct SourceVisibilityMatcher {
    private struct CompiledRule {
        let match: SourceVisibilityRegexMatch
        let expression: NSRegularExpression
    }

    private let configuration: SourceVisibilityConfiguration
    private let rootPaths: [String]
    private let compiledRules: [CompiledRule]
    private let rootEvaluations: [String: SourceVisibilityEvaluation]

    init(
        configuration: SourceVisibilityConfiguration,
        roots: [URL]
    ) {
        self.configuration = configuration
        let rootPaths = roots.compactMap(SourceVisibilityPath.normalized)
        let compiledRules: [CompiledRule] =
            configuration.regexRules.compactMap { rule in
            guard rule.isEnabled,
                  let expression = try? NSRegularExpression(pattern: rule.pattern)
            else {
                return nil
            }
            return CompiledRule(
                match: SourceVisibilityRegexMatch(
                    id: rule.id,
                    colorIndex: rule.colorIndex
                ),
                expression: expression
            )
        }
        self.rootPaths = rootPaths
        self.compiledRules = compiledRules
        rootEvaluations = Dictionary(uniqueKeysWithValues: rootPaths.map { path in
            (
                path,
                Self.evaluate(
                    normalizedPath: path,
                    candidate: URL(fileURLWithPath: path, isDirectory: false).lastPathComponent,
                    configuration: configuration,
                    compiledRules: compiledRules
                )
            )
        })
    }

    func evaluate(_ url: URL) -> SourceVisibilityEvaluation {
        guard let normalizedPath = SourceVisibilityPath.normalized(url)
        else {
            return SourceVisibilityEvaluation(
                hiddenMatches: [],
                regexMatches: []
            )
        }
        return evaluate(normalizedPath: normalizedPath)
    }

    func evaluate(
        normalizedPath: String
    ) -> SourceVisibilityEvaluation {
        Self.evaluate(
            normalizedPath: normalizedPath,
            candidate: relativePath(normalizedPath: normalizedPath),
            configuration: configuration,
            compiledRules: compiledRules
        )
    }

    private static func evaluate(
        normalizedPath: String,
        candidate: String,
        configuration: SourceVisibilityConfiguration,
        compiledRules: [CompiledRule]
    ) -> SourceVisibilityEvaluation {
        let range = NSRange(candidate.startIndex..., in: candidate)
        let regexMatches = compiledRules.compactMap { rule in
            var matched = false
            rule.expression.enumerateMatches(in: candidate, options: [.reportProgress], range: range) {
                result, _, stop in
                if result != nil { matched = true }
                if matched || Task.isCancelled { stop.pointee = true }
            }
            return matched ? rule.match : nil
        }

        if configuration.manuallyHiddenPaths.contains(normalizedPath) {
            return SourceVisibilityEvaluation(
                hiddenMatches: [.manual] + regexMatches.map {
                    .regex($0)
                },
                regexMatches: regexMatches
            )
        }
        if configuration.alwaysShownPaths.contains(normalizedPath) {
            return SourceVisibilityEvaluation(
                hiddenMatches: [],
                regexMatches: regexMatches
            )
        }
        return SourceVisibilityEvaluation(
            hiddenMatches: regexMatches.map { .regex($0) },
            regexMatches: regexMatches
        )
    }

    func evaluateIncludingAncestors(_ url: URL) -> SourceVisibilityEvaluation {
        guard let normalizedPath = SourceVisibilityPath.normalized(url) else {
            return SourceVisibilityEvaluation(
                hiddenMatches: [],
                regexMatches: []
            )
        }
        return evaluateIncludingAncestors(normalizedPath: normalizedPath)
    }

    func evaluateIncludingAncestors(
        normalizedPath: String
    ) -> SourceVisibilityEvaluation {
        guard let rootPath = matchingRootPath(for: normalizedPath) else {
            return evaluate(normalizedPath: normalizedPath)
        }
        return evaluateIncludingAncestors(
            normalizedPath: normalizedPath,
            rootPath: rootPath
        )
    }

    private func evaluateIncludingAncestors(
        normalizedPath: String,
        rootPath: String
    ) -> SourceVisibilityEvaluation {
        let direct = evaluate(normalizedPath: normalizedPath)

        var regexMatches = direct.regexMatches
        var ancestorPath = URL(fileURLWithPath: normalizedPath, isDirectory: false)
            .deletingLastPathComponent()
            .path
        while ancestorPath.count >= rootPath.count,
              ancestorPath == rootPath
                || ancestorPath.hasPrefix(rootPath + "/")
        {
            let ancestor = ancestorPath == rootPath
                ? rootEvaluations[rootPath] ?? evaluate(
                    normalizedPath: ancestorPath
                )
                : evaluate(normalizedPath: ancestorPath)
            for match in ancestor.regexMatches where !regexMatches.contains(match) {
                regexMatches.append(match)
            }
            if !ancestor.hiddenMatches.isEmpty {
                return SourceVisibilityEvaluation(
                    hiddenMatches: ancestor.hiddenMatches,
                    regexMatches: regexMatches
                )
            }
            if ancestorPath == rootPath {
                break
            }
            ancestorPath = URL(fileURLWithPath: ancestorPath, isDirectory: false)
                .deletingLastPathComponent()
                .path
        }

        return SourceVisibilityEvaluation(
            hiddenMatches: direct.hiddenMatches,
            regexMatches: regexMatches
        )
    }

    func relativePath(for url: URL) -> String {
        guard let normalizedPath = SourceVisibilityPath.normalized(url)
        else {
            return url.lastPathComponent
        }
        return relativePath(normalizedPath: normalizedPath)
    }

    func relativePath(normalizedPath: String) -> String {
        let matchingRoot = matchingRootPath(for: normalizedPath)

        guard let matchingRoot else {
            return URL(fileURLWithPath: normalizedPath, isDirectory: false).lastPathComponent
        }
        guard normalizedPath != matchingRoot else {
            return URL(fileURLWithPath: matchingRoot, isDirectory: false).lastPathComponent
        }
        return String(normalizedPath.dropFirst(matchingRoot.count + 1))
    }

    private func matchingRootPath(for normalizedPath: String) -> String? {
        rootPaths
            .filter { rootPath in
                normalizedPath == rootPath
                    || normalizedPath.hasPrefix(rootPath + "/")
            }
            .max { $0.count < $1.count }
    }
}

enum SourceVisibilityProjection {
    static func includes(
        _ kind: SourceTreeEntry.Kind?,
        in viewMode: SourceVisibilityViewMode
    ) -> Bool {
        guard let kind else { return true }
        return switch (viewMode, kind) {
        case (.tree, _), (.filesOnly, .media), (.media, .media), (.foldersOnly, .folder):
            true
        case (.filesOnly, .folder), (.media, .folder), (.foldersOnly, .media):
            false
        }
    }
}

enum SourceTreeSortCriterion: String, CaseIterable, Identifiable, Sendable {
    case type
    case dateCreated
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type:
            "Type"
        case .dateCreated:
            "Date Created"
        case .name:
            "Name"
        }
    }

    var systemImage: String {
        switch self {
        case .type:
            "square.grid.2x2"
        case .dateCreated:
            "calendar"
        case .name:
            "textformat"
        }
    }
}

enum SourceTreeSortDirection: String, CaseIterable, Sendable {
    case off
    case ascending
    case descending

    var next: Self {
        switch self {
        case .off:
            .ascending
        case .ascending:
            .descending
        case .descending:
            .off
        }
    }

    var title: String {
        switch self {
        case .off:
            "Off"
        case .ascending:
            "Ascending"
        case .descending:
            "Descending"
        }
    }

    var systemImage: String? {
        switch self {
        case .off:
            nil
        case .ascending:
            "arrow.up"
        case .descending:
            "arrow.down"
        }
    }

    static func resolve(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .off
    }
}

struct SourceTreeSortConfiguration: Equatable, Sendable {
    let name: SourceTreeSortDirection
    let dateCreated: SourceTreeSortDirection
    let type: SourceTreeSortDirection

    func direction(
        for criterion: SourceTreeSortCriterion
    ) -> SourceTreeSortDirection {
        switch criterion {
        case .type:
            type
        case .dateCreated:
            dateCreated
        case .name:
            name
        }
    }
}

enum SourceTreeSorting {
    static func sorted(
        _ entries: [SourceTreeEntry],
        using configuration: SourceTreeSortConfiguration
    ) -> [SourceTreeEntry] {
        guard entries.count > 1,
              configuration.type != .off
                || configuration.dateCreated != .off
                || configuration.name != .off
        else { return entries }

        // Resolve a filename only if earlier criteria tie, and at most once
        // per entry. A date sort with distinct dates need not read any names.
        var names: [String?] = configuration.name == .off
            ? [] : Array(repeating: nil, count: entries.count)
        func name(at index: Int) -> String {
            if let cached = names[index] { return cached }
            let value = entries[index].url.lastPathComponent
            names[index] = value
            return value
        }

        // Move indices during sorting instead of complete entries and their
        // metadata. The original index also preserves the order of full ties.
        return entries.indices.sorted { leftIndex, rightIndex in
            let left = entries[leftIndex], right = entries[rightIndex]
            if configuration.type != .off, left.kind != right.kind {
                return configuration.type == .ascending
                    ? left.kind == .folder : left.kind == .media
            }

            if configuration.dateCreated != .off {
                switch (left.creationDate, right.creationDate) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return configuration.dateCreated == .ascending
                        ? leftDate < rightDate : leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            if configuration.name != .off {
                var comparison = name(at: leftIndex).localizedStandardCompare(name(at: rightIndex))
                if comparison == .orderedSame {
                    comparison = left.url.path.compare(right.url.path, options: [.literal])
                }
                if comparison != .orderedSame {
                    return configuration.name == .ascending
                        ? comparison == .orderedAscending : comparison == .orderedDescending
                }
            }
            return leftIndex < rightIndex
        }.map { entries[$0] }
    }
}


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
                let root = metadataRoots.first { file.path.hasPrefix($0.path + "/") }
                    ?? file.deletingLastPathComponent()
                do {
                    entries[index].recognizedMedia = try reader.recognize(file, within: root, checkCancellation: checkCancellation)
                } catch { return [] }
            }
        }
        return entries
    }
}


struct SourceTreeDisplayRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case folder(isRoot: Bool)
        case media(dateAdded: Date?)
        case message(String)
        case mediaSection

        var itemKind: SourceTreeEntry.Kind? {
            switch self {
            case .folder:
                .folder
            case .media:
                .media
            case .message, .mediaSection:
                nil
            }
        }
    }

    let id: String
    let folderID: String
    let url: URL
    let displayName: String
    var contextLabel: String? = nil
    var recognizedMedia: RecognizedMediaName? = nil
    var visibilityPath: String? = nil
    let depth: Int
    let ancestorIDs: [String]
    let kind: Kind
    var visibility: SourceRowVisibility? = nil
    var containsSupportedMedia: Bool? = nil
}

enum SourceTreeIdentity {
    static func folderID(for url: URL) -> String {
        normalizedPath(for: url)
    }

    static func fileID(for url: URL) -> String {
        normalizedPath(for: url)
    }

    static func path(fromFolderID id: String) -> String {
        id
    }

    static func isFolderID(_ id: String, inside root: URL) -> Bool {
        let rootPath = normalizedPath(for: root)
        return id == rootPath || id.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(for url: URL) -> String {
        (NormalizedFileURL.normalize(url) ?? url.absoluteURL.standardized).path
    }
}

