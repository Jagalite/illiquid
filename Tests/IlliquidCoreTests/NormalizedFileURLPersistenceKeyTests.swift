import Foundation
import Testing
@testable import IlliquidCore
#if os(macOS)
import CoreFoundation
#endif

@Suite("Normalized file persistence keys")
struct NormalizedFileURLPersistenceKeyTests {
    @Test func ordinaryASCIIPathsKeepExactBytes() throws {
        for path in [
            "/Media/Episode 2.mkv",
            "/Volumes/External Media/Season 1/Episode 10.mkv",
            "/Media/100% complete #2?.mkv",
            "/Media/a\\b:take;2.mkv",
            "/Media/~user/~/Episode.mkv",
        ] {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            expectKeyMatchesNormalization(url)
            #expect(NormalizedFileURL.persistenceKey(for: url).map { Array($0.utf8) }
                == Array(path.utf8))
        }
    }

    @Test func directoryFlagsAndSlashShapesFollowTheConstructor() throws {
        for path in [
            "/", "//", "///", "/Media", "/Media/", "/Media//", "/Media///",
            "/Media//Episode.mkv", "//Media/Episode.mkv", "/Media/./Season/../",
        ] {
            for isDirectory in [false, true] {
                expectKeyMatchesNormalization(URL(fileURLWithPath: path, isDirectory: isDirectory))
                expectKeyMatchesNormalization(NSURL(fileURLWithPath: path, isDirectory: isDirectory) as URL)
            }
        }
        for spelling in [
            "file:/.", "file:/..", "file:///./", "file:///../", "file:////",
            "file:///Media/.", "file:///Media/..", "file:///Media///?copy=1#part",
        ] {
            expectKeyMatchesNormalization(try #require(URL(string: spelling)))
        }
    }

    @Test func asciiNullsAndControlsPreservePlatformPathSemantics() throws {
        for value in [0, 1, 9, 10, 13, 31, 127] {
            let control = String(try #require(UnicodeScalar(value)))
            for path in ["/Media/a" + control + "b.mkv", "/Media/end.mkv" + control] {
                for isDirectory in [false, true] {
                    expectKeyMatchesNormalization(URL(fileURLWithPath: path, isDirectory: isDirectory))
                }
            }
            let escaped = String(format: "%%%02X", value)
            for spelling in ["file:///Media/a" + escaped + "b.mkv", "file:///Media/end.mkv" + escaped] {
                expectKeyMatchesNormalization(try #require(URL(string: spelling)))
            }
        }
    }

    @Test func percentEscapesRemainPathDataAfterNormalization() throws {
        for component in [
            "%2F", "%2f", "%00", "%252F", "%2500", "%2E", "%2e%2e",
            "%252E%252E", "%41", "%C3%A9", "%CC%81", "100%25", "a%23b%3Fc",
        ] {
            expectKeyMatchesNormalization(try #require(URL(string: "file:///Media/" + component)))
            expectKeyMatchesNormalization(URL(fileURLWithPath: "/Media/" + component, isDirectory: false))
        }
        // A literal percent escape in a path constructor is distinct from the
        // equivalent escaped character in a URL string.
        let literal = URL(fileURLWithPath: "/Media/%41.mkv", isDirectory: false)
        let encoded = try #require(URL(string: "file:///Media/%41.mkv"))
        #expect(!NormalizedFileURL.representsSameFile(literal, encoded))
    }

    @Test func localAuthoritiesQueriesAndFragmentsKeepTheirIdentity() throws {
        let ordinary = URL(fileURLWithPath: "/Media/Episode 2.mkv", isDirectory: false)
        for spelling in [
            "file:///Media/Episode%202.mkv?edition=1#chapter",
            "file://localhost/Media/Episode%202.mkv",
            "file://LOCALHOST/Media/Season/../Episode%202.mkv?copy=1#part",
            "FILE:///Media/Episode%202.mkv",
        ] {
            let url = try #require(URL(string: spelling))
            expectKeyMatchesNormalization(url)
            #expect(NormalizedFileURL.representsSameFile(url, ordinary))
        }
    }

    @Test func unsupportedAuthoritiesAndSchemesStillHaveNoKey() throws {
        for spelling in [
            "file://remote.example/Media/Movie.mkv",
            "file://localhost.example/Media/Movie.mkv",
            "file://127.0.0.1/Media/Movie.mkv",
            "file://[::1]/Media/Movie.mkv",
            "file://user@localhost/Media/Movie.mkv",
            "file://user:secret@localhost/Media/Movie.mkv",
            "file://localhost:1234/Media/Movie.mkv",
            "https://example.invalid/Media/Movie.mkv",
            "ftp://example.invalid/Media/Movie.mkv",
            "file:relative.mkv", "file:", "file://", "file://localhost",
        ] {
            let url = try #require(URL(string: spelling))
            expectKeyMatchesNormalization(url)
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
            #expect(!NormalizedFileURL.representsSameFile(url, url))
        }
    }

    @Test func relativeURLsResolveAndValidateTheirBases() throws {
        let localBase = URL(fileURLWithPath: "/Media/Season", isDirectory: true)
        let localFileBase = URL(fileURLWithPath: "/Media/Season/movie.mkv", isDirectory: false)
        let nestedBase = try #require(URL(string: "../Other/", relativeTo: localBase))
        let remoteBase = try #require(URL(string: "file://remote.example/Media/"))
        let credentialBase = try #require(URL(string: "file://user@localhost/Media/"))
        let webBase = try #require(URL(string: "https://example.invalid/Media/"))
        for base in [localBase, localFileBase, nestedBase, remoteBase, credentialBase, webBase] {
            for path in ["Episode 2.mkv", "../Movie.mkv", "../../", "./%2F.mkv", "/Media/Other.mkv"] {
                expectKeyMatchesNormalization(try #require(URL(string: path, relativeTo: base)))
                for isDirectory in [false, true] {
                    expectKeyMatchesNormalization(URL(fileURLWithPath: path, isDirectory: isDirectory, relativeTo: base))
                }
            }
        }
        let inheritedRemote = try #require(URL(string: "Movie.mkv", relativeTo: remoteBase))
        #expect(NormalizedFileURL.persistenceKey(for: inheritedRemote) == nil)
    }

    @Test func UnicodeKeysUseThePlatformConstructorAsTheByteOracle() throws {
        // NSString file-path conversion can use a platform-specific Unicode
        // representation. Canonically equivalent Swift String equality cannot
        // verify that persistence bytes are unchanged.
        for name in [
            "Caf\u{00E9}", "Cafe\u{0301}", "\u{00C5}", "A\u{030A}", "\u{212B}",
            "\u{2126}", "\u{212A}", "\u{F900}", "\u{AC00}", "\u{1100}\u{1161}",
            "e\u{0340}", "e\u{0341}", "東京", "👩\u{200D}💻", "\u{2000}",
        ] {
            let path = "/Media/" + name + ".mkv"
            for isDirectory in [false, true] {
                expectKeyMatchesNormalization(URL(fileURLWithPath: path, isDirectory: isDirectory))
                expectKeyMatchesNormalization(NSURL(fileURLWithPath: path, isDirectory: isDirectory) as URL)
            }
            expectKeyMatchesNormalization(try #require(URL(string: "file://" + path)))
        }
        for spelling in [
            "file:///Media/Cafe%CC%81.mkv", "file:///Media/Caf%C3%A9.mkv",
            "file:///Media/%E2%84%AB.mkv", "file:///Media/A%CC%8A.mkv",
        ] {
            expectKeyMatchesNormalization(try #require(URL(string: spelling)))
        }
    }

    @Test func bridgedAndDataRepresentationURLsKeepExactKeyBytes() throws {
        let base = URL(fileURLWithPath: "/Media/Season", isDirectory: true)
        for spelling in [
            "file:///Media/Episode%202.mkv", "file://localhost/Media/a%23b%3Fc.mkv",
            "file:///Media/%252F.mkv", "file:///Media/Cafe%CC%81.mkv",
            "../Episode%202.mkv", "../%2E%2E/Movie.mkv?copy=1#part",
        ] {
            expectKeyMatchesNormalization(try #require(NSURL(string: spelling, relativeTo: base)) as URL)
            expectKeyMatchesNormalization(try #require(URL(dataRepresentation: Data(spelling.utf8), relativeTo: base)))
        }
    }

    @Test func fileReferenceLikePathsRetainConstructorFallback() throws {
        // Percent decoding or lexical standardization can reveal a reference
        // prefix only after the input URL was originally constructed.
        for spelling in [
            "file:///.file/id=0.0", "file:///.file/id=6571367.2773272",
            "file:///%2Efile/id=0.0", "file:///%2Efile/id%3D0.0",
            "file:///.file/./id=0.0", "file:////.file/id=0.0",
            "file:///.file/id=0.0/", "file:///.file/id=0.0?copy=1#part",
        ] {
            expectKeyMatchesNormalization(try #require(URL(string: spelling)))
        }
    }

    #if os(macOS)
    @Test(arguments: [false, true])
    func reachableFileReferencesMatchBeforeAndAfterRename(isDirectory: Bool) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "IlliquidPersistenceKey-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let original = root.appendingPathComponent("original", isDirectory: isDirectory)
        let renamed = root.appendingPathComponent("renamed", isDirectory: isDirectory)
        if isDirectory {
            try manager.createDirectory(at: original, withIntermediateDirectories: false)
        } else {
            try Data([0x61]).write(to: original)
        }

        // Capture the native reference spelling before bridging it to Swift URL,
        // which may eagerly convert file references to file paths.
        var creationError: Unmanaged<CFError>?
        defer { creationError?.release() }
        let reference = try #require(CFURLCreateFileReferenceURL(
            kCFAllocatorDefault, original as CFURL, &creationError)).takeRetainedValue()
        #expect(CFURLIsFileReferenceURL(reference))
        let spelling = try #require(CFURLGetString(reference)) as String
        let before = try #require(URL(string: spelling))
        expectKeyMatchesNormalization(before)
        #expect(NormalizedFileURL.persistenceKey(for: before) != nil)

        try manager.moveItem(at: original, to: renamed)
        // Recreate the URL after the rename; no resource mutation occurs
        // between the oracle and candidate calls for either phase.
        let after = try #require(URL(string: spelling))
        expectKeyMatchesNormalization(after)
        #expect(NormalizedFileURL.persistenceKey(for: after) != nil)
        expectKeyMatchesNormalization(try #require(NSURL(string: spelling)) as URL)
        let foundationPath = try #require((after as NSURL).filePathURL)
        #expect(NormalizedFileURL.persistenceKey(for: after).map { Array($0.utf8) }
            == (NormalizedFileURL.normalize(foundationPath)?.path).map { Array($0.utf8) })
    }
    #endif

    private func expectKeyMatchesNormalization(_ url: URL) {
        let expected = NormalizedFileURL.normalize(url)?.path
        let actual = NormalizedFileURL.persistenceKey(for: url)
        #expect(actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
            "Key bytes changed for \(url.absoluteString)")
    }
}
