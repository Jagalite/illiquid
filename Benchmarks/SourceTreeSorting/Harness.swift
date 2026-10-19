import Foundation
import IlliquidCore

// Compiled alongside each revision's actual SourceTreeEntry and sorter.
// Receipts compare complete output order between revisions; there is no copied
// comparator. Metadata recognition and fixture construction are outside timing.
private let workloadNames = [
    "name-random", "name-sorted", "name-reverse", "name-duplicates",
    "mixed-name", "date-unique", "date-unique-descending", "date-ties", "date-only", "type-only",
    "off", "metadata-name",
]

private func shuffled<T>(_ values: [T], seed: UInt64) -> [T] {
    var result = values
    var state = seed
    if result.count > 1 {
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result.swapAt(index, Int(state % UInt64(index + 1)))
        }
    }
    return result
}

private func configuration(_ workload: String) -> SourceTreeSortConfiguration {
    .init(
        name: ["date-only", "type-only", "off"].contains(workload) ? .off : .ascending,
        dateCreated: workload == "date-unique-descending" ? .descending
            : ["date-unique", "date-ties", "date-only"].contains(workload) ? .ascending : .off,
        type: ["mixed-name", "date-ties", "type-only"].contains(workload) ? .ascending : .off
    )
}

private func makeEntry(ordinal: Int, url: URL, folder: Bool, date: Date?, metadata: Bool) -> SourceTreeEntry {
    var entry = SourceTreeEntry(
        url: url, kind: folder ? .folder : .media,
        dateAdded: Date(timeIntervalSince1970: Double(ordinal)), creationDate: date,
        visibilityPath: ordinal.isMultiple(of: 3) ? url.path : nil
    )
    if metadata { entry.recognizedMedia = MediaNameRecognition.recognize(relativePath: url.path) }
    return entry
}

private func fixture(size: Int, workload: String, seed: UInt64 = 0x5EED) -> [SourceTreeEntry] {
    let indices = Array(0..<size)
    let order = workload == "name-sorted" ? indices
        : workload == "name-reverse" ? Array(indices.reversed()) : shuffled(indices, seed: seed)
    return order.enumerated().map { ordinal, index in
        let folder = ["mixed-name", "date-ties", "type-only"].contains(workload) && index.isMultiple(of: 5)
        let path: String
        if workload == "name-duplicates" {
            path = "/fixtures/Folder \(index)/Episode 1.mkv"
        } else if workload == "metadata-name" {
            path = "/fixtures/Show \(index / 25) (2020)/Season 01/S01E\(index % 25).1080p.WEB-DL.mkv"
        } else {
            path = "/fixtures/\(folder ? "Season" : "Episode") \(index)\(folder ? "" : ".mkv")"
        }
        let date = index.isMultiple(of: 7) && !workload.hasPrefix("date-unique") ? nil
            : Date(timeIntervalSince1970: Double(workload == "date-ties" ? index % 4 : index))
        return makeEntry(ordinal: ordinal, url: URL(fileURLWithPath: path, isDirectory: folder),
                         folder: folder, date: date, metadata: workload == "metadata-name")
    }
}

private func adversarial(seed: UInt64?) -> [SourceTreeEntry] {
    let paths = [
        "Episode 2.mkv", "Episode 10.mkv", "episode 2.mkv", "Episode 02.mkv",
        "Épisode 2.mkv", "E\u{301}pisode 2.mkv", "épisode 2.mkv", "Ä.mkv", "Z.mkv",
        "猫 2.mkv", "猫 10.mkv", "👩‍💻.mkv", "100%.mkv", "a#b.mkv", "a?b.mkv",
        " A.mkv", ".hidden.mkv", "A/Equal.mkv", "a/Equal.mkv", "B/Equal.mkv",
        "Show (2020)/Season 01/S01E02.1080p.mkv", "Movie (2021)-trailer.mp4",
        "Same.mkv", "Same.mkv", "Same.mkv", "same.mkv", "plain", "Season 2",
    ]
    var urls = paths.map { URL(fileURLWithPath: "/fixtures/" + $0) }
    urls += [
        "file:///fixtures/encoded%20space.mkv", "file:///fixtures/encoded%2520space.mkv",
        "file:///fixtures/encoded%23hash.mkv", "file:///fixtures/encoded%2Fslash.mkv",
        "file:///fixtures/E%CC%81pisode%202.mkv", "file:///fixtures/%C3%89pisode%202.mkv",
    ].map { URL(string: $0)! }
    let order = seed.map { shuffled(Array(urls.indices), seed: $0) } ?? Array(urls.indices)
    return order.enumerated().map { ordinal, index in
        let duplicate = (22...24).contains(index)
        return makeEntry(ordinal: ordinal, url: urls[index],
                         folder: !duplicate && index.isMultiple(of: 4),
                         date: duplicate ? Date(timeIntervalSince1970: 100)
                            : index.isMultiple(of: 3) ? nil : Date(timeIntervalSince1970: Double(index % 4) - 2),
                         metadata: true)
    }
}

