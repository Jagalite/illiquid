import Foundation

let snapshotVariant = "candidate"

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
                let rootURL = URL(fileURLWithPath: path, isDirectory: true)
                let reusableResults = SourceMediaPresenceSnapshot.reusableResults(
                    under: SourceTreeIdentity.folderID(for: rootURL), results: self.results
                ) { folder in
                    self.summaries[folder]?.isComplete == true
                        && self.summaries[folder]?.isReadable == true
                }
        return reusableResults
    }
}
