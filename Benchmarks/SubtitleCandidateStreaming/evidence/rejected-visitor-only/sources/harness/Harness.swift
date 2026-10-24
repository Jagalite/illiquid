import CHeapProbe
import Dispatch
import Foundation
import IlliquidCore

private enum Scenario: String, Codable {
    case broad, dense, exact, unrelated, empty
}

private struct Fixture {
    let scenario: Scenario
    let media: [URL]
    let subtitles: [URL]
    let exactTarget: Int
    let expectedExact: [URL]

    init(scenario: Scenario, count: Int) {
        precondition(count >= 2)
        self.scenario = scenario
        let target = count / 2
        exactTarget = target
        let root = URL(fileURLWithPath: "/tmp/illiquid-subtitle-candidate-streaming", isDirectory: true)
        let stems = (0..<count).map { index in
            let number = String(index)
            let digits = String(repeating: "0", count: max(0, 8 - number.count)) + number
            return scenario == .dense ? "Shared.Series." + digits + "p" : "Shared.Series.Episode." + digits
        }
        media = stems.map { root.appendingPathComponent($0 + (scenario == .dense ? ".x265.mkv" : ".1080p.WEB-DL.x265.mkv")) }
        expectedExact = ["en", "fr", "ja"].map {
            root.appendingPathComponent(stems[target] + "." + $0 + ".srt")
        }
        switch scenario {
        case .broad, .dense:
            // All candidates share this prefix and token count. Equal scores
            // leave the generic subtitle unassigned.
            subtitles = [root.appendingPathComponent("Shared.Series.en.srt")]
        case .exact: subtitles = expectedExact.reversed()
        case .unrelated: subtitles = [root.appendingPathComponent("Other.Series.en.srt")]
        case .empty: subtitles = []
        }
    }

