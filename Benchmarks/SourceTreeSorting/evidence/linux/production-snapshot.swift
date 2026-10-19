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
    private static let criterionPrecedence: [SourceTreeSortCriterion] = [
        .type,
        .dateCreated,
        .name,
    ]

    static func sorted(
        _ entries: [SourceTreeEntry],
        using configuration: SourceTreeSortConfiguration
    ) -> [SourceTreeEntry] {
        guard entries.count > 1 else { return entries }
        guard configuration.name != .off
            || configuration.dateCreated != .off
            || configuration.type != .off
        else { return entries }

        // Date ordering can resolve every comparison without reading a name.
        // Otherwise, derive each filename once for this sort instead of once
        // per comparison. Keep these keys local to the immutable input.
        let names: [String] = configuration.name != .off && configuration.dateCreated == .off
            ? entries.map { $0.url.lastPathComponent } : []
        func filename(at index: Int) -> String {
            names.isEmpty ? entries[index].url.lastPathComponent : names[index]
        }

        // Entries carry optional recognized-media metadata. Sort lightweight
        // offsets, then materialize the original entries in their final order.
        return entries.indices
            .sorted { left, right in
                for criterion in criterionPrecedence {
                    let direction = configuration.direction(for: criterion)
                    guard direction != .off else { continue }
                    if let precedes = orderedBefore(
                        entries[left],
                        entries[right],
                        by: criterion,
                        direction: direction,
                        nameComparison: naturalComparison(
                            entries[left].url, entries[right].url,
                            leftName: filename(at: left),
                            rightName: filename(at: right)
                        )
                    ) {
                        return precedes
                    }
                }
                return left < right
            }
            .map { entries[$0] }
    }

    private static func orderedBefore(
        _ left: SourceTreeEntry,
        _ right: SourceTreeEntry,
        by criterion: SourceTreeSortCriterion,
        direction: SourceTreeSortDirection,
        nameComparison: @autoclosure () -> ComparisonResult
    ) -> Bool? {
        switch criterion {
        case .type:
            guard left.kind != right.kind else { return nil }
            let foldersFirst = direction == .ascending
            return foldersFirst
                ? left.kind == .folder
                : left.kind == .media

        case .dateCreated:
            switch (left.creationDate, right.creationDate) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return direction == .ascending
                    ? leftDate < rightDate
                    : leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return nil
            }

        case .name:
            let comparison = nameComparison()
            guard comparison != .orderedSame else { return nil }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private static func naturalComparison(
        _ left: URL,
        _ right: URL,
        leftName: String,
        rightName: String
    ) -> ComparisonResult {
        let nameComparison = leftName.localizedStandardCompare(rightName)
        guard nameComparison == .orderedSame else { return nameComparison }
        return left.path.compare(right.path, options: [.literal])
    }
}

