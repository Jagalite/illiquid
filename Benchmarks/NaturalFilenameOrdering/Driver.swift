import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private enum Workload: String, Codable, Sendable {
    case sort
    case makePlaylist
}

private struct CaseSpec: Codable, Sendable {
    let id: String
    let workload: Workload
    let count: Int
    let subtitleCount: Int
    let scenario: String
}

private let cases: [CaseSpec] = [
    .init(id: "sort-empty", workload: .sort, count: 0, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-singleton", workload: .sort, count: 1, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-shuffled-2", workload: .sort, count: 2, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-shuffled-8", workload: .sort, count: 8, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-shuffled-24", workload: .sort, count: 24, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-sorted-8", workload: .sort, count: 8, subtitleCount: 0, scenario: "numeric-sorted"),
    .init(id: "sort-reversed-24", workload: .sort, count: 24, subtitleCount: 0, scenario: "numeric-reversed"),
    .init(id: "sort-shuffled-128", workload: .sort, count: 128, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-shuffled-1000", workload: .sort, count: 1000, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-shuffled-10000", workload: .sort, count: 10000, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "sort-sorted-10000", workload: .sort, count: 10000, subtitleCount: 0, scenario: "numeric-sorted"),
    .init(id: "sort-reversed-10000", workload: .sort, count: 10000, subtitleCount: 0, scenario: "numeric-reversed"),
    .init(id: "sort-unicode-1000", workload: .sort, count: 1000, subtitleCount: 0, scenario: "unicode"),
    .init(id: "sort-ties-1000", workload: .sort, count: 1000, subtitleCount: 0, scenario: "ties"),
    .init(id: "playlist-128-no-subtitles", workload: .makePlaylist, count: 128, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "playlist-1000-no-subtitles", workload: .makePlaylist, count: 1000, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "playlist-10000-no-subtitles", workload: .makePlaylist, count: 10000, subtitleCount: 0, scenario: "numeric-shuffled"),
    .init(id: "playlist-1000-with-subtitles", workload: .makePlaylist, count: 1000, subtitleCount: 1000, scenario: "numeric-shuffled"),
]

private struct Generator {
    var state: UInt64 = 0x632be59bd9b4e019

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, Int(next() % UInt64(index + 1)))
        }
    }
}

private struct Fixture {
    let spec: CaseSpec
    let folder: URL
    let media: [URL]
    let subtitles: [URL]
    let dates: [URL: Date]

    init(_ spec: CaseSpec) {
        self.spec = spec
        let folder = URL(fileURLWithPath: "/Volumes/Media/Performance research/Caf\u{00e9}/Season 1", isDirectory: true)
        self.folder = folder
        let unicode = ["七人の侍", "Épisode", "E\u{0301}pisode", "Показы", "👩🏽‍🚀 Mission", "Straße", "Ångström", "İstanbul"]
        let tiedNames = ["Episode 7.mkv", "Episode 7.mkv", "Épisode 7.mkv", "E\u{0301}pisode 7.mkv", "EPISODE 7.mkv", "episode 07.mkv"]
        var media: [URL] = (0..<spec.count).map { index in
            switch spec.scenario {
            case "unicode":
                return folder.appendingPathComponent("\(unicode[index % unicode.count]) - Episode \(index + 1).mkv")
            case "ties":
                return folder.appendingPathComponent("Folder \(index)", isDirectory: true)
                    .appendingPathComponent(tiedNames[index % tiedNames.count])
            default:
                return folder.appendingPathComponent("Show - Episode \(index + 1).mkv")
            }
        }
        var subtitles = spec.subtitleCount == 0 ? [] : media.map {
            $0.deletingPathExtension().appendingPathExtension("en.srt")
        }
        var dates: [URL: Date] = [:]
        if spec.workload == .makePlaylist {
            for (index, url) in media.enumerated() where index.isMultiple(of: 3) {
                dates[url] = Date(timeIntervalSince1970: 1_650_000_000 + Double(index % 17))
            }
        }
        switch spec.scenario {
        case "numeric-sorted":
            media.sort(by: NaturalFilenameOrdering.areInIncreasingOrder)
        case "numeric-reversed":
            media.sort(by: NaturalFilenameOrdering.areInIncreasingOrder)
            media.reverse()
        default:
            var generator = Generator()
            generator.shuffle(&media)
            generator.shuffle(&subtitles)
        }
        self.media = media
        self.subtitles = subtitles
        self.dates = dates
    }
}

