import Foundation
import IlliquidCore
import Testing
@testable import IlliquidApp

@Suite("Source tab membership")
struct SourceTabMembershipTests {
    // Keep the original per-item predicate as an independent behavioral oracle.
    // In particular, a rejected file identity can still use folder fallback.
    private func originalContains(_ candidate: URL, in tab: SourceTab) -> Bool {
        tab.items.contains { item in
            switch item.kind {
            case .file:
                return NormalizedFileURL.representsSameFile(candidate, item.url)
            case .folder:
                let folder = item.url
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
    }

    private func decodedItem(_ kind: SourceTabItem.Kind, path: String) throws -> SourceTabItem {
        let data = try JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "path": path])
        return try JSONDecoder().decode(SourceTabItem.self, from: data)
    }

    private func tab(_ kind: SourceTabItem.Kind, path: String) -> SourceTab {
        SourceTab(id: "test", items: [
            SourceTabItem(kind: kind, url: URL(fileURLWithPath: path, isDirectory: kind == .folder)),
        ])
    }

    @Test func emptyTabsRejectEveryCandidate() throws {
        let empty = SourceTab(id: "empty", items: [])
        for input in ["file:///Media/Movie.mkv", "file:///", "file:relative.mkv",
                      "file://server/Media/Movie.mkv", "https://example.com/Movie.mkv"] {
            let candidate = try #require(URL(string: input))
            #expect(!SourceTabs.contains(candidate, in: empty))
        }
    }

    @Test(arguments: [
        "file:///Media/Caf%C3%A9%20%231.mkv",
        "file://localhost/Media/Caf%C3%A9%20%231.mkv",
        "file://LOCALHOST/Media/Caf%C3%A9%20%231.mkv",
        "file:///Media/Cafe%CC%81%20%231.mkv",
        "file:///Media/Season/../Caf%C3%A9%20%231.mkv",
        "file:///Media/Caf%C3%A9%20%231.mkv?token=one#chapter",
    ])
    func filesPreserveCanonicalIdentity(_ input: String) throws {
        let candidate = try #require(URL(string: input))
        let source = tab(.file, path: "/Media/Café #1.mkv")
        #expect(SourceTabs.contains(candidate, in: source))
        #expect(SourceTabs.contains(candidate, in: source) == originalContains(candidate, in: source))
    }

    @Test func folderMatchesUseComponentsAndKeepRootBehavior() {
        let source = tab(.folder, path: "/Media/Shows")
        for path in ["/Media/Shows", "/Media/Shows/", "/Media/Shows/Season/Episode.mkv"] {
            #expect(SourceTabs.contains(URL(fileURLWithPath: path), in: source))
        }
        for path in ["/Media", "/Media/Shows-Archive/Episode.mkv", "/Other/Media/Shows/Episode.mkv"] {
            #expect(!SourceTabs.contains(URL(fileURLWithPath: path), in: source))
        }
        #expect(SourceTabs.contains(URL(fileURLWithPath: "/Media/Movie.mkv"), in: tab(.folder, path: "/")))
        #expect(SourceTabs.contains(URL(fileURLWithPath: "/"), in: tab(.folder, path: "/")))
        #expect(!SourceTabs.contains(URL(fileURLWithPath: "/media/Shows/Episode.mkv"), in: source))
    }

    @Test(arguments: [
        "file://media-server.example/Media/Movie.mkv",
        "file://127.0.0.1/Media/Movie.mkv",
        "file://[::1]/Media/Movie.mkv",
        "file://user@localhost/Media/Movie.mkv",
        "file://user:secret@localhost/Media/Movie.mkv",
        "file://localhost:1234/Media/Movie.mkv",
    ])
    func unsupportedFileIdentityStillReachesFolderFallback(_ input: String) throws {
        let candidate = try #require(URL(string: input))
        let file = tab(.file, path: "/Media/Movie.mkv").items[0]
        let folder = tab(.folder, path: "/Media").items[0]
        #expect(!SourceTabs.contains(candidate, in: SourceTab(id: "file", items: [file])))
        for items in [[file, folder], [folder, file], [file, file, folder]] {
            let mixed = SourceTab(id: "mixed", items: items)
            #expect(SourceTabs.contains(candidate, in: mixed))
            #expect(SourceTabs.contains(candidate, in: mixed) == originalContains(candidate, in: mixed))
        }
    }

    @Test func relativeReferencesKeepTheirBaseSemantics() throws {
        let source = tab(.file, path: "/Media/Movie.mkv")
        let localBase = URL(fileURLWithPath: "/Media/Season/", isDirectory: true)
        let local = try #require(URL(string: "../Movie.mkv", relativeTo: localBase))
        #expect(SourceTabs.contains(local, in: source))
        let remoteBase = try #require(URL(string: "file://server.example/Media/Season/"))
        let remote = try #require(URL(string: "../Movie.mkv", relativeTo: remoteBase))
        #expect(!SourceTabs.contains(remote, in: source))
        #expect(SourceTabs.contains(remote, in: tab(.folder, path: "/Media")))
        let webBase = try #require(URL(string: "https://example.com/Media/"))
        let web = try #require(URL(string: "Movie.mkv", relativeTo: webBase))
        #expect(!SourceTabs.contains(web, in: tab(.folder, path: "/Media")))
    }

