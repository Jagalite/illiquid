import Dispatch
import Foundation

// UTF-8 arrays deliberately avoid String's canonical-equivalence equality.
// Include every stored field and all computed presentation strings.
private struct Receipt: Encodable {
    let path: [UInt8]
    let kind: String
    let title: [UInt8]
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: [UInt8]?
    let episodeTitle: [UInt8]?
    let edition: [UInt8]?
    let catalogIDs: [[UInt8]]
    let variant: [UInt8]?
    let metadataSources: [[UInt8]]
    let seriesTitle: [UInt8]
    let displayName: [UInt8]
    let section: [UInt8]

    init(path: String, media: RecognizedMediaName) {
        self.path = Array(path.utf8)
        kind = media.kind.rawValue
        title = Array(media.title.utf8)
        year = media.year
        season = media.season
        episode = media.episode
        lastEpisode = media.lastEpisode
        airDate = media.airDate.map { Array($0.utf8) }
        episodeTitle = media.episodeTitle.map { Array($0.utf8) }
        edition = media.edition.map { Array($0.utf8) }
        catalogIDs = media.catalogIDs.map { Array($0.utf8) }
        variant = media.variant.map { Array($0.utf8) }
        metadataSources = media.metadataSources.map { Array($0.utf8) }
        seriesTitle = Array(media.seriesTitle.utf8)
        displayName = Array(media.displayName.utf8)
        section = Array(media.section.utf8)
    }
}

// This lightweight consumer keeps complete returned values live without timing
// JSON serialization or the computed UI strings. It is not the parity oracle.
@inline(never)
private func consume(_ value: RecognizedMediaName) -> UInt64 {
    var result = UInt64(value.title.utf8.count)
    for integer in [value.year, value.season, value.episode, value.lastEpisode] {
        result = result &* 31 &+ UInt64(integer.map { $0 + 1 } ?? 0)
    }
    for string in [value.airDate, value.episodeTitle, value.edition, value.variant] {
        result = result &* 31 &+ UInt64(string.map { $0.utf8.count + 1 } ?? 0)
    }
    for string in value.catalogIDs + value.metadataSources {
        result = result &* 31 &+ UInt64(string.utf8.count)
    }
    return result &* 31 &+ UInt64(value.kind.rawValue.utf8.count)
}

@inline(never)
private func recognizeBatch(_ paths: [String]) -> UInt64 {
    var checksum: UInt64 = 0
    for path in paths {
        checksum = checksum &* 16_777_619 &+ consume(MediaNameRecognition.recognize(relativePath: path))
    }
    return checksum
}

private func batch(_ paths: [String]) -> UInt64 {
    // Bound transient Objective-C objects to one corpus traversal on macOS.
    // Both executables use precisely the same boundary and consumer.
    #if canImport(ObjectiveC)
    return autoreleasepool { recognizeBatch(paths) }
    #else
    return recognizeBatch(paths)
    #endif
}

@main
private struct Driver {
    static func main() throws {
        let arguments = CommandLine.arguments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if arguments.count == 2, arguments[1] == "cases" {
            FileHandle.standardOutput.write(try encoder.encode(RecognitionCorpus.cases))
            return
        }
        if arguments.count == 2, arguments[1] == "dump" {
            let receipts = RecognitionCorpus.differentialPaths.map {
                Receipt(path: $0, media: MediaNameRecognition.recognize(relativePath: $0))
            }
            FileHandle.standardOutput.write(try encoder.encode(receipts))
            return
        }
        precondition(arguments.count == 4 && arguments[1] == "measure")
        let name = arguments[2]
        precondition(RecognitionCorpus.cases.contains(name))
        guard let passes = Int(arguments[3]), passes > 0 else { preconditionFailure("positive passes required") }
        let paths = RecognitionCorpus.paths(for: name)
        let warmup = batch(paths) &+ batch(paths)
        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<passes { checksum = checksum &* 31 &+ batch(paths) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        struct Measurement: Encodable {
            let workload: String
            let paths: Int
            let passes: Int
            let recognitions: Int
            let elapsed_nanoseconds: UInt64
            let checksum: String
            let warmup_checksum: String
        }
        let result = Measurement(workload: name, paths: paths.count, passes: passes,
                                 recognitions: paths.count * passes, elapsed_nanoseconds: elapsed,
                                 checksum: String(checksum), warmup_checksum: String(warmup))
        FileHandle.standardOutput.write(try encoder.encode(result))
    }
}
