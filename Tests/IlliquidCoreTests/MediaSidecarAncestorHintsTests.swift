import Foundation
import Testing
@testable import IlliquidCore

@Suite("Sidecar ancestor metadata reuse")
struct MediaSidecarAncestorHintsTests {
    @Test func siblingMappingsAndOwnNFOsCannotReplaceSharedDefaults() throws {
        try withFixture { root in
            let season = root.appendingPathComponent("Season 2", isDirectory: true)
            try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
            try write("""
                <tvshow><title>Root Series</title><year>2010</year>
                <uniqueid type="tvdb">101</uniqueid></tvshow>
                """, at: root, name: "tvshow.nfo")
            try write("""
                title: Root Plex
                season: 5
                tmdbid: 202
                ep: S04E06-E08: Season 2/first.mkv
                ep: E09: Season 2/second.mkv
                """, at: root, name: ".plexmatch")
            let inheritedTitle = "Inherited Cafe\u{0301}"
            try write("""
                <tvshow><title>\(inheritedTitle)</title><year>2011</year>
                <uniqueid type="tvdb">303</uniqueid></tvshow>
                """, at: season, name: "tvshow.nfo")
            try write("season: 7\ntmdbid: 404", at: season, name: ".plexmatch")
            try write("""
                <episodedetails><showtitle>Own Series</showtitle><title>Own Finale</title>
                <season>9</season><episode>12</episode></episodedetails>
                """, at: season, name: "first.nfo")

            let reader = MediaSidecarReader()
            var first = try reader.recognize(season.appendingPathComponent("first.mkv"), within: root)
            #expect(first.kind == .episode)
            #expect(first.title == "Own Series")
            #expect(first.season == 9 && first.episode == 12 && first.lastEpisode == nil)
            #expect(first.episodeTitle == "Own Finale")
            #expect(first.catalogIDs == ["tvdb-303", "tmdb-404"])
            #expect(reader.filesRead == 5)

            // A returned value can share array storage with cached metadata,
            // but caller mutation must not change the next sibling's sources.
            first.metadataSources.append("caller")
            #expect(first.metadataSources == [".plexmatch", "NFO", "caller"])
            for (name, episode) in [("second.mkv", 9), ("S02E13.mkv", 13), ("second.mkv", 9)] {
                let file = season.appendingPathComponent(name)
                let result = try reader.recognize(file, within: root)
                #expect(try result == MediaSidecarReader().recognize(file, within: root))
                #expect(result.kind == .episode)
                #expect(result.title.utf8.elementsEqual(inheritedTitle.utf8))
                #expect(result.year == 2011)
                // An implicit mapping takes the deepest ancestor's season,
                // not the first sibling's explicit mapping or own-file season.
                #expect(result.season == 7 && result.episode == episode)
                #expect(result.lastEpisode == nil && result.episodeTitle == nil)
                #expect(result.catalogIDs == ["tvdb-303", "tmdb-404"])
                #expect(result.metadataSources == [".plexmatch", "NFO"])
                #expect(reader.filesRead == 5)
            }

            let unmatched = season.appendingPathComponent("unmapped.mkv")
            let result = try reader.recognize(unmatched, within: root)
            #expect(result == MediaNameRecognition.recognize(relativePath: unmatched.path))
            #expect(result.kind == .unknown && result.episode == nil)
            #expect(reader.filesRead == 5)
        }
    }