// Include relative/base representations so parity cannot hide reconstructed URLs.
private struct URLReceipt: Encodable {
    let absoluteString: String
    let relativeString: String
    let baseURL: String?
    let isFileURL: Bool
    let hasDirectoryPath: Bool

    init(_ url: URL) {
        absoluteString = url.absoluteString
        relativeString = url.relativeString
        baseURL = url.baseURL?.absoluteString
        isFileURL = url.isFileURL
        hasDirectoryPath = url.hasDirectoryPath
    }
}

private struct ItemReceipt: Encodable {
    let url: URLReceipt
    let subtitles: [URLReceipt]
    let dateAdded: Double?

    init(_ item: FolderPlaylistItem) {
        url = URLReceipt(item.url)
        subtitles = item.externalSubtitleURLs.map(URLReceipt.init)
        dateAdded = item.dateAdded?.timeIntervalSince1970
    }
}

private struct Receipt: Encodable {
    let urls: [URLReceipt]?
    let folder: URLReceipt?
    let items: [ItemReceipt]?
}

private enum Output {
    case urls([URL])
    case playlist(FolderPlaylist)

    var receipt: Receipt {
        switch self {
        case let .urls(urls):
            return Receipt(urls: urls.map(URLReceipt.init), folder: nil, items: nil)
        case let .playlist(playlist):
            return Receipt(urls: nil, folder: URLReceipt(playlist.folderURL), items: playlist.items.map(ItemReceipt.init))
        }
    }
}

// The same deliberately small consumer runs in both variants. It observes each
// returned collection without adding an O(N) full-output hash to the timed work.
@inline(never)
private func consume(_ urls: [URL]) -> UInt64 {
    UInt64(urls.count) &+ UInt64(urls.first?.absoluteString.utf8.count ?? 0)
        &+ UInt64(urls.last?.absoluteString.utf8.count ?? 0)
}

@inline(never)
private func consume(_ playlist: FolderPlaylist) -> UInt64 {
    UInt64(playlist.count) &+ UInt64(playlist.items.first?.url.absoluteString.utf8.count ?? 0)
        &+ UInt64(playlist.items.last?.url.absoluteString.utf8.count ?? 0)
        &+ UInt64(playlist.items.first?.externalSubtitleURLs.count ?? 0)
        &+ UInt64(playlist.items.last?.externalSubtitleURLs.count ?? 0)
}

private func execute(_ fixture: Fixture) -> Output {
    switch fixture.spec.workload {
    case .sort:
        return .urls(NaturalFilenameOrdering.sort(fixture.media))
    case .makePlaylist:
        return .playlist(FolderPlaylistDiscovery.makePlaylist(folderURL: fixture.folder,
            mediaURLs: fixture.media, subtitleURLs: fixture.subtitles, metadataDates: fixture.dates))
    }
}

@inline(never)
private func warmup(_ fixture: Fixture) -> UInt64 {
    switch execute(fixture) {
    case let .urls(urls): return consume(urls)
    case let .playlist(playlist): return consume(playlist)
    }
}

private struct Batch {
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let output: Output
}

@inline(never)
private func measure(_ fixture: Fixture, iterations: Int) -> Batch {
    switch fixture.spec.workload {
    case .sort:
        var final: [URL] = []
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let result = NaturalFilenameOrdering.sort(fixture.media)
            checksum &+= consume(result)
            final = result
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Batch(iterations: iterations, elapsedNanoseconds: elapsed, checksum: checksum, output: .urls(final))
    case .makePlaylist:
        var final: FolderPlaylist?
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let result = FolderPlaylistDiscovery.makePlaylist(folderURL: fixture.folder,
                mediaURLs: fixture.media, subtitleURLs: fixture.subtitles, metadataDates: fixture.dates)
            checksum &+= consume(result)
            final = result
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Batch(iterations: iterations, elapsedNanoseconds: elapsed, checksum: checksum, output: .playlist(final!))
    }
}