private func ordinal(_ entry: SourceTreeEntry) -> Int {
    guard let date = entry.dateAdded, let value = Int(exactly: date.timeIntervalSince1970) else {
        preconditionFailure("Sorter lost the fixture identity")
    }
    return value
}

private func checksum(_ values: [Int]) -> String {
    let hash = values.reduce(UInt64(14_695_981_039_346_656_037)) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

private func verifiedOrdinals(_ input: [SourceTreeEntry], using config: SourceTreeSortConfiguration) -> [Int] {
    let output = SourceTreeSorting.sorted(input, using: config)
    let ordinals = output.map(ordinal)
    precondition(output.count == input.count && Set(ordinals).count == input.count)
    for (entry, index) in zip(output, ordinals) {
        precondition(input.indices.contains(index) && entry == input[index], "Sorter changed entry metadata")
    }
    return ordinals
}

private func verify() -> [String: Any] {
    var cases: [(String, [SourceTreeEntry])] = [
        ("empty", []), ("singleton", fixture(size: 1, workload: "name-random")),
        ("adversarial", adversarial(seed: nil)),
        ("adversarial-shuffled", adversarial(seed: 0x12345678)),
    ]
    cases += workloadNames.map { ($0, fixture(size: 257, workload: $0)) }
    cases += [UInt64(1), UInt64.max].map { seed in
        ("seed-\(seed)", fixture(size: 293, workload: "date-ties", seed: seed))
    }
    var receipts: [[String: Any]] = []
    for (label, input) in cases {
        for name in SourceTreeSortDirection.allCases {
            for date in SourceTreeSortDirection.allCases {
                for type in SourceTreeSortDirection.allCases {
                    let config = SourceTreeSortConfiguration(name: name, dateCreated: date, type: type)
                    let ordinals = verifiedOrdinals(input, using: config)
                    receipts.append(["case": label, "name": name.rawValue, "date": date.rawValue,
                                     "type": type.rawValue, "count": input.count,
                                     "ordinals": ordinals, "checksum": checksum(ordinals)])
                }
            }
        }
    }
    return ["schema_version": 1, "mode": "verify", "cases": cases.count,
            "sorts": receipts.count, "metadata_preserved": true, "receipts": receipts]
}

@inline(never)
private func sortOnce(_ entries: [SourceTreeEntry], _ config: SourceTreeSortConfiguration) -> [SourceTreeEntry] {
    SourceTreeSorting.sorted(entries, using: config)
}

// The timer includes each complete sorted() call, returned-array destruction,
// and this identical endpoint/count checksum in both revisions. It does not
// retain result arrays between iterations or precompute any sorting keys.
@inline(never)
private func sortBatch(_ entries: [SourceTreeEntry], _ config: SourceTreeSortConfiguration, iterations: Int) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for _ in 0..<iterations {
        let result = sortOnce(entries, config)
        hash = (hash ^ UInt64(result.count)) &* 1_099_511_628_211
        if let first = result.first, let last = result.last {
            hash = (hash ^ UInt64(ordinal(first))) &* 1_099_511_628_211
            hash = (hash ^ UInt64(ordinal(last))) &* 1_099_511_628_211
        }
    }
    return hash
}

@main
private struct SourceTreeSortingHarness {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["verify"] { emit(verify()); return }
        if args.count == 3, args[0] == "verify-fixture", let size = Int(args[1]),
           (0...1_000_000).contains(size), workloadNames.contains(args[2]) {
            let entries = fixture(size: size, workload: args[2])
            let ordinals = verifiedOrdinals(entries, using: configuration(args[2]))
            emit(["schema_version": 1, "mode": "verify-fixture", "size": size,
                  "workload": args[2], "ordinals": ordinals, "metadata_preserved": true])
            return
        }
        guard args.count == 4, args[0] == "bench", let size = Int(args[1]),
              (0...1_000_000).contains(size), workloadNames.contains(args[2]),
              let iterations = Int(args[3]), iterations > 0 else {
            FileHandle.standardError.write(Data("Expected verify, verify-fixture <size> <workload>, or bench <size> <workload> <iterations>\n".utf8))
            exit(2)
        }
        let entries = fixture(size: size, workload: args[2])
        let config = configuration(args[2])
        let warmup = sortBatch(entries, config, iterations: 2)
        let start = DispatchTime.now().uptimeNanoseconds
        let hash = sortBatch(entries, config, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        emit(["schema_version": 1, "mode": "bench", "size": size, "workload": args[2],
              "iterations": iterations, "sorts": iterations, "elapsed_ns": elapsed,
              "checksum": String(hash, radix: 16), "warmup_checksum": String(warmup, radix: 16)])
    }

    private static func emit(_ object: [String: Any]) {
        var receipt = object
        receipt["locale"] = Locale.current.identifier
        receipt["entry_stride"] = MemoryLayout<SourceTreeEntry>.stride
        receipt["enumerated_entry_stride"] = MemoryLayout<(Int, SourceTreeEntry)>.stride
        receipt["index_stride"] = MemoryLayout<Int>.stride
        let data = try! JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
    }
}
