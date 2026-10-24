import Foundation
import IlliquidCore
import CMemoryProbe

private struct BenchmarkFailure: Error, CustomStringConvertible {
    let description: String
}

private struct MemoryReading {
    let heap: UInt64
    let rss: UInt64

    @inline(never)
    static func capture() -> Self {
        Self(heap: UInt64(memory_probe_heap_bytes()),
             rss: UInt64(memory_probe_rss_bytes()))
    }
}

private struct Fixture {
    let name: String
    let media: [URL]
    let subtitles: [URL]
    let firstMatch: URL?
    let lastMatch: URL?

    static func make(_ name: String) throws -> Self {
        let count: Int
        switch name {
        case "release16": count = 16
        case "release256": count = 256
        case "release4096", "plain4096", "mixed4096", "unicode4096", "empty4096": count = 4_096
        case "release32768": count = 32_768
        default: throw BenchmarkFailure(description: "Unknown memory workload: \(name)")
        }
        let directory = URL(fileURLWithPath: "/benchmark/illiquid-subtitle-qualifier-storage", isDirectory: true)
        let suffix = ".1080p.WEB-DL.x265.10bit.AAC"
        func stem(_ index: Int) -> String {
            let number = String(index)
            let padded = String(repeating: "0", count: max(0, 6 - number.count)) + number
            return name == "unicode4096"
                ? "Café.冒険.Épisode.\(padded)"
                : "Memory.Adventure.Episode.\(padded)"
        }
        var media: [URL] = []
        media.reserveCapacity(count)
        for index in 0..<count {
            let qualified = name != "plain4096" && (name != "mixed4096" || index.isMultiple(of: 2))
            media.append(directory.appendingPathComponent(stem(index) + (qualified ? suffix : "") + ".mkv"))
        }
        if name == "empty4096" {
            return Self(name: name, media: media, subtitles: [], firstMatch: nil, lastMatch: nil)
        }
        let first = directory.appendingPathComponent(stem(0) + ".en.sdh.srt")
        let last = directory.appendingPathComponent(stem(count - 1) + ".ja.forced.ass")
        return Self(name: name, media: media,
                    subtitles: [directory.appendingPathComponent("Unrelated.Observer.en.srt"), first, last],
                    firstMatch: first, lastMatch: last)
    }

    func expectedSubtitles(at index: Int) -> [URL] {
        if index == 0, let firstMatch { return [firstMatch] }
        if index == media.count - 1, let lastMatch { return [lastMatch] }
        return []
    }
}

/// Stable, length-delimited checksum of every output key and ordered value.
/// It is a parity receipt; it is not a cryptographic integrity digest.
private struct OutputChecksum {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ number: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            value = (value ^ UInt64(UInt8(truncatingIfNeeded: number >> shift))) &* 1_099_511_628_211
        }
    }

    mutating func append(_ string: String) {
        append(UInt64(string.utf8.count))
        for byte in string.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
    }

    mutating func append(media: URL, subtitles: [URL]) {
        append(media.absoluteString)
        append(UInt64(subtitles.count))
        for subtitle in subtitles { append(subtitle.absoluteString) }
    }

    var rendered: String {
        let digits = String(value, radix: 16)
        return "fnv1a64:" + String(repeating: "0", count: 16 - digits.count) + digits
    }
}

@main
private enum MemoryDriver {
    @inline(never)
    private static func warmRuntime() throws {
        let directory = URL(fileURLWithPath: "/benchmark/qualifier-warmup", isDirectory: true)
        let media = [
            directory.appendingPathComponent("Warm.Adventure.1080p.WEB-DL.x265.10bit.AAC.mkv"),
            directory.appendingPathComponent("Café.冒険.Épisode.1080p.WEB-DL.x265.10bit.AAC.mkv"),
        ]
        let subtitles = [directory.appendingPathComponent("Warm.Adventure.en.sdh.srt"),
                         directory.appendingPathComponent("Café.冒険.Épisode.ja.forced.ass")]
        let result = ExternalSubtitleMatcher.associate(subtitleURLs: subtitles, with: media, isCancelled: { false })
        guard result.count == 2, result[media[0]] == [subtitles[0]], result[media[1]] == [subtitles[1]] else {
            throw BenchmarkFailure(description: "Runtime warmup association failed")
        }
        withExtendedLifetime((media, subtitles, result)) {}
        for _ in 0..<3 {
            _ = MemoryReading.capture()
            _ = memory_probe_peak_rss_bytes()
        }
    }

