import CryptoKit
import Foundation
import IlliquidCore

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Fixture {
    let candidates: [ThumbnailPolicy.Candidate]
    let current: URL?
    let folder: URL?
    let now: Date
    let preferences: ThumbnailPreferences
}

private struct OutputSignature: Codable, Equatable {
    let count: Int
    let sha256: String
}

private struct ScenarioReceipt: Codable {
    let scenario: String
    let input_count: Int
    let output: OutputSignature
}

private struct VerificationCase: Codable {
    let id: String
    let urls: [String]
}

private struct VerificationReceipt: Codable {
    let schema: Int
    let cases: Int
    let total_output_urls: Int
    let ordered_output_sha256: String
    let semantic_anchors: Int
    let scenarios: [ScenarioReceipt]
}

private struct TimingChecks: Codable {
    let output_count: Int
    let output_sha256: String
    let count_checksum: UInt64
}

private struct TimingReceipt: Codable {
    let scenario: String
    let iterations: Int
    let wall_nanoseconds: UInt64
    let checks: TimingChecks
}

@main
private enum ThumbnailRankingBenchmark {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let scenarioNames = [
        "no-folder-32", "no-folder-128", "no-folder-2048",
        "with-folder-32", "with-folder-128", "with-folder-2048",
    ]

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--verify"] {
            try emit(verify())
            return
        }
        guard arguments.count == 4,
              arguments[0] == "--scenario",
              arguments[2] == "--iterations",
              let iterations = Int(arguments[3]),
              iterations > 0,
              scenarioNames.contains(arguments[1])
        else {
            throw BenchmarkError(
                "Usage: --verify OR --scenario "
                    + scenarioNames.joined(separator: "|")
                    + " --iterations POSITIVE_INTEGER"
            )
        }
        try emit(measure(scenario: arguments[1], iterations: iterations))
    }

    private static func url(_ relative: String) -> URL {
        URL(fileURLWithPath: "/benchmark/media/" + relative)
    }

    private static func encoder() -> JSONEncoder {
        let result = JSONEncoder()
        result.outputFormatting = [.sortedKeys]
        return result
    }

    private static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let data = try encoder().encode(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signature(_ urls: [URL]) throws -> OutputSignature {
        OutputSignature(count: urls.count, sha256: try digest(urls.map(\.absoluteString)))
    }

    private static func emit<Value: Encodable>(_ value: Value) throws {
        let data = try encoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BenchmarkError("JSON encoding did not produce UTF-8.")
        }
        print(text)
    }

    private static func fixture(_ scenario: String) throws -> Fixture {
        guard scenarioNames.contains(scenario),
              let last = scenario.split(separator: "-").last,
              let count = Int(last)
        else { throw BenchmarkError("Unknown scenario: \(scenario)") }

        let folder = scenario.hasPrefix("with-folder-") ? url("active") : nil
        var candidates: [ThumbnailPolicy.Candidate] = []
        candidates.reserveCapacity(count)
        for index in 0..<count {
            let directory = index % 4 == 0 ? "active" : "history-\(index % 4)"
            // Spaces and non-ASCII names exercise ordinary Foundation file URLs.
            let itemURL = url("\(directory)/Episode \(index) café.mkv")
            let lastUsed: Date?
            switch index % 8 {
            case 0: lastUsed = nil
            case 1: lastUsed = now.addingTimeInterval(-8 * 86_400)
            default: lastUsed = now.addingTimeInterval(-Double(index % 6) * 86_400)
            }
            let neighborDistance = index > 0 && index < 10 ? index : nil
            candidates.append(.init(
                url: itemURL, lastUsed: lastUsed,
                isVisible: index % 31 == 3, neighborDistance: neighborDistance
            ))
        }
        return Fixture(
            candidates: candidates, current: candidates.first?.url,
            folder: folder, now: now, preferences: ThumbnailPreferences()
        )
    }

    // Keep the benchmark entry point out of the caller's optimization context.
    // The implementation under test remains the real production ranked method.
    @inline(never)
    private static func rank(_ fixture: Fixture) -> [URL] {
        ThumbnailPolicy.ranked(
            fixture.candidates, current: fixture.current, folder: fixture.folder,
            now: fixture.now, preferences: fixture.preferences,
            maximumCount: fixture.candidates.count
        )
    }

    private static func measure(scenario: String, iterations: Int) throws -> TimingReceipt {
        // Construction, URL standardization, and warm-up stay outside the timer.
        let fixture = try fixture(scenario)
        let warmupCount = rank(fixture).count
        guard warmupCount > 0 else {
            throw BenchmarkError("The timing fixture unexpectedly ranked no URLs.")
        }
        var output: [URL] = []
        var countChecksum: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            output = rank(fixture)
            countChecksum &+= UInt64(output.count)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        // Consume the full ordered URL output after measurement.
        let outputSignature = try signature(output)
        guard outputSignature.count == warmupCount else {
            throw BenchmarkError("The ranking output changed during measurement.")
        }
        return TimingReceipt(
            scenario: scenario, iterations: iterations, wall_nanoseconds: elapsed,
            checks: TimingChecks(
                output_count: outputSignature.count, output_sha256: outputSignature.sha256,
                count_checksum: countChecksum
            )
        )
    }

    private static func verificationCandidates() -> [ThumbnailPolicy.Candidate] {
        let duplicate = url("other/duplicate.mkv")
        let eligibleDuplicate = url("other/eligible-duplicate.mkv")
        return [
            .init(url: url("active/current.mkv")),
            .init(url: url("active/unmarked.mkv")),
            .init(url: url("active/recent.mkv"), lastUsed: now),
            .init(url: url("active/expired.mkv"), lastUsed: now.addingTimeInterval(-8 * 86_400)),
            .init(url: url("active/horizon.mkv"), lastUsed: now.addingTimeInterval(-7 * 86_400)),
            .init(url: url("active/past-horizon.mkv"), lastUsed: now.addingTimeInterval(-7 * 86_400 - 1)),
            .init(url: url("active/negative-neighbor.mkv"), neighborDistance: -2),
            .init(url: url("other/neighbor.mkv"), neighborDistance: 3),
            .init(url: url("other/visible.mkv"), isVisible: true),
            .init(url: url("active2/visible.mkv"), isVisible: true),
            .init(url: url("active/subfolder/child.mkv")),
            .init(url: url("other/tie-b.mkv"), lastUsed: now.addingTimeInterval(-100)),
            .init(url: url("other/tie-a.mkv"), lastUsed: now.addingTimeInterval(-100)),
            .init(url: url("other/future.mkv"), lastUsed: now.addingTimeInterval(86_400)),
            .init(url: duplicate),
            .init(url: duplicate, lastUsed: now, isVisible: true),
            .init(url: eligibleDuplicate, lastUsed: now),
            .init(url: eligibleDuplicate, isVisible: true, neighborDistance: 0),
            .init(url: url("active/subfolder/../normalized.mkv"), lastUsed: now),
            .init(url: url("active/normalized.mkv"), isVisible: true),
            .init(url: URL(string: "https://example.invalid/video.mkv")!,
                  lastUsed: now, isVisible: true, neighborDistance: 0),
        ]
    }

    private static func checkSemanticAnchors() throws -> Int {
        let plain = url("active/plain.mkv")
        let duplicate = url("other/duplicate.mkv")
        let tieB = url("other/tie-b.mkv")
        let tieA = url("other/tie-a.mkv")
        let settings = ThumbnailPreferences()

        func ranked(_ candidates: [ThumbnailPolicy.Candidate], current: URL? = nil,
                    folder: URL? = nil, maximumCount: Int? = nil) -> [URL] {
            ThumbnailPolicy.ranked(candidates, current: current, folder: folder,
                                  now: now, preferences: settings, maximumCount: maximumCount)
        }

        guard ranked([.init(url: plain)]).isEmpty else {
            throw BenchmarkError("Absent folder unexpectedly grants locality.")
        }
        guard ranked([.init(url: plain)], folder: url("active")) == [plain] else {
            throw BenchmarkError("Matching folder lost local eligibility.")
        }
        guard ranked([.init(url: plain)], current: plain) == [plain] else {
            throw BenchmarkError("Absent folder lost current-video eligibility.")
        }
        guard ranked([.init(url: duplicate), .init(url: duplicate, isVisible: true)]).isEmpty else {
            throw BenchmarkError("Duplicate ranking no longer keeps the first occurrence.")
        }
        guard ranked([.init(url: duplicate, isVisible: true), .init(url: duplicate)]) == [duplicate] else {
            throw BenchmarkError("Eligible first duplicate was not preserved.")
        }
        guard ranked([.init(url: tieB, lastUsed: now), .init(url: tieA, lastUsed: now)]) == [tieB, tieA] else {
            throw BenchmarkError("Equal-score input ordering changed.")
        }
        guard ranked([.init(url: plain, isVisible: true)], maximumCount: 0).isEmpty else {
            throw BenchmarkError("Zero maximum count did not return an empty ranking.")
        }
        return 7
    }

    private static func verify() throws -> VerificationReceipt {
        let anchors = try checkSemanticAnchors()
        let candidates = verificationCandidates()
        let folders: [URL?] = [nil, url("active"), url("active2")]
        let currents: [URL?] = [nil, url("active/current.mkv")]
        let limits: [Int?] = [nil, -1, 0, 1, 8, 64, 128, Int.max]
        let exclusions: [[String]] = [[], [url("active").path], [url("active2").path], ["/"]]
        let recencyWindows = [1, 7, 30]
        var cases: [VerificationCase] = []
        cases.reserveCapacity(1_728)
        var totalURLs = 0
        for priority in ThumbnailPreferences.Priority.allCases {
            for (folderIndex, folder) in folders.enumerated() {
                for (currentIndex, current) in currents.enumerated() {
                    for (limitIndex, limit) in limits.enumerated() {
                        for (exclusionIndex, excluded) in exclusions.enumerated() {
                            for days in recencyWindows {
                                var settings = ThumbnailPreferences()
                                settings.priority = priority
                                settings.recencyDays = days
                                settings.excludedFolderPaths = excluded
                                let output = ThumbnailPolicy.ranked(
                                    candidates, current: current, folder: folder, now: now,
                                    preferences: settings, maximumCount: limit
                                )
                                totalURLs += output.count
                                cases.append(VerificationCase(
                                    id: "\(priority.rawValue)/folder-\(folderIndex)/current-\(currentIndex)"
                                        + "/limit-\(limitIndex)/exclusion-\(exclusionIndex)/days-\(days)",
                                    urls: output.map(\.absoluteString)
                                ))
                            }
                        }
                    }
                }
            }
        }
        guard cases.count == 1_728 else {
            throw BenchmarkError("Verification matrix did not cover every expected case.")
        }
        var scenarios: [ScenarioReceipt] = []
        for scenario in scenarioNames {
            let input = try fixture(scenario)
            scenarios.append(ScenarioReceipt(
                scenario: scenario, input_count: input.candidates.count,
                output: try signature(rank(input))
            ))
        }
        return VerificationReceipt(
            schema: 1, cases: cases.count, total_output_urls: totalURLs,
            ordered_output_sha256: try digest(cases),
            semantic_anchors: anchors, scenarios: scenarios
        )
    }
}
