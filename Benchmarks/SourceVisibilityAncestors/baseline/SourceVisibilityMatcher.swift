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
