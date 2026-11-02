import Foundation
import IlliquidCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct WorkloadDescriptor: Encodable {
    let id: String
    let operationsPerIteration: Int
}

private let workloadIDs = [
    "key-short", "key-root", "key-ascii64", "key-long-ascii64",
    "key-percent64", "key-raw-localhost64", "key-unicode-nfc64",
    "key-unicode-nfd64", "key-invalid-authority64", "same-file64",
    "item-id512", "item-id-invalid64", "folder-last32", "folder-miss32",
    "folder-last512", "folder-miss512", "folder-first512",
    "folder-singleton-hit", "folder-singleton-miss", "folder-empty",
]

private enum Fixture {
    case keys([URL])
    case sameFile([(URL, URL)])
    case itemIDs([FolderPlaylistItem])
    case folder(FolderPlaylist, queries: [URL], expected: [Int?])

    var operationsPerIteration: Int {
        switch self {
        case .keys(let values): values.count
        case .sameFile(let values): values.count
        case .itemIDs(let values): values.count
        case .folder(_, let queries, _): queries.count
        }
    }
}

private enum DriverError: Error {
    case invalidArguments
    case invalidFixture(String)
    case mismatch(String)
}

private func local(_ path: String, directory: Bool = false) -> URL {
    URL(fileURLWithPath: path, isDirectory: directory)
}

private func parsed(_ value: String) throws -> URL {
    guard let result = URL(string: value) else { throw DriverError.invalidFixture(value) }
    return result
}

private func filename(_ index: Int) -> String {
    let number = String(index)
    return "episode-" + String(repeating: "0", count: max(0, 4 - number.count)) + number + ".mkv"
}

private func invalidURLs() throws -> [URL] {
    try (0..<64).map { index in
        let tail = "/Media/" + filename(index)
        let value: String
        switch index % 8 {
        case 0: value = "https://example.invalid" + tail
        case 1: value = "file://archive.example.invalid" + tail
        case 2: value = "file://user@localhost" + tail
        case 3: value = "file://localhost:1234" + tail
        case 4: value = "file:relative-\(index).mkv"
        case 5: value = "file://localhost"
        case 6: value = "ftp://example.invalid" + tail
        default: value = "file://127.0.0.1" + tail
        }
        return try parsed(value)
    }
}

private func makeFixture(_ id: String) throws -> Fixture {
    switch id {
    case "key-short":
        return .keys(Array(repeating: local("/a"), count: 64))
    case "key-root":
        return .keys(Array(repeating: local("/", directory: true), count: 64))
    case "key-ascii64":
        return .keys((0..<64).map { local("/Volumes/Media/Show/Season 1/" + filename($0)) })
    case "key-long-ascii64":
        let parent = "/Volumes/Media/" + (0..<16).map {
            "collection-\($0)-abcdefghij"
        }.joined(separator: "/") + "/"
        return .keys((0..<64).map { local(parent + filename($0)) })
    case "key-percent64":
        return .keys(try (0..<64).map { index in
            let component: String
            switch index % 4 {
            case 0: component = "A%20Folder/100%25%20Complete-\(index)%23%3F.mkv"
            case 1: component = "Encoded%2FSlash-\(index).mkv"
            case 2: component = "Literal%252F-\(index).mkv"
            default: component = "Nul%00-\(index).mkv"
            }
            return try parsed("file:///Media/" + component + "?ignored=1#chapter")
        })
    case "key-raw-localhost64":
        return .keys(try (0..<64).map {
            try parsed("file://LOCALHOST/Media/Season/../" + filename($0) + "?edition=1#chapter")
        })
    case "key-unicode-nfc64":
        return .keys(try (0..<64).map {
            try parsed("file:///Media/Caf%C3%A9/Film%20\($0).mkv")
        })
    case "key-unicode-nfd64":
        return .keys(try (0..<64).map {
            try parsed("file:///Media/Cafe%CC%81/Film%20\($0).mkv")
        })
    case "key-invalid-authority64":
        return .keys(try invalidURLs())
    case "same-file64":
        return .sameFile(try (0..<64).map { index in
            let lhs = local("/Media/" + filename(index))
            let rhsIndex = index.isMultiple(of: 2) ? index : index + 64
            let rhs = try parsed("file://localhost/Media/Season/../" + filename(rhsIndex))
            return (lhs, rhs)
        })
    case "item-id512":
        return .itemIDs((0..<512).map {
            FolderPlaylistItem(url: local("/Media/" + filename($0)))
        })
    case "item-id-invalid64":
        return .itemIDs(try invalidURLs().map { FolderPlaylistItem(url: $0) })
    default:
        let count: Int
        let selected: Int?
        switch id {
        case "folder-last32": count = 32; selected = 31
        case "folder-miss32": count = 32; selected = nil
        case "folder-last512": count = 512; selected = 511
        case "folder-miss512": count = 512; selected = nil
        case "folder-first512": count = 512; selected = 0
        case "folder-singleton-hit": count = 1; selected = 0
        case "folder-singleton-miss": count = 1; selected = nil
        case "folder-empty": count = 0; selected = nil
        default: throw DriverError.invalidArguments
        }
        let items = (0..<count).reversed().map { index in
            FolderPlaylistItem(
                url: local("/Media/" + filename(index)),
                dateAdded: Date(timeIntervalSince1970: Double(index))
            )
        }
        let playlist = FolderPlaylist(folderURL: local("/Media", directory: true), items: items)
        // Integer labels establish the expected sorted positions independently
        // of the identity helpers that this benchmark exercises.
        for (index, item) in playlist.items.enumerated() {
            guard item.dateAdded?.timeIntervalSince1970 == Double(index) else {
                throw DriverError.invalidFixture("Unexpected playlist order")
            }
        }
        let query = local("/Media/" + (selected.map(filename) ?? "missing.mkv"))
        return .folder(
            playlist,
            queries: Array(repeating: query, count: 32),
            expected: Array(repeating: selected, count: 32)
        )
    }
}

