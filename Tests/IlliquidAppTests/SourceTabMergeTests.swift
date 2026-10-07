import Foundation
import Testing
@testable import IlliquidApp

@Suite("Source tab merge scaling")
struct SourceTabMergeTests {
    @Test func decodedAliasesUnicodeAndKindsKeepFirstCanonicalOccurrence() throws {
        let rows = [
            ["kind": "file", "path": "/media/Shows/../Movie.mkv"],
            ["kind": "file", "path": "/media/Movie.mkv"],
            ["kind": "folder", "path": "/media/Movie.mkv"],
            ["kind": "file", "path": "/media/Cafe\u{301}.mkv"],
            ["kind": "file", "path": "/media/Café.mkv"],
            ["kind": "file", "path": ""],
        ]
        let decoded = try JSONDecoder().decode([SourceTabItem].self,
            from: JSONSerialization.data(withJSONObject: rows))
        let expected = [
            SourceTabItem(kind: .file, url: URL(fileURLWithPath: "/media/Movie.mkv")),
            SourceTabItem(kind: .folder, url: URL(fileURLWithPath: "/media/Movie.mkv")),
            SourceTabItem(kind: .file, url: URL(fileURLWithPath: "/media/Café.mkv")),
        ]
        #expect(SourceTabItems.merging(Array(decoded.prefix(2)), with: Array(decoded.dropFirst(2))) == expected)
        #expect(SourceTabItems.merging(expected, with: decoded) == expected)
    }

    @Test func largeOverlappingInputsPreserveOrderAndDistinctNewItems() {
        let original = (0..<10_000).map {
            SourceTabItem(kind: .file, url: URL(fileURLWithPath: "/media/episode-\($0).mkv"))
        }
        let last = SourceTabItem(kind: .folder, url: URL(fileURLWithPath: "/media/next"))
        #expect(SourceTabItems.merging(original, with: Array(original.reversed()) + [last]) == original + [last])
    }
}
