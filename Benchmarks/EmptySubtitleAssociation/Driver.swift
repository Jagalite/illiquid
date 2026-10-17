import Dispatch
import Foundation
import IlliquidCore

private enum DriverError: Error, CustomStringConvertible {
    case usage
    case unknownCase(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .usage:
            return "Usage: driver CASE ITERATIONS SEED (positive iterations, UInt64 seed)"
        case let .unknownCase(name):
            return "Unknown benchmark case: \(name)"
        case let .mismatch(message):
            return "Fixture verification failed: \(message)"
        }
    }
}

private enum Operation: String, Codable {
    case associate
    case makePlaylist
}

private enum Inventory {
    case emptySubtitles
    case unicodeMedia
    case duplicateMedia
    case unsupportedMedia
    case matchingSubtitles
    case unsupportedSubtitles
}

private struct Case {
    let name: String
    let operation: Operation
    let count: Int
    let inventory: Inventory

    init(_ name: String) throws {
        self.name = name
        let configuration: (Operation, Int, Inventory)
        switch name {
        case "associate-empty-0":
            configuration = (.associate, 0, .emptySubtitles)
        case "associate-empty-1":
            configuration = (.associate, 1, .emptySubtitles)
        case "associate-empty-16":
            configuration = (.associate, 16, .emptySubtitles)
        case "associate-empty-1000":
            configuration = (.associate, 1_000, .emptySubtitles)
        case "associate-empty-10000":
            configuration = (.associate, 10_000, .emptySubtitles)
        case "associate-unicode-1000":
            configuration = (.associate, 1_000, .unicodeMedia)
        case "associate-duplicates-1000":
            configuration = (.associate, 1_000, .duplicateMedia)
        case "associate-unsupported-media-1000":
            configuration = (.associate, 1_000, .unsupportedMedia)
        case "associate-matching-1000":
            configuration = (.associate, 1_000, .matchingSubtitles)
        case "associate-unsupported-subtitles-1000":
            configuration = (.associate, 1_000, .unsupportedSubtitles)
        case "playlist-empty-16":
            configuration = (.makePlaylist, 16, .emptySubtitles)
        case "playlist-empty-1000":
            configuration = (.makePlaylist, 1_000, .emptySubtitles)
        case "playlist-empty-10000":
            configuration = (.makePlaylist, 10_000, .emptySubtitles)
        case "playlist-matching-1000":
            configuration = (.makePlaylist, 1_000, .matchingSubtitles)
        default:
            throw DriverError.unknownCase(name)
        }
        operation = configuration.0
        count = configuration.1
        inventory = configuration.2
    }
}

/// SplitMix64 and Fisher-Yates make the input ordering reproducible from the CLI.
private struct Shuffle {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func apply<Value>(to values: inout [Value]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            let other = Int(next() % UInt64(index + 1))
            values.swapAt(index, other)
        }
    }
}

private struct AssociationEntry: Codable, Equatable {
    let url: String
    let externalSubtitleURLs: [String]
}

private struct PlaylistEntry: Codable, Equatable {
    let url: String
    let externalSubtitleURLs: [String]
    let dateAdded: Double?
}

private struct Receipt: Codable, Equatable {
    let associations: [AssociationEntry]?
    let folderURL: String?
    let items: [PlaylistEntry]?

    init(associations: [URL: [URL]]) {
        self.associations = associations.map { url, subtitles in
            AssociationEntry(
                url: url.absoluteString,
                externalSubtitleURLs: subtitles.map(\.absoluteString)
            )
        }.sorted { $0.url < $1.url }
        folderURL = nil
        items = nil
    }

    init(folderURL: URL, items: [PlaylistEntry]) {
        associations = nil
        self.folderURL = folderURL.absoluteString
        self.items = items
    }

    init(playlist: FolderPlaylist) {
        self.init(folderURL: playlist.folderURL, items: playlist.items.map { item in
            PlaylistEntry(
                url: item.url.absoluteString,
                externalSubtitleURLs: item.externalSubtitleURLs.map(\.absoluteString),
                dateAdded: item.dateAdded?.timeIntervalSince1970
            )
        })
    }
}

private struct Fixture {
    let folderURL: URL
    let mediaURLs: [URL]
    let subtitleURLs: [URL]
    let metadataDates: [URL: Date]
    let expectedReceipt: Receipt
    let countPerIteration: UInt64

