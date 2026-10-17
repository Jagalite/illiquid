import Dispatch
import Foundation
import IlliquidCore

// This driver is compiled separately from the optimized production module.
// Neither API is @inlinable, and cross-module optimization is not enabled.
private struct Workload: Codable {
    let id: String
    let api: String
    let count: Int
    let scenario: String
}

private struct Observation: Encodable {
    let workload: Workload
    let iterations: Int
    let expectedIndex: Int?
    let checksum: UInt64
    let elapsedMilliseconds: Double
    let nanosecondsPerCall: Double
}

private enum HarnessError: Error {
    case invalidArguments
    case fixtureOrder(String)
    case incorrectResult(String)
}

private func workloads() -> [Workload] {
    let cases: [(Int, String)] = [
        (0, "empty"), (1, "first"), (1, "all-invalid"),
        (32, "first"), (32, "middle"), (32, "last"), (32, "miss"),
        (1_000, "last"), (1_000, "miss"),
        (10_000, "last"), (10_000, "miss"),
        (1_000, "unicode-alias"), (1_000, "all-invalid"),
    ]
    var result = [Workload]()
    for api in ["mutation", "folder"] {
        result += cases.map { count, scenario in
            Workload(id: "\(api)-\(count)-\(scenario)", api: api,
                     count: count, scenario: scenario)
        }
    }
    for (count, scenario) in [(1_000, "nil-current"), (1, "invalid-current"),
                              (32, "invalid-fallback")] {
        result.append(Workload(id: "mutation-\(count)-\(scenario)", api: "mutation",
                               count: count, scenario: scenario))
    }
    return result
}

private struct Fixture {
    let items: [FolderPlaylistItem]
    let playlist: FolderPlaylist?
    let currentURL: URL?
    let fallbackIndex: Int?
    let expectedIndex: Int?

    init(_ workload: Workload) throws {
        let longPath = "/Volumes/Media/" + Array(
            repeating: "Café-日本語-Long-folder-name", count: 6
        ).joined(separator: "/")
        let path = workload.scenario == "unicode-alias" ? longPath : "/Volumes/Media/Shows"
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        func filename(_ label: Int) -> String {
            "Episode " + String(format: "%06d", label) + ".mkv"
        }
        let created = (0..<workload.count).map { label in
            let url = workload.scenario == "all-invalid"
                ? URL(string: "https://example.invalid/" + filename(label)
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
                : folder.appendingPathComponent(filename(label))
            return FolderPlaylistItem(url: url, dateAdded: Date(timeIntervalSince1970: Double(label)))
        }
        if workload.api == "folder" {
            let value = FolderPlaylist(folderURL: folder, items: Array(created.reversed()))
            // The expectation is based on independent fixture labels, not an
            // identity helper or either lookup implementation.
            guard value.items.map({ Int($0.dateAdded!.timeIntervalSince1970) })
                    == Array(0..<workload.count) else {
                throw HarnessError.fixtureOrder(workload.id)
            }
            playlist = value
            items = value.items
        } else {
            playlist = nil
            items = created
        }

        var target: URL? = folder.appendingPathComponent("Missing.mkv")
        var fallback: Int? = workload.count > 0 ? workload.count / 3 : 0
        var match: Int?
        switch workload.scenario {
        case "first": match = 0
        case "middle": match = workload.count / 2
        case "last", "unicode-alias": match = workload.count - 1
        case "nil-current": target = nil
        case "invalid-current": target = URL(string: "https://example.invalid/Missing.mkv")!
        case "invalid-fallback": fallback = workload.count + 5
        default: break
        }
        if let match {
            // Select the actual sorted position after checking the label order.
            // Normal cases use already prepared canonical URLs, like callers.
            target = items[match].url
            if workload.scenario == "unicode-alias" {
                target = URL(fileURLWithPath: path.decomposedStringWithCanonicalMapping
                    + "/temporary/../" + filename(match))
            }
        }
        currentURL = target
        fallbackIndex = fallback
        if let match {
            expectedIndex = match
        } else if workload.api == "folder" || workload.count == 0 {
            expectedIndex = nil
        } else if let fallback, (0..<workload.count).contains(fallback) {
            expectedIndex = fallback
        } else {
            expectedIndex = 0
        }
    }
}

@inline(never)
private func measure(_ workload: Workload, _ fixture: Fixture, iterations: Int) throws -> Observation {
    let expected = UInt64((fixture.expectedIndex ?? -1) + 1)
    var checksum: UInt64 = 0
    let started: UInt64
    let ended: UInt64
    if workload.api == "mutation" {
        guard PlaylistMutation.indexPreservingCurrentIdentity(
            currentURL: fixture.currentURL, fallbackIndex: fixture.fallbackIndex,
            in: fixture.items
        ) == fixture.expectedIndex else { throw HarnessError.incorrectResult(workload.id) }
        started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            let actual = PlaylistMutation.indexPreservingCurrentIdentity(
                currentURL: fixture.currentURL, fallbackIndex: fixture.fallbackIndex,
                in: fixture.items
            )
            checksum &+= UInt64((actual ?? -1) + 1)
        }
        ended = DispatchTime.now().uptimeNanoseconds
    } else {
        let playlist = fixture.playlist!
        let target = fixture.currentURL!
        guard playlist.index(of: target) == fixture.expectedIndex else {
            throw HarnessError.incorrectResult(workload.id)
        }
        started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            checksum &+= UInt64((playlist.index(of: target) ?? -1) + 1)
        }
        ended = DispatchTime.now().uptimeNanoseconds
    }
    // Consume every result inside the timed loop; validate after stopping the
    // clock. Setup, sorting, expectation construction, and one warmup are untimed.
    guard checksum == expected &* UInt64(iterations) else {
        throw HarnessError.incorrectResult(workload.id)
    }
    let elapsed = Double(ended - started)
    return Observation(workload: workload, iterations: iterations,
                       expectedIndex: fixture.expectedIndex, checksum: checksum,
                       elapsedMilliseconds: elapsed / 1_000_000,
                       nanosecondsPerCall: elapsed / Double(iterations))
}

@main
private enum Harness {
    static func main() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let arguments = Array(CommandLine.arguments.dropFirst())
        let output: Data
        if arguments == ["--list"] {
            output = try encoder.encode(workloads())
        } else {
            guard arguments.count == 2,
                  let workload = workloads().first(where: { $0.id == arguments[0] }),
                  let iterations = Int(arguments[1]), iterations > 0 else {
                throw HarnessError.invalidArguments
            }
            output = try encoder.encode(measure(workload, try Fixture(workload), iterations: iterations))
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}