// Lengths consume timed String results without hashing every output byte in the
// measured interval. Complete byte parity and fixture signatures are checked
// separately below. Nil and an empty String contribute different values.
@inline(__always)
private func stringValue(_ value: String?) -> UInt64 {
    value.map { UInt64($0.utf8.count) &+ 1 } ?? 0
}

@inline(__always)
private func indexValue(_ value: Int?) -> UInt64 {
    value.map { UInt64($0) &+ 1 } ?? 0
}

private struct Fingerprint {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func byte(_ value: UInt8) {
        self.value ^= UInt64(value)
        self.value &*= 1_099_511_628_211
    }

    mutating func integer(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            byte(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    mutating func string(_ value: String) {
        integer(UInt64(value.utf8.count))
        for value in value.utf8 { byte(value) }
    }

    mutating func optionalString(_ value: String?) {
        guard let value else { byte(0); return }
        byte(1)
        string(value)
    }

    mutating func url(_ value: URL) {
        string(value.relativeString)
        string(value.absoluteString)
        optionalString(value.baseURL?.absoluteString)
        byte(value.hasDirectoryPath ? 1 : 0)
    }

    var description: String {
        let digits = String(value, radix: 16)
        return "fnv1a64:" + String(repeating: "0", count: 16 - digits.count) + digits
    }
}

private func checkedKey(_ url: URL) throws -> String? {
    let expected = NormalizedFileURL.normalize(url)?.path
    let actual = NormalizedFileURL.persistenceKey(for: url)
    guard actual.map({ Array($0.utf8) }) == expected.map({ Array($0.utf8) }) else {
        throw DriverError.mismatch("Key UTF-8 differs from normalize(url)?.path: \(url.absoluteString)")
    }
    return actual
}

private func validate(_ fixture: Fixture, id: String) throws -> (checksum: UInt64, signature: String) {
    var hash = Fingerprint()
    hash.string(id)
    hash.integer(UInt64(fixture.operationsPerIteration))
    var checksum: UInt64 = 0
    switch fixture {
    case .keys(let values):
        for url in values {
            hash.url(url)
            let key = try checkedKey(url)
            hash.optionalString(key)
            checksum &+= stringValue(key)
        }
    case .sameFile(let pairs):
        for (lhs, rhs) in pairs {
            hash.url(lhs)
            hash.url(rhs)
            let lhsKey = try checkedKey(lhs)
            let rhsKey = try checkedKey(rhs)
            hash.optionalString(lhsKey)
            hash.optionalString(rhsKey)
            let expected: Bool
            if let lhsKey, let rhsKey { expected = lhsKey == rhsKey }
            else { expected = false }
            let actual = NormalizedFileURL.representsSameFile(lhs, rhs)
            guard actual == expected else { throw DriverError.mismatch("File comparison") }
            hash.byte(actual ? 1 : 0)
            checksum &+= actual ? 2 : 1
        }
    case .itemIDs(let items):
        for item in items {
            hash.url(item.url)
            let expected = try checkedKey(item.url) ?? item.url.absoluteString
            let actual = item.id
            guard Array(actual.utf8) == Array(expected.utf8) else {
                throw DriverError.mismatch("Playlist item ID")
            }
            hash.string(actual)
            checksum &+= stringValue(actual)
        }
    case .folder(let playlist, let queries, let expected):
        hash.url(playlist.folderURL)
        _ = try checkedKey(playlist.folderURL)
        for item in playlist.items {
            hash.url(item.url)
            hash.optionalString(try checkedKey(item.url))
        }
        for (query, expectedIndex) in zip(queries, expected) {
            hash.url(query)
            hash.optionalString(try checkedKey(query))
            let actual = playlist.index(of: query)
            guard actual == expectedIndex else { throw DriverError.mismatch("Folder lookup") }
            hash.integer(indexValue(actual))
            checksum &+= indexValue(actual)
        }
    }
    return (checksum, hash.description)
}

@inline(never)
private func measure(_ fixture: Fixture, iterations: Int) -> (elapsedNS: UInt64, checksum: UInt64) {
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    switch fixture {
    case .keys(let values):
        for _ in 0..<iterations {
            for url in values { checksum &+= stringValue(NormalizedFileURL.persistenceKey(for: url)) }
        }
    case .sameFile(let pairs):
        for _ in 0..<iterations {
            for (lhs, rhs) in pairs {
                checksum &+= NormalizedFileURL.representsSameFile(lhs, rhs) ? 2 : 1
            }
        }
    case .itemIDs(let items):
        for _ in 0..<iterations {
            for item in items { checksum &+= stringValue(item.id) }
        }
    case .folder(let playlist, let queries, _):
        for _ in 0..<iterations {
            for query in queries { checksum &+= indexValue(playlist.index(of: query)) }
        }
    }
    return (DispatchTime.now().uptimeNanoseconds - start, checksum)
}

private struct Measurement: Encodable {
    let id: String
    let iterations: Int
    let operationsPerIteration: Int
    let elapsedNS: UInt64
    let checksum: UInt64
    let signature: String
}

@main
private struct Driver {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FileIdentityKeys: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if arguments == ["--list"] {
            let descriptors = workloadIDs.map { id in
                WorkloadDescriptor(
                    id: id,
                    operationsPerIteration: id == "item-id512" ? 512 : (id.hasPrefix("folder-") ? 32 : 64)
                )
            }
            print(String(decoding: try encoder.encode(descriptors), as: UTF8.self))
            return
        }
        guard arguments.count == 2, workloadIDs.contains(arguments[0]),
              let iterations = Int(arguments[1]), iterations > 0 else {
            throw DriverError.invalidArguments
        }
        let id = arguments[0]
        let fixture = try makeFixture(id)
        let validation = try validate(fixture, id: id)
        let warmup = measure(fixture, iterations: 1)
        guard warmup.checksum == validation.checksum else {
            throw DriverError.mismatch("Warmup checksum")
        }
        let result = measure(fixture, iterations: iterations)
        guard result.checksum == validation.checksum &* UInt64(iterations) else {
            throw DriverError.mismatch("Timed checksum")
        }
        let record = Measurement(
            id: id, iterations: iterations, operationsPerIteration: fixture.operationsPerIteration,
            elapsedNS: result.elapsedNS, checksum: result.checksum, signature: validation.signature
        )
        print(String(decoding: try encoder.encode(record), as: UTF8.self))
    }
}