    init(benchmark: Case, seed: UInt64) {
        let folder = URL(
            fileURLWithPath: "/tmp/illiquid-empty-subtitle-fixtures/",
            isDirectory: true
        )
        var media: [URL] = []
        var subtitles: [URL] = []
        var dates: [URL: Date] = [:]
        var expectedAssociations: [URL: [URL]] = [:]
        var expectedItems: [PlaylistEntry] = []

        for inputIndex in 0..<benchmark.count {
            let index = benchmark.inventory == .duplicateMedia ? inputIndex / 2 : inputIndex
            let number = String(format: "%05d", index)
            let stem = benchmark.inventory == .unicodeMedia
                ? "Épisode \(number) 世界 Cafe\u{301} ＡＢ 🛰️"
                : "Episode \(number)"
            let mediaExtension = benchmark.inventory == .unsupportedMedia ? "txt" : "mkv"
            let mediaURL = folder.appendingPathComponent(stem + "." + mediaExtension, isDirectory: false)
            media.append(mediaURL)

            var expectedSubtitles: [URL] = []
            switch benchmark.inventory {
            case .matchingSubtitles:
                let subtitle = folder.appendingPathComponent(stem + ".srt", isDirectory: false)
                subtitles.append(subtitle)
                expectedSubtitles = [subtitle]
            case .unsupportedSubtitles:
                subtitles.append(folder.appendingPathComponent(stem + ".txt", isDirectory: false))
            default:
                break
            }
            // The expected association map is constructed directly from the
            // fixture's one-to-one names. Unsupported media also keep their keys.
            expectedAssociations[mediaURL] = expectedSubtitles

            if benchmark.operation == .makePlaylist {
                let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                dates[mediaURL] = date
                // Playlist fixtures have distinct, zero-padded ASCII names.
                // Their known natural order is the generation order; no production
                // sorter, matcher, or item initializer computes this oracle.
                expectedItems.append(PlaylistEntry(
                    url: mediaURL.absoluteString,
                    externalSubtitleURLs: expectedSubtitles.map(\.absoluteString),
                    dateAdded: date.timeIntervalSince1970
                ))
            }
        }

        var shuffle = Shuffle(state: seed)
        shuffle.apply(to: &media)
        shuffle.apply(to: &subtitles)
        folderURL = folder
        mediaURLs = media
        subtitleURLs = subtitles
        metadataDates = dates
        switch benchmark.operation {
        case .associate:
            expectedReceipt = Receipt(associations: expectedAssociations)
            countPerIteration = UInt64(expectedAssociations.count)
        case .makePlaylist:
            expectedReceipt = Receipt(folderURL: folder, items: expectedItems)
            countPerIteration = UInt64(expectedItems.count)
        }
    }

    func verify(_ receipt: Receipt, phase: String) throws {
        guard receipt == expectedReceipt else { throw DriverError.mismatch(phase) }
    }
}

private struct AssociationMeasurement {
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let last: [URL: [URL]]
}

private struct PlaylistMeasurement {
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let last: FolderPlaylist
}

@inline(never)
private func measureAssociations(_ fixture: Fixture, iterations: Int) -> AssociationMeasurement {
    var last: [URL: [URL]] = [:]
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let output = ExternalSubtitleMatcher.associate(
            subtitleURLs: fixture.subtitleURLs, with: fixture.mediaURLs
        )
        checksum &+= UInt64(output.count)
        // Replacing last includes the previous iteration's disposal in the loop.
        last = output
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
    return AssociationMeasurement(elapsedNanoseconds: elapsed, checksum: checksum, last: last)
}

@inline(never)
private func measurePlaylist(_ fixture: Fixture, iterations: Int) -> PlaylistMeasurement {
    var last: FolderPlaylist?
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let output = FolderPlaylistDiscovery.makePlaylist(
            folderURL: fixture.folderURL,
            mediaURLs: fixture.mediaURLs,
            subtitleURLs: fixture.subtitleURLs,
            metadataDates: fixture.metadataDates
        )
        checksum &+= UInt64(output.count)
        last = output
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
    // The CLI rejects zero iterations before entering this function.
    return PlaylistMeasurement(elapsedNanoseconds: elapsed, checksum: checksum, last: last!)
}

private struct Output: Encodable {
    let caseName: String
    let iterations: Int
    let seed: UInt64
    let elapsedNanoseconds: UInt64
    let checksum: UInt64
    let receipt: Receipt
    let operation: Operation

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, seed, checksum, receipt, operation
        case elapsedNanoseconds = "elapsed_ns"
    }
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let iterations = Int(arguments[2]), iterations > 0,
              let seed = UInt64(arguments[3]) else { throw DriverError.usage }
        let benchmark = try Case(arguments[1])
        let fixture = Fixture(benchmark: benchmark, seed: seed)
        let elapsedNanoseconds: UInt64
        let checksum: UInt64
        let receipt: Receipt

        switch benchmark.operation {
        case .associate:
            do {
                var lastWarmup: [URL: [URL]] = [:]
                for _ in 0..<3 {
                    lastWarmup = ExternalSubtitleMatcher.associate(
                        subtitleURLs: fixture.subtitleURLs, with: fixture.mediaURLs
                    )
                }
                try fixture.verify(Receipt(associations: lastWarmup), phase: "association warmup")
            }
            let measured = measureAssociations(fixture, iterations: iterations)
            elapsedNanoseconds = measured.elapsedNanoseconds
            checksum = measured.checksum
            receipt = Receipt(associations: measured.last)
        case .makePlaylist:
            do {
                var lastWarmup: FolderPlaylist?
                for _ in 0..<3 {
                    lastWarmup = FolderPlaylistDiscovery.makePlaylist(
                        folderURL: fixture.folderURL,
                        mediaURLs: fixture.mediaURLs,
                        subtitleURLs: fixture.subtitleURLs,
                        metadataDates: fixture.metadataDates
                    )
                }
                try fixture.verify(Receipt(playlist: lastWarmup!), phase: "playlist warmup")
            }
            let measured = measurePlaylist(fixture, iterations: iterations)
            elapsedNanoseconds = measured.elapsedNanoseconds
            checksum = measured.checksum
            receipt = Receipt(playlist: measured.last)
        }

        try fixture.verify(receipt, phase: "last timed output")
        guard checksum == fixture.countPerIteration &* UInt64(iterations) else {
            throw DriverError.mismatch("consumed result counts")
        }
        let output = Output(
            caseName: benchmark.name, iterations: iterations, seed: seed,
            elapsedNanoseconds: elapsedNanoseconds, checksum: checksum,
            receipt: receipt, operation: benchmark.operation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(output)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}
