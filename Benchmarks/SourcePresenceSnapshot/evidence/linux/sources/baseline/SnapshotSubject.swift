import Foundation

let snapshotVariant = "baseline"

enum SourceMediaPresenceCursor {
    struct Summary: Sendable {
        let hasDirectMedia: Bool
        let children: Set<String>
        let isComplete: Bool
        let isReadable: Bool
    }
}

struct SnapshotSubject {
    let results: [String: Bool]
    let summaries: [String: SourceMediaPresenceCursor.Summary]

    @inline(never)
    func snapshot(under path: String) -> [String: Bool] {
                let reusableResults = self.results.filter { entry in
                    self.summaries[entry.key]?.isComplete == true
                        && self.summaries[entry.key]?.isReadable == true
                }
        return reusableResults
    }
}