    func verify(_ result: [URL: [URL]]) -> Receipt {
        precondition(result.count == media.count, "Missing or unexpected media keys")
        var digest: UInt64 = 14_695_981_039_346_656_037
        var assigned = 0
        for (index, url) in media.enumerated() {
            let expected: [URL] = scenario == .exact && index == exactTarget ? expectedExact : []
            precondition(result[url] == expected, "Association or subtitle order differs from fixture oracle")
            assigned += expected.count
            for byte in url.absoluteString.utf8 { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
            digest = (digest ^ 255) &* 1_099_511_628_211
            for subtitle in expected {
                for byte in subtitle.absoluteString.utf8 { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
                digest = (digest ^ 254) &* 1_099_511_628_211
            }
        }
        return Receipt(mediaCount: media.count, inputSubtitleCount: subtitles.count,
                       assignedSubtitleCount: assigned, associationDigest: String(digest, radix: 16))
    }
}

private struct Receipt: Codable, Equatable {
    let mediaCount: Int
    let inputSubtitleCount: Int
    let assignedSubtitleCount: Int
    let associationDigest: String
}

private struct Association: Codable {
    let media: String
    let subtitles: [String]
}

private struct Verification: Codable {
    let scenario: Scenario
    let receipt: Receipt
    let associations: [Association]
}

private final class HeapProbe {
    private(set) var before: UInt64 = 0
    private(set) var maximum: UInt64 = 0
    private(set) var polls: UInt64 = 0
    private(set) var maximumPoll: UInt64 = 0

    func start() {
        before = subtitle_candidate_heap_bytes()
        maximum = before
        polls = 0
        maximumPoll = 0
    }

    @inline(never)
    func poll() -> Bool {
        polls += 1
        let live = subtitle_candidate_heap_bytes()
        if live > maximum { maximum = live; maximumPoll = polls }
        return false
    }
}

private struct Observation: Codable {
    let mode: String
    let scenario: Scenario
    let receipt: Receipt
    let heapMetric: String
    let heapBeforeBytes: UInt64?
    let maximumSampledHeapBytes: UInt64?
    let heapWithOutputBytes: UInt64?
    let sampledPeakAllocatorGrowthBytes: Int64?
    let outputAllocatorGrowthBytes: Int64?
    let cancellationPollCount: UInt64?
    let maximumSamplePoll: UInt64?
    let iterations: Int
    let loopWallNanoseconds: UInt64?
    let loopCPUNanoseconds: UInt64?
    let consumedCount: UInt64?
}

@inline(never)
private func associate(_ fixture: Fixture) -> [URL: [URL]] {
    ExternalSubtitleMatcher.associate(subtitleURLs: fixture.subtitles, with: fixture.media, isCancelled: { false })
}

@inline(never)
private func warmup(_ probe: HeapProbe) {
    let tiny = Fixture(scenario: .broad, count: 4)
    probe.start()
    let result = ExternalSubtitleMatcher.associate(
        subtitleURLs: tiny.subtitles, with: tiny.media, isCancelled: { probe.poll() }
    )
    subtitle_candidate_consume(UInt64(result.count))
    _ = subtitle_candidate_cpu_nanoseconds()
    _ = DispatchTime.now().uptimeNanoseconds
    withExtendedLifetime((tiny, result)) {}
}

@inline(never)
private func memory(_ fixture: Fixture, probe: HeapProbe, metric: String) -> Observation {
    probe.start()
    let result = ExternalSubtitleMatcher.associate(
        subtitleURLs: fixture.subtitles, with: fixture.media, isCancelled: { probe.poll() }
    )
    let after = subtitle_candidate_heap_bytes()
    let maximum = max(after, probe.maximum)
    // Do not hash, serialize, inspect expected paths or construct output records
    // until all memory readings are complete.
    let receipt = fixture.verify(result)
    let observation = Observation(
        mode: "memory", scenario: fixture.scenario, receipt: receipt, heapMetric: metric,
        heapBeforeBytes: probe.before, maximumSampledHeapBytes: maximum,
        heapWithOutputBytes: after,
        sampledPeakAllocatorGrowthBytes: Int64(maximum) - Int64(probe.before),
        outputAllocatorGrowthBytes: Int64(after) - Int64(probe.before),
        cancellationPollCount: probe.polls, maximumSamplePoll: probe.maximumPoll,
        iterations: 1, loopWallNanoseconds: nil, loopCPUNanoseconds: nil, consumedCount: nil
    )
    withExtendedLifetime((fixture, result, probe)) {}
    return observation
}

@inline(never)
private func timingLoop(_ fixture: Fixture, iterations: Int) -> UInt64 {
    var consumed: UInt64 = 0
    for _ in 0..<iterations {
        let result = associate(fixture)
        consumed &+= UInt64(result.count)
        consumed &+= UInt64(result.values.reduce(0) { $0 + $1.count })
    }
    return consumed
}

@inline(never)
private func timing(_ fixture: Fixture, iterations: Int, metric: String) -> Observation {
    precondition(iterations > 0)
    for _ in 0..<2 {
        let result = associate(fixture)
        subtitle_candidate_consume(UInt64(result.count))
        withExtendedLifetime(result) {}
    }
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let cpuStart = subtitle_candidate_cpu_nanoseconds()
    let consumed = timingLoop(fixture, iterations: iterations)
    let cpuEnd = subtitle_candidate_cpu_nanoseconds()
    let wallEnd = DispatchTime.now().uptimeNanoseconds
    subtitle_candidate_consume(consumed)
    let result = associate(fixture)
    let receipt = fixture.verify(result)
    precondition(consumed == UInt64(iterations) * UInt64(receipt.mediaCount + receipt.assignedSubtitleCount))
    let observation = Observation(
        mode: "timing", scenario: fixture.scenario, receipt: receipt, heapMetric: metric,
        heapBeforeBytes: nil, maximumSampledHeapBytes: nil, heapWithOutputBytes: nil,
        sampledPeakAllocatorGrowthBytes: nil, outputAllocatorGrowthBytes: nil,
        cancellationPollCount: nil, maximumSamplePoll: nil, iterations: iterations,
        loopWallNanoseconds: wallEnd - wallStart, loopCPUNanoseconds: cpuEnd - cpuStart,
        consumedCount: consumed
    )
    withExtendedLifetime((fixture, result)) {}
    return observation
}

@main
private struct Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        precondition(arguments.count == 4, "Usage: CandidateBenchmark verify|memory|timing scenario media-count iterations")
        let mode = arguments[0], scenario = Scenario(rawValue: arguments[1])!
        let count = Int(arguments[2])!, iterations = Int(arguments[3])!
        let metric = String(cString: subtitle_candidate_heap_metric())
        precondition(metric != "unsupported", "Unsupported allocator accounting")
        let probe = HeapProbe()
        warmup(probe)
        let fixture = Fixture(scenario: scenario, count: count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded: Data
        switch mode {
        case "verify":
            let result = associate(fixture)
            let receipt = fixture.verify(result)
            let rows = fixture.media.map { url in
                Association(media: url.absoluteString, subtitles: result[url]!.map(\.absoluteString))
            }
            encoded = try encoder.encode(Verification(scenario: scenario, receipt: receipt, associations: rows))
            withExtendedLifetime(result) {}
        case "memory": encoded = try encoder.encode(memory(fixture, probe: probe, metric: metric))
        case "timing": encoded = try encoder.encode(timing(fixture, iterations: iterations, metric: metric))
        default: preconditionFailure("Unknown measurement mode")
        }
        print(String(decoding: encoded, as: UTF8.self))
        withExtendedLifetime((fixture, probe)) {}
    }
}
