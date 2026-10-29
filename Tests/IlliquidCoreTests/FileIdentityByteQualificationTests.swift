import Foundation
#if canImport(Darwin)
import PR199NativeFixtures
import Darwin
#endif
import Testing
@testable import IlliquidCore

@Suite("File persistence key byte compatibility")
struct FileIdentityByteQualificationTests {
    // normalize is deliberately unchanged by the optimization. Compare bytes:
    // String equality alone would accept different Unicode representations.
    private func expectOriginalBytes(_ url: URL) {
        let expected = NormalizedFileURL.normalize(url)?.path.mapBytes
        let actual = NormalizedFileURL.persistenceKey(for: url)?.mapBytes
        #expect(actual == expected, "URL: \(url.absoluteString)")
    }

    // Only native NSURL references need this preflight. Direct Swift URL
    // fixtures always reach the unchanged oracle above.
    private struct BridgeCounts {
        var parity = 0
        var unresolved = 0
    }

    private func expectNativeBytes(_ native: NSURL, allowUnresolved: Bool = false,
                                   counts: inout BridgeCounts) {
        #if canImport(Darwin)
        phase("native.classify.before")
        if native.isFileReferenceURL() {
            phase("native.resolve.before")
            if native.filePathURL == nil {
                #expect(allowUnresolved, "Unexpected unresolved native reference")
                counts.unresolved += 1
                return
            }
        }
        #endif
        phase("bridge.before")
        let url = native as URL
        phase("bridge.after")
        expectOriginalBytes(url)
        phase("oracle.after")
        counts.parity += 1
    }

    // Diagnostics never inspect/describe a native URL, which could bridge it.
    private func phase(_ message: String) {
        guard ProcessInfo.processInfo.environment["PR199_BRIDGE_PHASES"] == "1" else { return }
        FileHandle.standardError.write(Data(("PR199 phase " + message + "\n").utf8))
    }