    private static func measure(_ fixture: Fixture) throws -> [String: Any] {
        try withExtendedLifetime(fixture) {
            // One initial poll, N output-map polls, then N media-index polls.
            // The next poll precedes processing the first subtitle. Neither
            // production source nor the cancellation cadence is instrumented.
            let targetPoll = 2 * fixture.media.count + 2
            var callbackCount = 0
            var sampledPoll: Int?
            var sampleCount = 0
            var indexReading: MemoryReading?
            let neverCancel: () -> Bool = {
                callbackCount += 1
                if callbackCount == targetPoll {
                    sampledPoll = callbackCount
                    sampleCount += 1
                    indexReading = MemoryReading.capture()
                }
                return false
            }
            let before = MemoryReading.capture()
            let result = ExternalSubtitleMatcher.associate(
                subtitleURLs: fixture.subtitles, with: fixture.media, isCancelled: neverCancel)
            let after = withExtendedLifetime(result) { MemoryReading.capture() }
            let peakRSS = UInt64(memory_probe_peak_rss_bytes())

            if fixture.subtitles.isEmpty {
                guard sampleCount == 0, indexReading == nil, callbackCount == fixture.media.count + 2 else {
                    throw BenchmarkFailure(description: "Empty-input fast path unexpectedly reached index sampling")
                }
            } else {
                guard sampleCount == 1, sampledPoll == targetPoll, indexReading != nil else {
                    throw BenchmarkFailure(description: "Did not sample the completed media index exactly once")
                }
            }
            guard result.count == fixture.media.count else {
                throw BenchmarkFailure(description: "Output map has missing or extra media keys")
            }
            var actualChecksum = OutputChecksum()
            var expectedChecksum = OutputChecksum()
            var associationCount = 0
            var associatedMediaCount = 0
            for (index, media) in fixture.media.enumerated() {
                guard let actual = result[media] else {
                    throw BenchmarkFailure(description: "Missing output media key at index \(index)")
                }
                let expected = fixture.expectedSubtitles(at: index)
                guard actual == expected else {
                    throw BenchmarkFailure(description: "Association mismatch at media index \(index)")
                }
                associationCount += actual.count
                if !actual.isEmpty { associatedMediaCount += 1 }
                actualChecksum.append(media: media, subtitles: actual)
                expectedChecksum.append(media: media, subtitles: expected)
            }
            guard actualChecksum.rendered == expectedChecksum.rendered,
                  associationCount == (fixture.subtitles.isEmpty ? 0 : 2) else {
                throw BenchmarkFailure(description: "Full output checksum or association count failed")
            }
            return [
                "schema_version": 1,
                "case": fixture.name,
                "input_count": fixture.media.count,
                "sampled_poll": sampledPoll.map { $0 as Any } ?? NSNull(),
                "sample_count": sampleCount,
                "callback_count": callbackCount,
                "heap_before": before.heap,
                "heap_index": indexReading.map { $0.heap as Any } ?? NSNull(),
                "heap_after": after.heap,
                "rss_before": before.rss,
                "rss_index": indexReading.map { $0.rss as Any } ?? NSNull(),
                "rss_after": after.rss,
                "peak_rss": peakRSS,
                "all_output_checksum": actualChecksum.rendered,
                "oracle_output_checksum": expectedChecksum.rendered,
                "media_count": result.count,
                "subtitle_count": fixture.subtitles.count,
                "association_count": associationCount,
                "associated_media_count": associatedMediaCount,
            ]
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw BenchmarkFailure(description: "Usage: MemoryDriver <case-name>")
        }
        try warmRuntime()
        let fixture = try Fixture.make(CommandLine.arguments[1])
        let report = try measure(fixture)
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