    @Test func decodedItemsAreStillNormalized() throws {
        let alias = try decodedItem(.file, path: "/Media/Season/../Cafe\u{301}.mkv")
        let folder = try decodedItem(.folder, path: "/Media/Season/../Cafe\u{301}")
        #expect(SourceTabs.contains(
            URL(fileURLWithPath: "/Media/Café.mkv"),
            in: SourceTab(id: "decoded-file", items: [alias])
        ))
        #expect(SourceTabs.contains(
            URL(fileURLWithPath: "/Media/Café/Episode.mkv"),
            in: SourceTab(id: "decoded-folder", items: [folder])
        ))
        for path in ["", "relative.mkv", "../relative", "//Media///Movie.mkv", "/Media/./Movie.mkv"] {
            for kind in [SourceTabItem.Kind.file, .folder] {
                let item = try decodedItem(kind, path: path)
                let source = SourceTab(id: "raw", items: [item])
                for candidate in [item.url, item.url.appendingPathComponent("Child.mkv"),
                                  URL(fileURLWithPath: "/Media/Movie.mkv")] {
                    #expect(SourceTabs.contains(candidate, in: source) == originalContains(candidate, in: source))
                }
            }
        }
    }

    @Test func queriesAndTabChangesDoNotReuseStaleIdentity() {
        let first = URL(fileURLWithPath: "/Media/First.mkv")
        let second = URL(fileURLWithPath: "/Media/Second.mkv")
        var source = tab(.file, path: first.path)
        #expect(SourceTabs.contains(first, in: source))
        #expect(!SourceTabs.contains(second, in: source))
        source.items = [SourceTabItem(kind: .file, url: second)]
        #expect(!SourceTabs.contains(first, in: source))
        #expect(SourceTabs.contains(second, in: source))
        source.items = tab(.folder, path: "/Media").items
        #expect(SourceTabs.contains(first, in: source))
        source.items.removeAll()
        #expect(!SourceTabs.contains(first, in: source))
    }

    @Test func fileAndFolderHitsWorkInEveryPosition() {
        let query = URL(fileURLWithPath: "/Media/Shows/Movie.mkv")
        let misses = (0..<24).map { index in
            SourceTabItem(kind: index.isMultiple(of: 2) ? .file : .folder,
                          url: URL(fileURLWithPath: "/Other/\(index)"))
        }
        let hits = [SourceTabItem(kind: .file, url: query), tab(.folder, path: "/Media/Shows").items[0]]
        for hit in hits {
            for index in [0, 1, 12, misses.count] {
                var items = misses
                items.insert(hit, at: index)
                let source = SourceTab(id: "position", items: items)
                #expect(SourceTabs.contains(query, in: source))
                #expect(SourceTabs.contains(query, in: source) == originalContains(query, in: source))
            }
        }
        #expect(!SourceTabs.contains(query, in: SourceTab(id: "miss", items: misses)))
    }

    @Test func URLCorpusMatchesOriginalPredicate() throws {
        let paths = ["/", "/Media", "/Media/", "/Media/Shows", "/Media/Shows-Archive",
                     "/Media/Movie.mkv", "/Media/./Movie.mkv", "/Media/Season/../Movie.mkv",
                     "/Media/Café.mkv", "/Media/Cafe\u{301}.mkv", "/Media/a%2Fb.mkv",
                     "/Media/a b#c?.mkv", "/Media/日本語.mkv", "//Media///Movie.mkv",
                     "/media/Movie.mkv", "", "relative", "../relative"]
        var items: [SourceTabItem] = []
        for path in paths {
            items.append(try decodedItem(.file, path: path))
            items.append(try decodedItem(.folder, path: path))
        }
        var queries = paths.map { URL(fileURLWithPath: $0, isDirectory: false) }
        for value in ["file:", "file://", "file:relative.mkv", "file:///Media/a%2Fb.mkv",
                      "file:///Media/a%252Fb.mkv", "file:///Media/Movie.mkv%00",
                      "file:///Media/%2E%2E/Movie.mkv", "file:///Media/Movie.mkv/",
                      "file://LOCALHOST/Media/Movie.mkv", "file://server/Media/Movie.mkv",
                      "file://user@localhost/Media/Movie.mkv", "https://example.com/Media/Movie.mkv"] {
            queries.append(try #require(URL(string: value)))
        }
        for base in [URL(fileURLWithPath: "/Media/", isDirectory: true),
                     try #require(URL(string: "file://server/Media/")),
                     try #require(URL(string: "https://example.com/Media/"))] {
            queries.append(try #require(URL(string: "Movie.mkv", relativeTo: base)))
            queries.append(try #require(URL(string: "../Movie.mkv", relativeTo: base)))
        }
        var tabs = items.map { SourceTab(id: "single", items: [$0]) }
        tabs += [SourceTab(id: "empty", items: []), SourceTab(id: "all", items: items),
                 SourceTab(id: "reverse", items: items.reversed()),
                 SourceTab(id: "files", items: items.filter { $0.kind == .file }),
                 SourceTab(id: "folders", items: items.filter { $0.kind == .folder }),
                 SourceTab(id: "duplicates", items: items + items)]
        for candidate in queries {
            for source in tabs {
                #expect(SourceTabs.contains(candidate, in: source) == originalContains(candidate, in: source))
            }
        }
    }

    @Test func symlinkIdentityRemainsLexical() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.mkv")
        try Data().write(to: target)
        let alias = root.appendingPathComponent("Alias.mkv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let source = SourceTab(id: "target", items: [SourceTabItem(kind: .file, url: target)])
        #expect(!SourceTabs.contains(alias, in: source))
        #expect(SourceTabs.contains(alias, in: SourceTab(id: "alias", items: [SourceTabItem(kind: .file, url: alias)])))
        #expect(SourceTabs.contains(alias, in: SourceTab(id: "folder", items: [SourceTabItem(kind: .folder, url: root)])))
    }
}
