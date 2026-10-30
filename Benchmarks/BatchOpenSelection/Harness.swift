import BatchOpenComponent
import Dispatch
import Foundation

// Compile this driver separately from the production component, without
// cross-module optimization. Fixture construction is outside the timed loop.
private struct Workload {
    let count: Int
    let scenario: String
    var id: String { "\(count)-\(scenario)" }
    var json: [String: Any] {
        ["id": id, "count": count, "scenario": scenario]
    }
}

private struct Fixture {
    let items: [FolderPlaylistItem]
    let currentURL: URL?
    let expectedIndex: Int?
    let expectedPreservesCurrent: Bool
}

private enum HarnessError: Error {
    case invalidArguments
    case incorrectResult(String)
}

private func workloads() -> [Workload] {
    let cases: [(Int, String)] = [
        (0, "empty"),
        (1, "first"), (1, "miss"), (1, "nil-current"), (1, "invalid-current"),
        (32, "first"), (32, "middle"), (32, "last"), (32, "miss"),
        (1_000, "first"), (1_000, "middle"), (1_000, "last"), (1_000, "miss"),
        (10_000, "first"), (10_000, "last"), (10_000, "miss"),
        (1_000, "unicode-alias"), (1_000, "invalid-current"),
        (1_000, "all-invalid"), (1_000, "nil-current"),
    ]
    return cases.map { Workload(count: $0.0, scenario: $0.1) }
}

private func fixture(for workload: Workload) throws -> Fixture {
    let path = workload.scenario == "unicode-alias"
        ? "/Volumes/Media/Café-日本語" : "/Volumes/Media/Shows"
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let remote = URL(string: "https://example.invalid/Media/")!
    func filename(_ index: Int) -> String {
        "Episode " + String(format: "%06d", index) + ".mkv"
    }
    let items = (0..<workload.count).map { index in
        FolderPlaylistItem(
            url: (workload.scenario == "all-invalid" ? remote : folder)
                .appendingPathComponent(filename(index)),
            dateAdded: Date(timeIntervalSince1970: Double(index))
        )
    }
    var target: URL? = folder.appendingPathComponent("Missing.mkv")
    var match: Int?
    switch workload.scenario {
    case "first": match = 0
    case "middle": match = workload.count / 2
    case "last", "unicode-alias": match = workload.count - 1
    case "nil-current": target = nil
    case "invalid-current": target = remote.appendingPathComponent("Missing.mkv")
    case "empty", "miss", "all-invalid": break
    default: throw HarnessError.invalidArguments
    }
    if let match {
        guard items.indices.contains(match) else { throw HarnessError.invalidArguments }
        target = items[match].url
        if workload.scenario == "unicode-alias" {
            target = URL(fileURLWithPath: path.decomposedStringWithCanonicalMapping
                + "/ignored/../" + filename(match))
        }
    }
    return Fixture(
        items: items,
        currentURL: target,
        expectedIndex: match ?? items.indices.first,
        expectedPreservesCurrent: match != nil
    )
}

private func checkedResult(
    _ fixture: Fixture, label: String
) throws -> BatchOpenSelectionResult {
    let actual = BatchOpenSelection.select(
        currentURL: fixture.currentURL, items: fixture.items
    )
    guard actual.selectedIndex == fixture.expectedIndex,
          actual.preservesCurrent == fixture.expectedPreservesCurrent else {
        throw HarnessError.incorrectResult(
            "\(label): index=\(String(describing: actual.selectedIndex)), "
                + "preservesCurrent=\(actual.preservesCurrent); expected "
                + "\(String(describing: fixture.expectedIndex)), "
                + "\(fixture.expectedPreservesCurrent)"
        )
    }
    return actual
}

private func witness(index: Int?, preservesCurrent: Bool) -> UInt64 {
    (UInt64((index ?? -1) + 1) << 1) | (preservesCurrent ? 1 : 0)
}

private struct RawItemPayload: Encodable {
    let url: URL
    let externalSubtitleURLs: [URL]
    let dateAdded: Date
}

private func decodedItem(_ url: URL, marker: Int) throws -> FolderPlaylistItem {
    // Synthesized Decodable bypasses FolderPlaylistItem's normalizing init.
    let payload = RawItemPayload(
        url: url,
        externalSubtitleURLs: [URL(fileURLWithPath: "/Media/marker-\(marker).srt")],
        dateAdded: Date(timeIntervalSince1970: Double(marker))
    )
    return try JSONDecoder().decode(
        FolderPlaylistItem.self, from: JSONEncoder().encode(payload)
    )
}

