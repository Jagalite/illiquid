import Dispatch
import Foundation
import IlliquidCore

/// Both isolated packages use the same module name and this exact driver.
/// Only the complete production MediaNameRecognition.swift differs between them.
@main
enum RecognitionBenchmarkDriver {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            try emit(RecognitionCorpus.benchmarkCases().map { CaseDescription(name: $0.name, count: $0.paths.count) })
            return
        }
        if arguments == ["--differential"] {
            let rows = RecognitionCorpus.differentialPaths().map { path in
                SemanticRow(path: path, result: .init(MediaNameRecognition.recognize(relativePath: path)))
            }
            try emit(rows)
            return
        }
        guard arguments.count == 4, arguments[0] == "--case", arguments[2] == "--iterations",
              let iterations = Int(arguments[3]), iterations > 0,
              let workload = RecognitionCorpus.benchmarkCases().first(where: { $0.name == arguments[1] })
        else {
            throw DriverError("usage: RecognitionBenchmark --list | --differential | --case NAME --iterations POSITIVE_INT")
        }
        let (operations, overflow) = iterations.multipliedReportingOverflow(by: workload.paths.count)
        guard !overflow else { throw DriverError("operation count overflows Int") }

        // Complete semantic output is built and checked before measurement.
        // Cross-variant parity is checked by the runner's full differential pass;
        // this local pass additionally rejects nondeterministic process results.
        let expected = workload.paths.map(MediaNameRecognition.recognize(relativePath:))
        let semanticRows = zip(workload.paths, expected).map { SemanticRow(path: $0.0, result: .init($0.1)) }
        let repeated = workload.paths.map { SemanticRow(path: $0, result: .init(MediaNameRecognition.recognize(relativePath: $0))) }
        guard semanticRows == repeated else { throw DriverError("recognition output changed during preflight") }
        let semanticChecksum = stableChecksum(try encoder().encode(semanticRows))
        let expectedMinimal = expected.reduce(UInt64(0)) { $0 &+ observation($1) }

        var retained: [RecognizedMediaName] = []
        retained.reserveCapacity(workload.paths.count)
        var warmupChecksum: UInt64 = 0
        for _ in 0..<2 {
            recognizeBatch(workload.paths, retained: &retained, checksum: &warmupChecksum)
        }
        guard retained == expected else { throw DriverError("recognition output changed during warmup") }

        var checksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            recognizeBatch(workload.paths, retained: &retained, checksum: &checksum)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        // Retain a complete batch across the timer boundary and consume all its
        // stored/derived fields afterwards. No JSON encoding or corpus generation
        // is part of the timed recognition workload.
        let finalRows = zip(workload.paths, retained).map { SemanticRow(path: $0.0, result: .init($0.1)) }
        guard finalRows == semanticRows, checksum == expectedMinimal &* UInt64(iterations) else {
            throw DriverError("timed recognition output differs from preflight")
        }
        try emit(Measurement(caseName: workload.name, iterations: iterations, operations: operations,
                             elapsedNS: elapsed, checksum: hexadecimal(checksum),
                             semanticChecksum: semanticChecksum))
        withExtendedLifetime(retained) {}
    }

    /// Batch retention and a small observation are identical for both variants.
    /// The module call is not inlinable, and complete results remain observable.
    @inline(never)
    private static func recognizeBatch(_ paths: [String], retained: inout [RecognizedMediaName], checksum: inout UInt64) {
        retained.removeAll(keepingCapacity: true)
        for path in paths {
            let result = MediaNameRecognition.recognize(relativePath: path)
            checksum &+= observation(result)
            retained.append(result)
        }
    }

    private static func observation(_ result: RecognizedMediaName) -> UInt64 {
        let kind: UInt64
        switch result.kind {
        case .movie: kind = 1
        case .episode: kind = 2
        case .extra: kind = 3
        case .unknown: kind = 4
        }
        return UInt64(result.title.utf8.count) &+ UInt64(result.year ?? 0) &+ kind
    }

    private static func stableChecksum(_ data: Data) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            value = (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hexadecimal(value)
    }

    private static func hexadecimal(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let data = try encoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

private struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct CaseDescription: Encodable {
    let name: String
    let count: Int
}

private struct Measurement: Encodable {
    let caseName: String
    let iterations: Int
    let operations: Int
    let elapsedNS: UInt64
    let checksum: String
    let semanticChecksum: String

    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, operations
        case elapsedNS = "elapsed_ns"
        case checksum
        case semanticChecksum = "semantic_checksum"
    }
}

private struct SemanticRow: Encodable, Equatable {
    let path: String
    let result: SemanticResult
}

/// Include every stored field and every user-visible derived field. Explicit null
/// values make optional-field coverage inspectable in the differential artifact.
private struct SemanticResult: Encodable, Equatable {
    let kind: String
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?
    let lastEpisode: Int?
    let airDate: String?
    let episodeTitle: String?
    let edition: String?
    let catalogIDs: [String]
    let variant: String?
    let metadataSources: [String]
    let seriesTitle: String
    let displayName: String
    let section: String

    init(_ value: RecognizedMediaName) {
        kind = value.kind.rawValue
        title = value.title
        year = value.year
        season = value.season
        episode = value.episode
        lastEpisode = value.lastEpisode
        airDate = value.airDate
        episodeTitle = value.episodeTitle
        edition = value.edition
        catalogIDs = value.catalogIDs
        variant = value.variant
        metadataSources = value.metadataSources
        seriesTitle = value.seriesTitle
        displayName = value.displayName
        section = value.section
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, year, season, episode, lastEpisode, airDate, episodeTitle
        case edition, catalogIDs, variant, metadataSources, seriesTitle, displayName, section
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(year, forKey: .year)
        try container.encode(season, forKey: .season)
        try container.encode(episode, forKey: .episode)
        try container.encode(lastEpisode, forKey: .lastEpisode)
        try container.encode(airDate, forKey: .airDate)
        try container.encode(episodeTitle, forKey: .episodeTitle)
        try container.encode(edition, forKey: .edition)
        try container.encode(catalogIDs, forKey: .catalogIDs)
        try container.encode(variant, forKey: .variant)
        try container.encode(metadataSources, forKey: .metadataSources)
        try container.encode(seriesTitle, forKey: .seriesTitle)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(section, forKey: .section)
    }
}
