import Foundation
import Testing
@testable import IlliquidCore

@Suite("Sidecar ancestor path planning")
struct MediaSidecarPathPlanTests {
    @Test func siblingsRetainTheirOwnMappingsAndOverrides() throws {
        try withFixture { root in
            let folder = root.appendingPathComponent("Season 2", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("<tvshow><title>Series</title><year>2010</year></tvshow>", at: root, name: "tvshow.nfo")
            try write("""
                title: Mapped Series
                ep: S04E06-E08: Season 2/first.mkv
                ep: S04E09: Season 2/second.mkv
                """, at: root, name: ".plexmatch")
            try write("season: 7", at: folder, name: ".plexmatch")
            try write("""
                <episodedetails><showtitle>Own Series</showtitle><title>Finale</title>
                <season>2</season><episode>10</episode></episodedetails>
                """, at: folder, name: "second.nfo")
            let reader = MediaSidecarReader()
            for name in ["first.mkv", "second.mkv", "S02E12.mkv", "first.mkv", "second.mkv"] {
                let file = folder.appendingPathComponent(name)
                let result = try reader.recognize(file, within: root)
                #expect(try result == MediaSidecarReader().recognize(file, within: root))
                #expect(result.year == 2010)
                if name == "first.mkv" {
                    #expect(result.title == "Mapped Series")
                    #expect(result.season == 4)
                    #expect(result.episode == 6)
                    #expect(result.lastEpisode == 8)
                } else if name == "second.mkv" {
                    #expect(result.title == "Own Series")
                    #expect(result.season == 2)
                    #expect(result.episode == 10)
                    #expect(result.lastEpisode == nil)
                    #expect(result.episodeTitle == "Finale")
                } else {
                    #expect(result.episode == 12)
                    #expect(result.lastEpisode == nil)
                }
            }
            #expect(reader.filesRead == 4)
        }
    }

    @Test func alternatingParentsAndSourceRootsDoNotSharePlans() throws {
        try withFixture { root in
            try write("<tvshow><title>Outer</title><year>2001</year></tvshow>", at: root, name: "tvshow.nfo")
            let left = root.appendingPathComponent("left", isDirectory: true)
            let right = root.appendingPathComponent("right", isDirectory: true)
            for folder in [left, right] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try write("title: \(folder.lastPathComponent)\nep: 3: clip.mkv", at: folder, name: ".plexmatch")
            }
            let reader = MediaSidecarReader()
            for (folder, boundary) in [(left, root), (right, root), (right, right),
                                        (left, left), (left, root), (right, root)] {
                let file = folder.appendingPathComponent("clip.mkv")
                let result = try reader.recognize(file, within: boundary)
                #expect(try result == MediaSidecarReader().recognize(file, within: boundary))
                #expect(result.title == folder.lastPathComponent)
                #expect(result.year == (boundary == root ? 2001 : nil))
                #expect(result.episode == 3)
            }
        }
    }

