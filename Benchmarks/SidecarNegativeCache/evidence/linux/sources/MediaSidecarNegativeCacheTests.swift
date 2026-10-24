import Foundation
import Testing
@testable import IlliquidCore

@Suite("Sidecar negative cache")
struct MediaSidecarNegativeCacheTests {
    @Test(arguments: ["absent", "empty", "malformed", "unsupported", "oversized", "directory", "symlink"])
    func unusableSidecarsStayCachedUntilANewScan(_ kind: String) throws {
        try withFixture { root in
            let file = root.appendingPathComponent("clip.mkv")
            let sidecar = root.appendingPathComponent("clip.nfo")
            switch kind {
            case "absent": break
            case "empty": try Data().write(to: sidecar)
            case "malformed": try write("<movie><title>Broken", to: sidecar)
            case "unsupported": try write("<movie><plot>No identification fields</plot></movie>", to: sidecar)
            case "oversized":
                try Data(repeating: 65, count: MediaSidecarReader.maximumFileBytes + 1).write(to: sidecar)
            case "directory":
                try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
            case "symlink":
                let target = root.appendingPathComponent("target.nfo")
                try write("<movie><title>Symlink Target</title></movie>", to: target)
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
            default: Issue.record("Unexpected fixture: \(kind)")
            }

            let reader = MediaSidecarReader()
            let original = try reader.recognize(file, within: root)
            #expect(original == MediaNameRecognition.recognize(relativePath: file.path))
            let originalReads = reader.filesRead
            if kind != "absent" { try FileManager.default.removeItem(at: sidecar) }
            try write("<movie><title>New Sidecar</title></movie>", to: sidecar)

            #expect(try reader.recognize(file, within: root) == original)
            #expect(reader.filesRead == originalReads)
            let fresh = MediaSidecarReader()
            #expect(try fresh.recognize(file, within: root).title == "New Sidecar")
            #expect(fresh.filesRead == 1)
        }
    }

    @Test func canonicalEquivalentNegativeKeysKeepTheExistingStringSemantics() throws {
        try withFixture { root in
            let original = try #require(URL(string: root.absoluteString + "Caf%C3%A9.mkv"))
            let alternate = try #require(URL(string: root.absoluteString + "Cafe%CC%81.mkv"))
            let originalSidecar = original.deletingPathExtension().appendingPathExtension("nfo")
            let alternateSidecar = alternate.deletingPathExtension().appendingPathExtension("nfo")
            // Dictionary and Set keys both use Swift String equality. The
            // filesystem can treat these spellings as aliases or distinct paths.
            #expect(originalSidecar.path == alternateSidecar.path)
            let reader = MediaSidecarReader()
            _ = try reader.recognize(original, within: root)
            try write("<movie><title>Added After Lookup</title></movie>", to: alternateSidecar)

            #expect(try reader.recognize(alternate, within: root)
                    == MediaNameRecognition.recognize(relativePath: alternate.path))
            #expect(reader.filesRead == 0)
            #expect(try MediaSidecarReader().recognize(alternate, within: root).title == "Added After Lookup")
        }
    }

    @Test func positiveAndNegativeEntriesShareTheExactEntryLimit() throws {
        try withFixture { root in
            try write("<tvshow><title>NFO Series</title><year>2001</year></tvshow>",
                      to: root.appendingPathComponent("tvshow.nfo"))
            try write("title: Cached Series", to: root.appendingPathComponent(".plexmatch"))
            let reader = MediaSidecarReader()
            // Every sibling reuses tvshow.nfo and .plexmatch. Their show hints
            // suppress movie.nfo probes. These two positive shared keys plus
            // 49,997 absent own-file NFOs leave exactly one entry available.
            for index in 0..<49_997 {
                _ = try reader.recognize(root.appendingPathComponent("clip\(index).mkv"), within: root)
            }
            #expect(reader.filesRead == 2)

            let admitted = root.appendingPathComponent("admitted.mkv")
            try write("<movie><title>Last Admitted Film</title></movie>",
                      to: admitted.deletingPathExtension().appendingPathExtension("nfo"))
            let accepted = try reader.recognize(admitted, within: root)
            #expect(accepted.title == "Last Admitted Film")
            #expect(reader.filesRead == 3)

            let blocked = root.appendingPathComponent("S01E02.mkv")
            try write("<movie><title>Past The Limit</title></movie>",
                      to: blocked.deletingPathExtension().appendingPathExtension("nfo"))
            let fallback = try reader.recognize(blocked, within: root)
            #expect(fallback.title == "Cached Series")
            #expect(fallback.year == 2001)
            #expect(fallback.episode == 2)
            #expect(reader.filesRead == 3)
            #expect(try MediaSidecarReader().recognize(blocked, within: root).title == "Past The Limit")

            // Admission being closed must not hide already cached metadata.
            try write("<movie><title>Changed On Disk</title></movie>",
                      to: admitted.deletingPathExtension().appendingPathExtension("nfo"))
            #expect(try reader.recognize(admitted, within: root) == accepted)
            #expect(reader.filesRead == 3)
        }
    }

    @Test func rejectedContentsConsumeTheByteBudgetAndCachedMetadataRemainsUsable() throws {
        try withFixture { root in
            let show = "<tvshow><title>NFO Series</title><year>2001</year></tvshow>"
            let plex = "title: Cached Series"
            let own = "<movie><title>Cached Film</title></movie>"
            try write(show, to: root.appendingPathComponent("tvshow.nfo"))
            try write(plex, to: root.appendingPathComponent(".plexmatch"))
            try write(own, to: root.appendingPathComponent("cached.nfo"))
            let reader = MediaSidecarReader()
            let cachedFile = root.appendingPathComponent("cached.mkv")
            let cached = try reader.recognize(cachedFile, within: root)
            #expect(cached.title == "Cached Film")
            #expect(reader.filesRead == 3)

            // Rejected documents count toward the same 16 MiB read budget as
            // successful parses. End at the exact boundary, including the three
            // positive entries loaded above.
            let alreadyRead = show.utf8.count + plex.utf8.count + own.utf8.count
            for index in 0..<128 {
                let bytes = MediaSidecarReader.maximumFileBytes - (index == 0 ? alreadyRead : 0)
                try Data(repeating: 65, count: bytes).write(to: root.appendingPathComponent("invalid\(index).nfo"))
                _ = try reader.recognize(root.appendingPathComponent("invalid\(index).mkv"), within: root)
            }
            #expect(reader.filesRead == 131)

            let lateFile = root.appendingPathComponent("S01E03.mkv")
            try write("<movie><title>Beyond Byte Budget</title></movie>",
                      to: lateFile.deletingPathExtension().appendingPathExtension("nfo"))
            let fallback = try reader.recognize(lateFile, within: root)
            #expect(fallback.title == "Cached Series")
            #expect(fallback.year == 2001)
            #expect(fallback.episode == 3)
            try FileManager.default.removeItem(at: root.appendingPathComponent("cached.nfo"))
            #expect(try reader.recognize(cachedFile, within: root) == cached)
            #expect(reader.filesRead == 131)
            #expect(try MediaSidecarReader().recognize(lateFile, within: root).title == "Beyond Byte Budget")
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-negative-cache-" + UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