private func verify() throws -> [String: Any] {
    var checks = 0
    var results: [[String: Any]] = []
    var checksum: UInt64 = 0
    func record(
        _ items: [FolderPlaylistItem], _ current: URL?,
        _ index: Int?, _ preserved: Bool, _ label: String
    ) throws {
        let result = try checkedResult(Fixture(
            items: items, currentURL: current,
            expectedIndex: index, expectedPreservesCurrent: preserved
        ), label: label)
        checksum &+= witness(index: result.selectedIndex,
                             preservesCurrent: result.preservesCurrent)
        results.append([
            "label": label,
            "selectedIndex": result.selectedIndex.map { $0 as Any } ?? NSNull(),
            "preservesCurrent": result.preservesCurrent,
        ])
        checks += 1
    }

    for workload in workloads() {
        let value = try fixture(for: workload)
        try record(value.items, value.currentURL, value.expectedIndex,
                   value.expectedPreservesCurrent, workload.id)
    }

    let a = URL(fileURLWithPath: "/Media/A.mkv")
    let alias = URL(string: "file://localhost/Media/ignored/../A.mkv")!
    let b = URL(fileURLWithPath: "/Media/B.mkv")
    let invalid = URL(string: "https://example.invalid/Media/A.mkv")!
    // Independent labels define identity; neither production implementation
    // nor NormalizedFileURL computes these expectations.
    let fixtures: [(item: FolderPlaylistItem, identity: Int?)] = [
        (try decodedItem(a, marker: 0), 0),
        (try decodedItem(alias, marker: 1), 0),
        (try decodedItem(b, marker: 2), 1),
        (try decodedItem(invalid, marker: 3), nil),
    ]
    let targets: [(url: URL?, identity: Int?)] = [
        (nil, nil), (a, 0), (alias, 0), (b, 1),
        (URL(fileURLWithPath: "/Media/Missing.mkv"), 2), (invalid, nil),
    ]
    var queues: [[Int]] = [[]]
    var layer: [[Int]] = [[]]
    for _ in 0..<4 {
        layer = layer.flatMap { prefix in fixtures.indices.map { prefix + [$0] } }
        queues.append(contentsOf: layer)
    }
    for queue in queues {
        let items = queue.map { fixtures[$0].item }
        for (targetNumber, target) in targets.enumerated() {
            let match = target.identity.flatMap { identity in
                queue.firstIndex { fixtures[$0].identity == identity }
            }
            try record(items, target.url, match ?? items.indices.first, match != nil,
                       "queue-\(queue)-target-\(targetNumber)")
        }
    }

    let canonical = URL(fileURLWithPath: "/Media/Café.mkv")
    let base = URL(string: "file:///Media/")!
    let aliases = [
        URL(string: "file:///Media/Caf%C3%A9.mkv")!,
        URL(string: "file:///Media/ignored/../Cafe%CC%81.mkv")!,
        URL(string: "file://localhost/Media/Caf%C3%A9.mkv")!,
        URL(string: "file://LOCALHOST/Media/Cafe%CC%81.mkv")!,
        URL(string: "ignored/../Cafe%CC%81.mkv", relativeTo: base)!,
    ]
    for (number, spelling) in aliases.enumerated() {
        let items = [
            try decodedItem(b, marker: 0),
            try decodedItem(spelling, marker: 1),
            try decodedItem(canonical, marker: 2),
        ]
        try record(items, canonical, 1, true, "decoded-alias-\(number)")
        try record(items, spelling, 1, true, "alias-target-\(number)")
    }

    let unsupported = [
        "https://example.invalid/Media/A.mkv",
        "file://media-server.example/Media/A.mkv",
        "file://127.0.0.1/Media/A.mkv",
        "file://user@localhost/Media/A.mkv",
        "file://user:example@localhost/Media/A.mkv",
        "file://localhost:1234/Media/A.mkv",
        "file://localhost:0/Media/A.mkv",
        "file:relative.mkv",
    ]
    for (number, spelling) in unsupported.enumerated() {
        let url = URL(string: spelling)!
        let bad = try decodedItem(url, marker: 0)
        let good = try decodedItem(a, marker: 1)
        try record([bad], url, 0, false, "unsupported-single-\(number)")
        try record([bad, good], url, 0, false, "unsupported-target-\(number)")
        try record([bad, good], a, 1, true, "unsupported-item-\(number)")
    }
    for other in ["/Elsewhere/A.mkv", "/Media/a.mkv"] {
        try record([FolderPlaylistItem(url: a), FolderPlaylistItem(url: b)],
                   URL(fileURLWithPath: other), 0, false, "distinct-\(other)")
    }
    guard queues.count == 341, checks == 2_102 else {
        throw HarnessError.incorrectResult("verification corpus count changed")
    }
    return ["status": "passed", "checks": checks,
            "checksum": NSNumber(value: checksum), "results": results]
}

@inline(never)
private func measure(_ workload: Workload, iterations: Int) throws -> [String: Any] {
    let value = try fixture(for: workload)
    for _ in 0..<3 {
        _ = try checkedResult(value, label: workload.id)
    }
    var checksum: UInt64 = 0
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        let actual = BatchOpenSelection.select(
            currentURL: value.currentURL, items: value.items
        )
        checksum &+= witness(index: actual.selectedIndex,
                             preservesCurrent: actual.preservesCurrent)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    let expected = witness(index: value.expectedIndex,
                           preservesCurrent: value.expectedPreservesCurrent)
    guard checksum == expected &* UInt64(iterations) else {
        throw HarnessError.incorrectResult("timed checksum: \(workload.id)")
    }
    let actual = try checkedResult(value, label: workload.id)
    return [
        "workload": workload.json,
        "iterations": iterations,
        "selectedIndex": actual.selectedIndex.map { $0 as Any } ?? NSNull(),
        "preservesCurrent": actual.preservesCurrent,
        "checksum": NSNumber(value: checksum),
        "wall_ns": NSNumber(value: elapsed),
        "ns_per_call": Double(elapsed) / Double(iterations),
    ]
}

private func emit(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

@main
private enum Harness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["list"] {
            try emit(workloads().map(\.json))
        } else if arguments == ["verify"] {
            try emit(verify())
        } else if arguments.count == 3, arguments[0] == "measure",
                  let workload = workloads().first(where: { $0.id == arguments[1] }),
                  let iterations = Int(arguments[2]),
                  (1...100_000_000).contains(iterations) {
            try emit(measure(workload, iterations: iterations))
        } else {
            throw HarnessError.invalidArguments
        }
    }
}