private struct CalibrationStep: Encodable {
    let iterations: Int
    let elapsedNanoseconds: UInt64
}

private struct Record: Encodable {
    let mode: String
    let spec: CaseSpec
    let processID: Int32
    let locale: String
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let nanosecondsPerOperation: Double
    let checksum: UInt64
    let checksumPerIteration: UInt64
    let calibration: [CalibrationStep]
    let receipt: Receipt
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

private enum DriverError: Error {
    case usage(String)
}

@main
private enum Driver {
    private static let maximumIterations = 10_000_000

    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("NaturalFilenameOrdering driver failed: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["list"] { try emit(cases); return }
        guard arguments.count >= 2, let spec = cases.first(where: { $0.id == arguments[1] }) else {
            throw DriverError.usage("list | verify CASE | measure CASE ITERATIONS | calibrate CASE TARGET_MS")
        }
        let fixture = Fixture(spec)
        let mode = arguments[0]
        if mode == "verify", arguments.count == 2 {
            let output = execute(fixture)
            let checksum: UInt64
            switch output {
            case let .urls(urls): checksum = consume(urls)
            case let .playlist(playlist): checksum = consume(playlist)
            }
            try emit(Record(mode: mode, spec: spec, processID: ProcessInfo.processInfo.processIdentifier,
                locale: Locale.current.identifier, iterations: 1, elapsedNanoseconds: 0,
                nanosecondsPerOperation: 0, checksum: checksum, checksumPerIteration: checksum,
                calibration: [], receipt: output.receipt))
            return
        }
        guard arguments.count == 3 else { throw DriverError.usage("expected three arguments") }
        let expectedChecksum = warmup(fixture)
        var calibration: [CalibrationStep] = []
        let batch: Batch
        if mode == "measure" {
            guard let iterations = Int(arguments[2]), (1...maximumIterations).contains(iterations) else {
                throw DriverError.usage("iterations must be between 1 and \(maximumIterations)")
            }
            batch = measure(fixture, iterations: iterations)
        } else if mode == "calibrate" {
            guard let milliseconds = Double(arguments[2]), milliseconds.isFinite, (1...2000).contains(milliseconds) else {
                throw DriverError.usage("target milliseconds must be between 1 and 2000")
            }
            let target = UInt64(milliseconds * 1_000_000)
            var current = measure(fixture, iterations: 1)
            calibration.append(.init(iterations: current.iterations, elapsedNanoseconds: current.elapsedNanoseconds))
            while current.elapsedNanoseconds < target, current.iterations < maximumIterations {
                let estimate = Double(current.iterations) * Double(target) / Double(max(current.elapsedNanoseconds, 1)) * 1.15
                let next = min(maximumIterations, max(current.iterations + 1, Int(ceil(estimate))))
                current = measure(fixture, iterations: next)
                calibration.append(.init(iterations: current.iterations, elapsedNanoseconds: current.elapsedNanoseconds))
            }
            batch = current
        } else {
            throw DriverError.usage("unknown mode \(mode)")
        }
        guard batch.checksum == expectedChecksum &* UInt64(batch.iterations) else {
            throw DriverError.usage("timed output checksum disagrees with untimed warmup")
        }
        try emit(Record(mode: mode, spec: spec, processID: ProcessInfo.processInfo.processIdentifier,
            locale: Locale.current.identifier, iterations: batch.iterations,
            elapsedNanoseconds: batch.elapsedNanoseconds,
            nanosecondsPerOperation: Double(batch.elapsedNanoseconds) / Double(batch.iterations),
            checksum: batch.checksum, checksumPerIteration: expectedChecksum,
            calibration: calibration, receipt: batch.output.receipt))
    }
}