    #if canImport(Darwin)
    // Independent filesystem assertion: realpath follows actual symlinks on
    // both existing targets. It never uses the production normalization oracle.
    private func canonicalBytes(_ path: String) throws -> [UInt8] {
        let pointer = try #require(path.withCString { realpath($0, nil) })
        defer { free(pointer) }
        return UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                                   count: strlen(pointer)).map { $0 }
    }

    private func referencePath(_ reference: NSURL) throws -> String {
        return try #require(reference.filePathURL).path
    }

    private func expectNativePath(_ path: String, isDirectory: Bool,
                                  allowUnresolved: Bool = false, counts: inout BridgeCounts) {
        // Nullable Objective-C boundary observes nil before Swift assumes an object exists.
        guard let object = PR199CreatePath(path, isDirectory) else {
            phase("native.constructor.nil")
            #expect(allowUnresolved, "Unexpected nil native path constructor: \(path)")
            counts.unresolved += 1
            return
        }
        expectNativeBytes(object as! NSURL, allowUnresolved: allowUnresolved, counts: &counts)
    }
    #else
    private func expectNativePath(_ path: String, isDirectory: Bool, allowUnresolved: Bool = false, counts: inout BridgeCounts) {
        expectNativeBytes(NSURL(fileURLWithPath: path, isDirectory: isDirectory), allowUnresolved: allowUnresolved, counts: &counts)
    }
    #endif

    private func report(_ counts: BridgeCounts, suite: String) {
        print("PR199 \(suite): nativeParity=\(counts.parity) unresolvedNativeReferences=\(counts.unresolved)")
    }

    #if canImport(Darwin)
    @Test func liveNativeReferencesPreserveBytesAcrossRename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        var counts = BridgeCounts()
        defer { report(counts, suite: "liveNativeReferences") }
        for directory in [false, true] {
            let original = root.appendingPathComponent(directory ? "directory" : "file", isDirectory: directory)
            if directory {
                try fm.createDirectory(at: original, withIntermediateDirectories: false)
            } else {
                try Data("reference fixture".utf8).write(to: original)
            }
            let reference = try #require(PR199CreateReference(original.path, directory)) as! NSURL
            #expect(reference.isFileReferenceURL())
            let before = try referencePath(reference)
            #expect(try canonicalBytes(before) == canonicalBytes(original.path))
            expectNativeBytes(reference, counts: &counts)
            let renamed = root.appendingPathComponent(directory ? "renamed-directory" : "renamed-file", isDirectory: directory)
            try fm.moveItem(at: original, to: renamed)
            let after = try referencePath(reference)
            #expect(try canonicalBytes(after) == canonicalBytes(renamed.path))
            expectNativeBytes(reference, counts: &counts)
        }
        #expect(counts.parity == 4)
        #expect(counts.unresolved == 0)
    }
    #endif

    @Test func pathConstructorsPreserveSpecialFormsAndUnicode() {
        var counts = BridgeCounts()
        defer { report(counts, suite: "pathConstructorsPreserveSpecialFormsAndUnicode") }
        let paths = [
            "/", "//", "///", "/tmp", "/tmp/", "/tmp//", "/tmp///",
            "//tmp/Film.mkv", "/tmp//Season///Film.mkv",
            "/tmp/./Film.mkv", "/tmp/Season/../Film.mkv",
            "/tmp/../../Film.mkv", "/tmp/..", "/tmp/../",
            "/tmp/~", "/tmp/~/Film.mkv", "/tmp/100% complete.mkv",
            "/tmp/%2F%2E%25.mkv", "/tmp/Film #1?.mkv",
            "/tmp/a:b;c=d&e+f.mkv", "/tmp/back\\slash.mkv",
            "/tmp/\tfilm\n.mkv",
            "/tmp/Caf\u{00E9}.mkv", "/tmp/Cafe\u{0301}.mkv",
            "/tmp/A\u{030A}land/\u{65E5}\u{672C}\u{8A9E}.mkv",
            "/tmp/\u{1F3AC}\u{FE0F}/\u{AC00}.mkv",
            "/tmp/\u{1100}\u{1161}/\u{212A}.mkv",
            "/.file/id=1.2", "/.file/id=1.2/",
            "/.file/id=not-a-real-reference",
            "/tmp/../.file/id=not-a-real-reference",
            "/tmp/.file/id=ordinary-filename",
        ]
        for path in paths {
            for directory in [false, true] {
                phase("path=\(path.debugDescription) directory=\(directory) direct.before")
                expectOriginalBytes(URL(fileURLWithPath: path, isDirectory: directory))
                phase("direct.after native.constructor.before")
                expectNativePath(path, isDirectory: directory,
                                  allowUnresolved: path == "/.file/id=1.2" || path == "/.file/id=1.2/"
                                      || path == "/.file/id=not-a-real-reference"
                                      || path == "/tmp/../.file/id=not-a-real-reference",
                                  counts: &counts)
            }
        }
    }

    @Test func everyAsciiByteAndItsPercentEncodingPreserveKeyBytes() throws {
        var counts = BridgeCounts()
        defer { report(counts, suite: "everyAsciiByteAndItsPercentEncodingPreserveKeyBytes") }
        for value in 0..<128 {
            let scalar = try #require(UnicodeScalar(value))
            let text = String(scalar)
            // NUL is not a valid filesystem path component. Exercise it via
            // percent-encoded URL strings below, avoiding invalid NSURL objects.
            if value != 0 {
                for directory in [false, true] {
                    expectOriginalBytes(URL(fileURLWithPath: "/tmp/A\(text)Z.mkv", isDirectory: directory))
                    expectNativePath("/tmp/A\(text)Z.mkv", isDirectory: directory, counts: &counts)
                }
            }
            let hex = String(value, radix: 16, uppercase: true)
            let escape = "%" + (hex.count == 1 ? "0" : "") + hex
            for encoded in [
                "file:///tmp/A\(escape)Z.mkv",
                "file:///tmp/A%25\(hex)Z.mkv",
                "file://LOCALHOST/tmp/A\(escape)Z.mkv/",
            ] {
                expectOriginalBytes(try #require(URL(string: encoded)))
                if let bridged = NSURL(string: encoded) { expectNativeBytes(bridged, counts: &counts) }
            }
        }
    }

    @Test func relativeReferencesAndAuthoritiesKeepTheOriginalContract() throws {
        var counts = BridgeCounts()
        defer { report(counts, suite: "relativeReferencesAndAuthoritiesKeepTheOriginalContract") }
        let bases = try [
            "file:///Movies/Season/",
            "file:///Movies/Season.mkv",
            "file://LOCALHOST/Movies/Season/",
            "file:////Movies//Season/",
            "file://archive.example.invalid/Movies/Season/",
            "file://user:password@localhost/Movies/Season/",
            "https://example.invalid/Movies/Season/",
        ].map { try #require(URL(string: $0)) }
        let references = [
            "", ".", "..", "../", "../../", "../../../",
            "Episode.mkv", "./Episode.mkv", "../Episode.mkv",
            "Season/../Episode%202.mkv", "/Movies/./Episode.mkv",
            "?edition=1", "#chapter", "Episode.mkv?edition=1#chapter",
            "A%2FB.mkv", "A%252FB.mkv", "%2E/%2E%2E/Episode.mkv",
            "Cafe%CC%81.mkv", "Caf%C3%A9.mkv",
            "/.file/id=not-a-real-reference",
            "/%2Efile/id%3Dnot-a-real-reference",
        ]
        for base in bases {
            for reference in references {
                // Foundation versions differ on accepting an empty relative
                // reference. Compare every URL that can actually be constructed.
                if let url = URL(string: reference, relativeTo: base) {
                    expectOriginalBytes(url)
                } else {
                    #expect(reference.isEmpty)
                }
                if let bridged = NSURL(string: reference, relativeTo: base) {
                    expectNativeBytes(bridged,
                                      allowUnresolved: reference == "/.file/id=not-a-real-reference"
                                          || reference == "/%2Efile/id%3Dnot-a-real-reference",
                                      counts: &counts)
                }
            }
        }
        for raw in [
            "file://media.example.invalid/Movies/Film.mkv",
            "file://localhost.example/Movies/Film.mkv",
            "file://127.0.0.1/Movies/Film.mkv",
            "file://[::1]/Movies/Film.mkv",
            "file://user@localhost/Movies/Film.mkv",
            "file://user:password@localhost/Movies/Film.mkv",
            "file://localhost:0/Movies/Film.mkv",
            "file://localhost:1234/Movies/Film.mkv",
            "file:relative.mkv", "file:", "file://", "file://localhost",
            "https://example.invalid/Film.mkv", "ftp://example.invalid/Film.mkv",
        ] {
            let url = try #require(URL(string: raw))
            #expect(NormalizedFileURL.persistenceKey(for: url) == nil)
            expectOriginalBytes(url)
        }
    }

    @Test func deterministicPathCombinationsMatchByBytes() throws {
        var counts = BridgeCounts()
        defer { report(counts, suite: "deterministicPathCombinationsMatchByBytes") }
        let prefixes = ["file:///", "file:/", "file://localhost/", "file://LOCALHOST/", "file:////"]
        let segments = [
            "Movies", "Movies/Season/..", "Movies//Season",
            "Movies/./Season", "Movies/../Movies", "Movies/../../Movies",
            "Movies/%2E/Season", "Movies/%2E%2E/Movies",
            "Media%20Share", "100%25", "A%2FB", "A%252FB",
            "Caf%C3%A9", "Cafe%CC%81", "%E6%97%A5%E6%9C%AC",
        ]
        let filenames = [
            "Episode.mkv", "Episode%202.mkv", "A%23B%3F.mkv",
            "A%00B.mkv", "A%5CB.mkv", "%7E.mkv", ".", "..", "",
        ]
        let suffixes = ["", "/", "//", "?copy=1#chapter"]
        for prefix in prefixes {
            for segment in segments {
                for filename in filenames {
                    for suffix in suffixes {
                        let raw = prefix + segment + "/" + filename + suffix
                        expectOriginalBytes(try #require(URL(string: raw)))
                        if let bridged = NSURL(string: raw) { expectNativeBytes(bridged, counts: &counts) }
                    }
                }
            }
        }
    }
}

private extension String {
    var mapBytes: [UInt8] { Array(utf8) }
}
