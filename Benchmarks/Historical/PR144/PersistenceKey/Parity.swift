import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Compile this driver separately from IlliquidCore. normalize(_:) is unchanged
// by the persistence-key optimization and supplies the complete old round trip.
// Compare optional UTF-8 bytes: Swift String equality alone would conceal a
// change between composed and decomposed persistent representations on Darwin.
private struct Mismatch: Codable {
    let caseNumber: Int
    let family: String
    let input: String
    let absoluteURL: String
    let relativeURL: String
    let baseURL: String?
    let baselineKey: String?
    let candidateKey: String?
    let baselineUTF8: [UInt8]?
    let candidateUTF8: [UInt8]?
}

private struct Receipt: Codable {
    let schemaVersion: Int
    let passed: Bool
    let requiredCaseCount: Int
    let attemptedCaseCount: Int
    let comparedCaseCount: Int
    let constructionRejectionCount: Int
    let acceptedIdentityCount: Int
    let rejectedIdentityCount: Int
    let mismatchCount: Int
    let canonicallyEquivalentMismatchCount: Int
    let casesByFamily: [String: Int]
    let mismatchesByFamily: [String: Int]
    let baselineDigest: String
    let candidateDigest: String
    let mismatchExamples: [Mismatch]
}

private struct Digest {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325