    @Test func unicodeEquivalentStringsKeepTheirExactURLBoundaries() throws {
        try withFixture { fixture in
            // File-path constructors can normalize both spellings on macOS.
            // Explicit URL strings retain distinct inputs; production URL
            // standardization is still free to apply the platform's rules.
            let composed = try #require(URL(string: fixture.absoluteString + "Caf%C3%A9/"))
            let decomposed = try #require(URL(string: fixture.absoluteString + "Cafe%CC%81/"))
            let original = try #require(URL(string: composed.absoluteString + "clip.mkv"))
            let alternate = try #require(URL(string: decomposed.absoluteString + "clip.mkv"))
            try FileManager.default.createDirectory(at: composed, withIntermediateDirectories: true)
            try write("title: Exact Root\nep: 5: clip.mkv", at: composed, name: ".plexmatch")
            #expect(composed.path == decomposed.path)
            #expect(!composed.absoluteString.utf8.elementsEqual(decomposed.absoluteString.utf8))
            #expect(!original.absoluteString.utf8.elementsEqual(alternate.absoluteString.utf8))
            let reader = MediaSidecarReader()
            // Warm a valid boundary using the reader's own parent transform;
            // root and child URL transforms need not normalize identically.
            let warmRoot = original.deletingLastPathComponent().standardizedFileURL
            #expect(try reader.recognize(original, within: warmRoot).title == "Exact Root")
            // Either URL can be a filesystem alias on macOS; the root walk's
            // original URL equality, rather than String equality, is the oracle.
            for (file, root) in [
                (alternate, composed), (original, decomposed), (original, composed),
            ] {
                #expect(try reader.recognize(file, within: root)
                        == MediaSidecarReader().recognize(file, within: root))
            }
        }
    }

    @Test func filesystemRootAndDirectoryURLSpellingMatchFreshReaders() throws {
        try withFixture { root in
            try write("title: Root Series\nep: 1: first.mkv\nep: 2: second.mkv", at: root, name: ".plexmatch")
            let filesystemRoot = URL(fileURLWithPath: "/", isDirectory: true)
            let fileStyleRoot = URL(fileURLWithPath: root.path, isDirectory: false)
            let reader = MediaSidecarReader()
            for boundary in [filesystemRoot, filesystemRoot, root, fileStyleRoot, root] {
                for name in ["first.mkv", "second.mkv"] {
                    let file = root.appendingPathComponent(name)
                    #expect(try reader.recognize(file, within: boundary)
                            == MediaSidecarReader().recognize(file, within: boundary))
                }
            }
        }
    }

    @Test func ancestorLimitRemainsInclusiveOfTheSourceRoot() throws {
        try withFixture { root in
            try write("title: Boundary Series", at: root, name: ".plexmatch")
            var folder = root
            for _ in 0..<63 { folder.appendPathComponent("d", isDirectory: true) }
            let overLimit = folder.appendingPathComponent("d", isDirectory: true)
            try FileManager.default.createDirectory(at: overLimit, withIntermediateDirectories: true)
            let reader = MediaSidecarReader()
            for parent in [folder, folder, overLimit, folder] {
                let file = parent.appendingPathComponent("S01E02.mkv")
                var checkpoints = 0
                let result = try reader.recognize(file, within: root) { checkpoints += 1 }
                #expect(try result == MediaSidecarReader().recognize(file, within: root))
                if parent == folder {
                    #expect(result.title == "Boundary Series")
                    #expect(checkpoints == 129)
                } else {
                    #expect(result == MediaNameRecognition.recognize(relativePath: file.path))
                    #expect(checkpoints == 64)
                }
            }
            #expect(reader.filesRead == 1)
        }
    }

    @Test func cancellationPreservesCheckpointAndReadOrderOnColdAndWarmCalls() throws {
        try withFixture { root in
            let middle = root.appendingPathComponent("a", isDirectory: true)
            let leaf = middle.appendingPathComponent("b", isDirectory: true)
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
            try write("<tvshow><title>Series</title></tvshow>", at: root, name: "tvshow.nfo")
            try write("title: Root Series", at: root, name: ".plexmatch")
            try write("season: 3", at: middle, name: ".plexmatch")
            try write("ep: 7: clip.mkv", at: leaf, name: ".plexmatch")
            try write("<episodedetails><title>Own Title</title><episode>8</episode></episodedetails>",
                      at: leaf, name: "clip.nfo")
            let file = leaf.appendingPathComponent("clip.mkv")
            let expected = try MediaSidecarReader().recognize(file, within: root)
            for warm in [false, true] {
                let expectedReads = warm ? Array(repeating: 4, count: 7) : [0, 0, 0, 0, 2, 3, 4]
                for cancellationPoint in 1...7 {
                    let reader = MediaSidecarReader()
                    if warm {
                        _ = try reader.recognize(leaf.appendingPathComponent("S01E01.mkv"), within: root)
                        #expect(reader.filesRead == 4)
                    }
                    var readsAtCheck: [Int] = []
                    #expect(throws: CancellationError.self) {
                        try reader.recognize(file, within: root) {
                            readsAtCheck.append(reader.filesRead)
                            if readsAtCheck.count == cancellationPoint { throw CancellationError() }
                        }
                    }
                    #expect(readsAtCheck == Array(expectedReads.prefix(cancellationPoint)))
                    #expect(reader.filesRead == expectedReads[cancellationPoint - 1])
                    #expect(try reader.recognize(file, within: root) == expected)
                    #expect(reader.filesRead == 5)
                }
            }
        }
    }

    @Test func negativeSidecarCacheStillAppliesToSiblingFiles() throws {
        try withFixture { root in
            let first = root.appendingPathComponent("S01E01.mkv")
            let second = root.appendingPathComponent("S01E02.mkv")
            let reader = MediaSidecarReader()
            _ = try reader.recognize(first, within: root)
            try write("title: Newly Added Series", at: root, name: ".plexmatch")
            let cached = try reader.recognize(second, within: root)
            #expect(cached == MediaNameRecognition.recognize(relativePath: second.path))
            #expect(reader.filesRead == 0)
            #expect(try MediaSidecarReader().recognize(second, within: root).title == "Newly Added Series")
        }
    }

    @Test func exhaustedByteBudgetStillUsesPreviouslyReadAncestorMetadata() throws {
        try withFixture { root in
            let shared = "title: Budget Series"
            try write(shared, at: root, name: ".plexmatch")
            let prefix = "<movie><title>Budget Film</title><plot>"
            let suffix = "</plot></movie>"
            let reader = MediaSidecarReader()
            // The shared sidecar plus these 128 own-file NFOs consume exactly
            // 16 MiB. Padding belongs to an ignored XML field.
            for index in 0..<128 {
                let byteCount = MediaSidecarReader.maximumFileBytes - (index == 0 ? shared.utf8.count : 0)
                let padding = byteCount - prefix.utf8.count - suffix.utf8.count
                try write(prefix + String(repeating: " ", count: padding) + suffix,
                          at: root, name: "film\(index).nfo")
                let file = root.appendingPathComponent("film\(index).mkv")
                #expect(try reader.recognize(file, within: root).title == "Budget Film")
            }
            #expect(reader.filesRead == 129)
            try write("<episodedetails><showtitle>Too Late</showtitle><episode>9</episode></episodedetails>",
                      at: root, name: "S01E03.nfo")
            let remaining = try reader.recognize(root.appendingPathComponent("S01E03.mkv"), within: root)
            #expect(remaining.title == "Budget Series")
            #expect(remaining.episode == 3)
            #expect(reader.filesRead == 129)
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-path-plan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, at folder: URL, name: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }
}
