import Foundation

struct SourceBrowserProjection: Sendable {
    let rows: [SourceTreeDisplayRow]
    let hiddenCount: Int
    let regexCounts: [String: Int]
    let thumbnailCandidates: [URL]
    let mediaPaths: Set<String>

    init(rows: [SourceTreeDisplayRow], hiddenCount: Int, regexCounts: [String: Int]) {
        self.rows = rows
        self.hiddenCount = hiddenCount
        self.regexCounts = regexCounts
        var candidates: [URL] = [], paths: Set<String> = []
        for row in rows {
            guard case .media = row.kind else { continue }
            if candidates.count < 2048 { candidates.append(row.url) }
            paths.insert(row.url.standardizedFileURL.path)
        }
        thumbnailCandidates = candidates
        mediaPaths = paths
    }
}

/// Serial background projection. Search changes reuse the visibility result,
/// including compiled-rule evaluation; only source or rule changes rebuild it.
actor SourceBrowserFilter {
    private var cachedInput: SourceTreeProjectionInput?
    private var cachedRows: [SourceTreeDisplayRow] = []
    private(set) var treeBuildCount = 0

    func project(input: SourceTreeProjectionInput, revealsRulePreview: Bool,
                 query: String) -> SourceBrowserProjection? {
        guard !Task.isCancelled else { return nil }
        if input != cachedInput {
            let rows = input.rows()
            guard !Task.isCancelled else { return nil }
            cachedRows = rows
            cachedInput = input
            treeBuildCount += 1
        }
        return project(rows: cachedRows, configuration: input.visibility,
                       roots: input.roots, revealsRulePreview: revealsRulePreview, query: query)
    }

    private(set) var visibilityBuildCount = 0
    private struct Key: Equatable {
        let rows: [SourceTreeDisplayRow]
        let configuration: SourceVisibilityConfiguration
        let roots: [URL]
        let revealsRulePreview: Bool
    }
    private var cachedKey: Key?
    private var cachedProjection: SourceBrowserProjection?

    func project(
        rows: [SourceTreeDisplayRow], configuration: SourceVisibilityConfiguration,
        roots: [URL], revealsRulePreview: Bool, query: String
    ) -> SourceBrowserProjection? {
        guard !Task.isCancelled else { return nil }
        let key = Key(rows: rows, configuration: configuration, roots: roots,
                      revealsRulePreview: revealsRulePreview)
        if key != cachedKey {
            visibilityBuildCount += 1
            guard let projection = visibility(
                from: rows, configuration: configuration, roots: roots,
                revealsRulePreview: revealsRulePreview
            ) else { return nil }
            cachedProjection = projection
            cachedKey = key
        }
        guard let projection = cachedProjection else { return nil }
        let searched = Self.search(projection.rows, query: query)
        let result = configuration.viewMode == .media
            ? Self.organizeMedia(searched) : searched
        guard !Task.isCancelled else { return nil }
        return SourceBrowserProjection(rows: result, hiddenCount: projection.hiddenCount,
                                       regexCounts: projection.regexCounts)
    }

    private func visibility(
        from allRows: [SourceTreeDisplayRow],
        configuration: SourceVisibilityConfiguration, roots: [URL],
        revealsRulePreview: Bool
    ) -> SourceBrowserProjection? {
        let matcher = SourceVisibilityMatcher(configuration: configuration, roots: roots)
        let evaluatesVisibility =
            !configuration.manuallyHiddenPaths.isEmpty
            || !configuration.alwaysShownPaths.isEmpty
            || configuration.regexRules.contains { $0.isEnabled }
        let revealsHiddenItems = configuration.showsHiddenItems
            || revealsRulePreview
        var hiddenFolders: [String: SourceRowVisibility] = [:]
        var counts = Dictionary(
            uniqueKeysWithValues: configuration.regexRules.map { ($0.id, 0) }
        )
        var hiddenCount = 0
        var rows: [SourceTreeDisplayRow] = []

        for var row in allRows {
            guard !Task.isCancelled else { return nil }
            if !SourceVisibilityProjection.includes(
                row.kind.itemKind,
                in: configuration.viewMode
            ) {
                continue
            }

            let inheritedVisibility = row.ancestorIDs.lazy.compactMap {
                hiddenFolders[$0]
            }.first
            let evaluation = if evaluatesVisibility,
                                let visibilityPath = row.visibilityPath
            {
                configuration.viewMode.scansRecursively
                    ? matcher.evaluateIncludingAncestors(
                        normalizedPath: visibilityPath
                    )
                    : matcher.evaluate(normalizedPath: visibilityPath)
            } else if evaluatesVisibility {
                configuration.viewMode.scansRecursively
                    ? matcher.evaluateIncludingAncestors(row.url)
                    : matcher.evaluate(row.url)
            } else {
                SourceVisibilityEvaluation(
                    hiddenMatches: [],
                    regexMatches: []
                )
            }
            for match in evaluation.regexMatches {
                counts[match.id, default: 0] += 1
            }

            let directVisibility = evaluation.hiddenMatches.isEmpty
                ? nil
                : SourceRowVisibility(
                    matches: evaluation.hiddenMatches,
                    isInherited: false
                )
            let visibility = inheritedVisibility.map {
                SourceRowVisibility(matches: $0.matches, isInherited: true)
            } ?? directVisibility

            if case .folder = row.kind, let visibility {
                hiddenFolders[row.id] = visibility
            }
            if visibility != nil, row.kind.itemKind != nil {
                hiddenCount += 1
            }
            guard visibility == nil || revealsHiddenItems else { continue }
            row.visibility = visibility
            rows.append(row)
        }

        return SourceBrowserProjection(rows: rows, hiddenCount: hiddenCount, regexCounts: counts)
    }

    private static func organizeMedia(_ rows: [SourceTreeDisplayRow]) -> [SourceTreeDisplayRow] {
        // Case variations in release names should not split a season.
        var canonicalTitles: [String: String] = [:]
        let sections = Dictionary(grouping: rows) { row in
            let title = row.recognizedMedia?.section ?? "Other Videos"
            let key = title.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            let canonical = canonicalTitles[key] ?? title
            canonicalTitles[key] = canonical
            return canonical
        }
        func rank(_ title: String) -> Int {
            if title == "Movies" { return 0 }
            if title.hasPrefix("TV Shows · ") { return 1 }
            return title == "Extras" ? 2 : 3
        }
        let titles = sections.keys.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        var result: [SourceTreeDisplayRow] = []
        for title in titles {
            guard !Task.isCancelled else { return [] }
            guard let members = sections[title], let first = members.first else { continue }
            result.append(SourceTreeDisplayRow(
                id: "media-section:\(title)", folderID: "", url: first.url,
                displayName: "\(title) (\(members.count))", depth: 0,
                ancestorIDs: [], kind: .mediaSection))
            // Episode order has semantic meaning; retain the selected file sort
            // for movies, extras, unknown files, and alternate versions of an episode.
            if first.recognizedMedia?.kind == .episode {
                result.append(contentsOf: members.enumerated().sorted { lhs, rhs in
                    guard let a = lhs.element.recognizedMedia, let b = rhs.element.recognizedMedia
                    else { return lhs.offset < rhs.offset }
                    if a.episode != b.episode { return (a.episode ?? 0) < (b.episode ?? 0) }
                    if a.airDate != b.airDate { return (a.airDate ?? "") < (b.airDate ?? "") }
                    return lhs.offset < rhs.offset
                }.map(\.element))
            } else {
                result.append(contentsOf: members)
            }
        }
        return result
    }

    static func search(_ rows: [SourceTreeDisplayRow], query: String) -> [SourceTreeDisplayRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        let matchingRows = rows.filter {
            guard !Task.isCancelled else { return false }
            switch $0.kind {
            case .folder, .media:
                if $0.displayName.localizedCaseInsensitiveContains(query) { return true }
                guard let media = $0.recognizedMedia else { return false }
                return $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || media.section.localizedCaseInsensitiveContains(query)
                    || media.catalogIDs.contains { $0.localizedCaseInsensitiveContains(query) }
                    || ($0.contextLabel?.localizedCaseInsensitiveContains(query) ?? false)
            case .message, .mediaSection:
                return false
            }
        }
        let visibleIDs = Set(matchingRows.flatMap { [$0.id] + $0.ancestorIDs })
        return rows.filter { visibleIDs.contains($0.id) }
    }
}