    @Test func ancestorEditsAndDeletionRetainTheReadersExistingSnapshot() throws {
        try withFixture { root in
            try write("""
                <tvshow><title>Before NFO</title><year>2001</year>
                <uniqueid type="tvdb">9</uniqueid></tvshow>
                """, at: root, name: "tvshow.nfo")
            try write("title: Before Plex\nseason: 3\ntmdbid: 41", at: root, name: ".plexmatch")
            let reader = MediaSidecarReader()
            _ = try reader.recognize(root.appendingPathComponent("Filename - S01E01.mkv"), within: root)
            #expect(reader.filesRead == 2)

            try write("""
                <tvshow><title>After NFO</title><year>2022</year>
                <uniqueid type="tvdb">19</uniqueid></tvshow>
                """, at: root, name: "tvshow.nfo")
            try write("title: After Plex\nseason: 8\ntmdbid: 51", at: root, name: ".plexmatch")
            let second = root.appendingPathComponent("Filename - S01E02.mkv")
            let cached = try reader.recognize(second, within: root)
            #expect(cached.title == "Before Plex" && cached.year == 2001)
            #expect(cached.season == 3 && cached.episode == 2)
            #expect(cached.catalogIDs == ["tvdb-9", "tmdb-41"])
            let fresh = try MediaSidecarReader().recognize(second, within: root)
            #expect(fresh.title == "After Plex" && fresh.year == 2022)
            #expect(fresh.season == 8 && fresh.episode == 2)
            #expect(fresh.catalogIDs == ["tvdb-19", "tmdb-51"])

            try FileManager.default.removeItem(at: root.appendingPathComponent("tvshow.nfo"))
            try FileManager.default.removeItem(at: root.appendingPathComponent(".plexmatch"))
            let third = root.appendingPathComponent("Filename - S01E03.mkv")
            let afterDeletion = try reader.recognize(third, within: root)
            #expect(afterDeletion.title == "Before Plex" && afterDeletion.year == 2001)
            #expect(afterDeletion.season == 3 && afterDeletion.episode == 3)
            #expect(afterDeletion.catalogIDs == ["tvdb-9", "tmdb-41"])
            #expect(afterDeletion.metadataSources == [".plexmatch", "NFO"])
            #expect(try MediaSidecarReader().recognize(third, within: root)
                    == MediaNameRecognition.recognize(relativePath: third.path))
            #expect(reader.filesRead == 2)
        }
    }

    @Test func canceledParentChangeCannotPublishIncompleteAncestorMetadata() throws {
        try withFixture { root in
            try write("""
                <tvshow><title>Outer Series</title><year>2000</year>
                <uniqueid type="tvdb">10</uniqueid></tvshow>
                """, at: root, name: "tvshow.nfo")
            let left = root.appendingPathComponent("left", isDirectory: true)
            let right = root.appendingPathComponent("right", isDirectory: true)
            for folder in [left, right] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try write("title: Left Series\nseason: 2\ntmdbid: 20", at: left, name: ".plexmatch")
            try write("title: Before Cancellation\nseason: 4\ntmdbid: 30", at: right, name: ".plexmatch")
            let reader = MediaSidecarReader()
            _ = try reader.recognize(left.appendingPathComponent("S01E01.mkv"), within: root)
            #expect(reader.filesRead == 2)

            // Two discovery checkpoints and the root read have completed;
            // stop immediately before the right parent's sidecars are read.
            var checkpoints = 0
            #expect(throws: CancellationError.self) {
                try reader.recognize(right.appendingPathComponent("S01E01.mkv"), within: root) {
                    checkpoints += 1
                    if checkpoints == 4 { throw CancellationError() }
                }
            }
            #expect(checkpoints == 4 && reader.filesRead == 2)
            try write("title: After Cancellation\nseason: 5\ntmdbid: 99", at: right, name: ".plexmatch")

            let retry = right.appendingPathComponent("S01E02.mkv")
            let result = try reader.recognize(retry, within: root)
            #expect(try result == MediaSidecarReader().recognize(retry, within: root))
            #expect(result.title == "After Cancellation" && result.year == 2000)
            #expect(result.season == 5 && result.episode == 2)
            #expect(result.catalogIDs == ["tvdb-10", "tmdb-99"])
            #expect(reader.filesRead == 3)

            let previousParent = left.appendingPathComponent("S01E03.mkv")
            let previous = try reader.recognize(previousParent, within: root)
            #expect(previous.title == "Left Series" && previous.year == 2000)
            #expect(previous.season == 2 && previous.episode == 3)
            #expect(previous.catalogIDs == ["tvdb-10", "tmdb-20"])
            #expect(reader.filesRead == 3)
        }
    }

    @Test func reentrantRecognitionKeepsEachParentsMetadata() throws {
        // Exercise replacing, clearing, and introducing ancestor metadata while
        // the outer call is paused at its first cancellation checkpoint.
        for (outerHasHints, nestedHasHints) in [(true, true), (true, false), (false, true)] {
            try withFixture { root in
                let outerParent = root.appendingPathComponent("left", isDirectory: true)
                let nestedParent = root.appendingPathComponent("right", isDirectory: true)
                for folder in [outerParent, nestedParent] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                if outerHasHints {
                    try write("title: Left Series\nseason: 2\ntmdbid: 20", at: outerParent, name: ".plexmatch")
                }
                if nestedHasHints {
                    try write("title: Right Series\nseason: 4\ntmdbid: 30", at: nestedParent, name: ".plexmatch")
                }
                let outerFile = outerParent.appendingPathComponent("Filename Left - S01E02.mkv")
                let nestedFile = nestedParent.appendingPathComponent("Filename Right - S01E03.mkv")
                let expectedOuter = try MediaSidecarReader().recognize(outerFile, within: root)
                let expectedNested = try MediaSidecarReader().recognize(nestedFile, within: root)
                let reader = MediaSidecarReader()
                _ = try reader.recognize(outerFile, within: root)

                var didReenter = false
                var nestedResult: RecognizedMediaName?
                let outerResult = try reader.recognize(outerFile, within: root) {
                    if !didReenter {
                        didReenter = true
                        nestedResult = try reader.recognize(nestedFile, within: root)
                    }
                }
                #expect(didReenter)
                #expect(outerResult == expectedOuter)
                #expect(nestedResult == expectedNested)
                #expect(try reader.recognize(nestedFile, within: root) == expectedNested)
                #expect(try reader.recognize(outerFile, within: root) == expectedOuter)
                #expect(reader.filesRead == (outerHasHints ? 1 : 0) + (nestedHasHints ? 1 : 0))
            }
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-ancestor-hints-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, at folder: URL, name: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }
}