    private mutating func append<Bytes: Sequence>(_ bytes: Bytes)
        where Bytes.Element == UInt8
    {
        for byte in bytes {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    mutating func appendField(_ string: String?) {
        guard let string else {
            append([UInt8(0)])
            return
        }
        append([UInt8(1)])
        append(String(string.utf8.count).utf8)
        append([UInt8(0)])
        append(string.utf8)
    }

    var hexadecimal: String { String(value, radix: 16) }
}

private struct ParitySuite {
    static let requiredCaseCount = 65_536
    private(set) var attemptedCaseCount = 0
    private var comparedCaseCount = 0
    private var constructionRejectionCount = 0
    private var acceptedIdentityCount = 0
    private var rejectedIdentityCount = 0
    private var mismatchCount = 0
    private var canonicallyEquivalentMismatchCount = 0
    private var casesByFamily: [String: Int] = [:]
    private var mismatchesByFamily: [String: Int] = [:]
    private var examplesByFamily: [String: Int] = [:]
    private var mismatchExamples: [Mismatch] = []
    private var baselineDigest = Digest()
    private var candidateDigest = Digest()

    mutating func check(_ url: URL?, family: String, input: String) {
        attemptedCaseCount += 1
        casesByFamily[family, default: 0] += 1
        baselineDigest.appendField(family)
        candidateDigest.appendField(family)
        baselineDigest.appendField(input)
        candidateDigest.appendField(input)
        baselineDigest.appendField(url?.absoluteString)
        candidateDigest.appendField(url?.absoluteString)
        guard let url else {
            constructionRejectionCount += 1
            return
        }

        comparedCaseCount += 1
        let baselineKey = NormalizedFileURL.normalize(url)?.path
        let candidateKey = NormalizedFileURL.persistenceKey(for: url)
        baselineDigest.appendField(baselineKey)
        candidateDigest.appendField(candidateKey)
        if baselineKey == nil {
            rejectedIdentityCount += 1
        } else {
            acceptedIdentityCount += 1
        }
        let baselineUTF8 = baselineKey.map { Array($0.utf8) }
        let candidateUTF8 = candidateKey.map { Array($0.utf8) }
        guard baselineUTF8 != candidateUTF8 else { return }

        mismatchCount += 1
        mismatchesByFamily[family, default: 0] += 1
        if baselineKey == candidateKey {
            canonicallyEquivalentMismatchCount += 1
        }
        // Keep several families visible when an early family has many failures.
        guard mismatchExamples.count < 30, examplesByFamily[family, default: 0] < 5 else {
            return
        }
        examplesByFamily[family, default: 0] += 1
        mismatchExamples.append(Mismatch(
            caseNumber: attemptedCaseCount,
            family: family,
            input: input,
            absoluteURL: url.absoluteString,
            relativeURL: url.relativeString,
            baseURL: url.baseURL?.absoluteString,
            baselineKey: baselineKey,
            candidateKey: candidateKey,
            baselineUTF8: baselineUTF8,
            candidateUTF8: candidateUTF8
        ))
    }

    var receipt: Receipt {
        Receipt(
            schemaVersion: 1,
            passed: attemptedCaseCount == Self.requiredCaseCount
                && comparedCaseCount >= 50_000 && mismatchCount == 0,
            requiredCaseCount: Self.requiredCaseCount,
            attemptedCaseCount: attemptedCaseCount,
            comparedCaseCount: comparedCaseCount,
            constructionRejectionCount: constructionRejectionCount,
            acceptedIdentityCount: acceptedIdentityCount,
            rejectedIdentityCount: rejectedIdentityCount,
            mismatchCount: mismatchCount,
            canonicallyEquivalentMismatchCount: canonicallyEquivalentMismatchCount,
            casesByFamily: casesByFamily,
            mismatchesByFamily: mismatchesByFamily,
            baselineDigest: baselineDigest.hexadecimal,
            candidateDigest: candidateDigest.hexadecimal,
            mismatchExamples: mismatchExamples
        )
    }
}

private struct Random {
    private var state: UInt64 = 0x5045_5253_4953_544b

    mutating func index(_ upperBound: Int) -> Int {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        mixed ^= mixed >> 31
        return Int(mixed % UInt64(upperBound))
    }
}

private let unicodeSegments = [
    "Caf\u{00e9}", "Cafe\u{0301}", "\u{00c5}", "A\u{030a}", "\u{212b}",
    "\u{2126}", "\u{03a9}", "\u{212a}", "K", "\u{ac00}", "\u{1100}\u{1161}",
    "\u{ac01}", "\u{1100}\u{1161}\u{11a8}", "\u{1f82}", "\u{0958}",
    "\u{0915}\u{093c}", "\u{1d15e}", "\u{2f800}", "\u{f900}",
    "a\u{0315}\u{0300}", "a\u{0300}\u{0315}", "\u{0301}",
    "日本語", "العربية", "👩‍💻", "🎬\u{fe0f}", "\u{200b}",
    "e" + String(repeating: "\u{0301}", count: 24),
]

private let pathSpellings = [
    "/", "//", "///", "////", "/Media", "/Media/", "/Media//", "/Media/.",
    "/Media/..", "/Media/../", "/./Media/Feature.mkv", "/../Media/Feature.mkv",
    "/../../Media/Feature.mkv", "/Media/./Feature.mkv", "/Media/Season/../Feature.mkv",
    "/Media//Season///Feature.mkv", "//Media/Feature.mkv", "///Media/Feature.mkv",
    "/Media/Feature.mkv", "/Media/feature.mkv", "/Media/FEATURE.MKV",
    "/Media/space%20name.mkv", "/Media/hash%23name.mkv", "/Media/query%3Fname.mkv",
    "/Media/semicolon;name.mkv", "/Media/colon:name.mkv", "/Media/%25name.mkv",
    "/Media/%252Fname.mkv", "/Media/%2Fname.mkv", "/Media/%2fname.mkv",
    "/Media/%00name.mkv", "/Media/name%00", "/Media/%2500name.mkv",
    "/Media/%2E/Feature.mkv", "/Media/%2E%2E/Feature.mkv", "/Media/.%2e/Feature.mkv",
    "/Media/Caf%C3%A9.mkv", "/Media/Cafe%CC%81.mkv", "/Media/%F0%9F%8E%AC.mkv",
    "/Media/%C0%AFname.mkv", "/Media/%ED%A0%80name.mkv", "/Media/%F4%90%80%80name.mkv",
    "/Media/%FFname.mkv", "/Media/%7Fname.mkv", "/Media/%09name.mkv",
    "/Media/%0Aname.mkv", "/Media/%5Cname.mkv", "/Media/%name.mkv",
    "/Media/%0name.mkv", "/Media/%GGname.mkv", "/Volumes/Media%20Share/Feature.mkv",
    "/tmp/./nonexistent/../Feature.mkv", "", "relative.mkv",
]

private let authorities = [
    "", "localhost", "LOCALHOST", "LocalHost", "%6cocalhost", "LOCAL%68OST",
    "localhost.", "media-server.invalid", "127.0.0.1", "[::1]",
    "user@localhost", "user:secret@localhost", "user:@localhost", ":secret@localhost",
    "@localhost", "localhost:0", "localhost:1234", "localhost:", "localhost:65536",
]

private let suffixes = ["", "?version=1", "#chapter", "?x=%2f%00#part%20one"]

private func checkRawURLs(_ suite: inout ParitySuite) {
    for scheme in ["file", "FILE", "FiLe", "https", "ftp"] {
        for authority in authorities {
            for path in pathSpellings {
                for suffix in suffixes {
                    let input = "\(scheme)://\(authority)\(path)\(suffix)"
                    suite.check(URL(string: input), family: "raw-url", input: input)
                }
            }
        }
    }
    for input in ["file:", "file://", "file://localhost", "file:relative.mkv",
                  "file:/Media/Feature.mkv", "FILE:/Media/Cafe%CC%81.mkv",
                  "file:/", "file:////", "file:///..", "file:///../", "file:///../../",
                  "file:///Media/..", "file:///Media/../..", "file:///Media/../../..",
                  "file://localhost/.", "file://localhost/.."] {
        suite.check(URL(string: input), family: "raw-url", input: input)
    }
}

private func checkEncodedBytes(_ suite: inout ParitySuite) {
    for byte in 0...255 {
        let hex = String(byte, radix: 16)
        let padded = hex.count == 1 ? "0" + hex : hex
        for encoded in ["%" + padded, "%" + padded.uppercased()] {
            for path in ["/Media/a\(encoded)b.mkv", "/Media/\(encoded)/Feature.mkv",
                         "/\(encoded)Media/Feature.mkv", "/Media/Feature.mkv\(encoded)",
                         "/Media/a%25\(encoded)b.mkv"] {
                for authority in ["", "localhost", "LOCALHOST", "media-server.invalid"] {
                    let input = "file://\(authority)\(path)"
                    suite.check(URL(string: input), family: "encoded-byte", input: input)
                }
            }
        }
    }
}

private func checkUnicode(_ suite: inout ParitySuite) {
    for first in unicodeSegments {
        for second in unicodeSegments {
            let path = "/__illiquid_key_parity__/\(first)/\(second).mkv"
            for isDirectory in [false, true] {
                suite.check(URL(fileURLWithPath: path, isDirectory: isDirectory),
                            family: "unicode", input: "file-path directory=\(isDirectory) \(path)")
            }
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            for authority in ["", "LOCALHOST"] {
                let input = "file://\(authority)\(encodedPath)"
                suite.check(URL(string: input), family: "unicode", input: input)
            }
        }
    }
}

private func checkFilePaths(_ suite: inout ParitySuite) {
    let bases = [
        URL(fileURLWithPath: "/__illiquid_key_parity__/base", isDirectory: true),
        URL(fileURLWithPath: "/__illiquid_key_parity__/base.mkv", isDirectory: false),
        URL(fileURLWithPath: "/", isDirectory: true),
        URL(string: "file://LOCALHOST/__illiquid_key_parity__/base/")!,
        URL(string: "file://media-server.invalid/__illiquid_key_parity__/base/")!,
    ]
    // Malformed bytes use the failable URI initializer in the encoded-byte
    // family; these file-path fixtures contain no embedded NUL characters.
    let paths = pathSpellings.filter { $0.hasPrefix("/") } + [
        "relative.mkv", "../Feature.mkv", "./Feature.mkv", "Season/../Feature.mkv",
        "/__illiquid_key_parity__/a%00b.mkv", "/__illiquid_key_parity__/tail%00",
        "/__illiquid_key_parity__/back\\slash.mkv", "/__illiquid_key_parity__/hash#query?.mkv",
        "/__illiquid_key_parity__/line\nfeed.mkv", "/__illiquid_key_parity__/tab\tname.mkv",
    ]
    for base in bases {
        for path in paths {
            for isDirectory in [false, true] {
                let input = "file-path directory=\(isDirectory) base=\(base.absoluteString) path=\(path)"
                suite.check(URL(fileURLWithPath: path, isDirectory: isDirectory, relativeTo: base),
                            family: "file-path", input: input)
            }
        }
    }
}

private func checkNestedBases(_ suite: inout ParitySuite) {
    let roots = [
        "file:///__illiquid_key_parity__/root/", "file:///__illiquid_key_parity__/root.mkv",
        "file://LOCALHOST/__illiquid_key_parity__/root/", "file:///",
        "file://media-server.invalid/root/", "file://user@localhost/root/",
        "file://localhost:1234/root/", "https://example.invalid/root/",
    ]
    let middleReferences = [
        "child/", "child.mkv", "../", "./", "../../", "child/../other/", "?v=1", "#part",
        "Caf%C3%A9/", "Cafe%CC%81/", "%2e%2e/", "//localhost/absolute/",
        "//media-server.invalid/absolute/", "/absolute//base/", "file:/replacement/", "",
    ]
    let leafReferences = [
        "Feature.mkv", "./Feature.mkv", "../Feature.mkv", "../../Feature.mkv", "../../..",
        "../../../Feature.mkv", "/Feature.mkv", "//localhost/Feature.mkv",
        "//user@localhost/Feature.mkv", "//127.0.0.1/Feature.mkv", "?query", "#fragment", "",
        "Caf%C3%A9.mkv", "Cafe%CC%81.mkv", "%2e/Feature.mkv", "%2e%2e/Feature.mkv",
        "a%2Fb.mkv", "a%00b.mkv", "a%252Fb.mkv", "file:relative.mkv", "file:/Feature.mkv",
        "/%2Efile/id=0.0", "a//b///Feature.mkv", "Feature.mkv/", ".", "..",
    ]
    for root in roots {
        let base = URL(string: root)
        for middleReference in middleReferences {
            let middle = base.flatMap { URL(string: middleReference, relativeTo: $0) }
            for leafReference in leafReferences {
                let leaf = middle.flatMap { URL(string: leafReference, relativeTo: $0) }
                suite.check(leaf, family: "nested-base",
                            input: "root=\(root) middle=\(middleReference) leaf=\(leafReference)")
            }
        }
    }
}

private func checkFileReferences(_ suite: inout ParitySuite) {
    // Encoded prefixes become visible only when .path is decoded. The baseline
    // then reconstructs a URL, whose Darwin initializer can recognize a file ID.
    for identity in ["0.0", "0.18446744073709551615", "invalid"] {
        for prefix in ["/.file/id=", "/%2Efile/id=", "/.%66ile/id=", "/.file/%69d=",
                       "/.file/id%3D", "/.file%2Fid=", "/Media/../%2Efile/id="] {
            for authority in ["", "localhost", "LOCALHOST"] {
                for suffix in suffixes {
                    let input = "file://\(authority)\(prefix)\(identity)\(suffix)"
                    suite.check(URL(string: input), family: "file-reference", input: input)
                }
            }
        }
    }
}

private func checkGeneratedCombinations(_ suite: inout ParitySuite) {
    var random = Random()
    let segments = ["Media", "Feature.mkv", "", ".", "..", "Season 1", "A", "a", "A:B",
                    "a%2Fb", "%00", "%2500", "%2E", "%2e%2e", "%252e", "%", "%GG",
                    "x;y", "x#y", "x?y", "x\\y", "x%2500y"] + unicodeSegments
    let bases = [
        URL(fileURLWithPath: "/__illiquid_key_parity__/base", isDirectory: true),
        URL(fileURLWithPath: "/__illiquid_key_parity__/base.mkv", isDirectory: false),
        URL(string: "file://LOCALHOST/__illiquid_key_parity__/base/")!,
        URL(string: "file://media-server.invalid/__illiquid_key_parity__/base/")!,
    ]
    while suite.attemptedCaseCount < ParitySuite.requiredCaseCount {
        let componentCount = 1 + random.index(7)
        var components: [String] = []
        for _ in 0..<componentCount { components.append(segments[random.index(segments.count)]) }
        let relativePath = components.joined(separator: random.index(4) == 0 ? "//" : "/")
        let suffix = suffixes[random.index(suffixes.count)]
        switch random.index(4) {
        case 0:
            let localAuthorities = ["", "localhost", "LOCALHOST", "%6cocalhost",
                                    "user@localhost", "media-server.invalid"]
            let authority = localAuthorities[random.index(localAuthorities.count)]
            let input = "file://\(authority)/\(relativePath)\(suffix)"
            suite.check(URL(string: input), family: "generated-url", input: input)
        case 1:
            let path = "/__illiquid_key_parity__/" + relativePath
            let isDirectory = random.index(2) == 0
            suite.check(URL(fileURLWithPath: path, isDirectory: isDirectory),
                        family: "generated-file-path",
                        input: "file-path directory=\(isDirectory) \(path)")
        case 2:
            let base = bases[random.index(bases.count)]
            let reference = "../" + relativePath + suffix
            suite.check(URL(string: reference, relativeTo: base), family: "generated-base",
                        input: "base=\(base.absoluteString) reference=\(reference)")
        default:
            let path = "/__illiquid_key_parity__/" + relativePath
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            let input = "file://" + encoded + suffix
            suite.check(URL(string: input), family: "generated-encoded-path", input: input)
        }
    }
}

@main
private enum PersistenceKeyParity {
    static func main() throws {
        var suite = ParitySuite()
        checkRawURLs(&suite)
        checkEncodedBytes(&suite)
        checkUnicode(&suite)
        checkFilePaths(&suite)
        checkNestedBases(&suite)
        checkFileReferences(&suite)
        checkGeneratedCombinations(&suite)
        let receipt = suite.receipt
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(receipt))
        FileHandle.standardOutput.write(Data([10]))
        if !receipt.passed { exit(1) }
    }
}
