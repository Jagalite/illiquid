import Foundation
import Dispatch
import IlliquidCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Fixture {
    let items: [FolderPlaylistItem]
    let saved: [String]
    let expected: [String]
}

private func key(_ label: Int, unicode: Bool) -> String {
    if unicode {
        return "/Media/Caf\u{00E9}/\u{6771}\u{4EAC}/"
            + String(repeating: "Long \u{00E9}pisode title ", count: 8)
            + "\(label).mkv"
    }
    return "/Media/Series/Episode \(label).mkv"
}

private func fixture(size: Int, workload: String) -> Fixture {
    let original = Array(0..<size)
    var current = Array(original.reversed())
    var saved = original
    switch workload {
    case "unchanged", "unicode":
        break
    case "edited":
        current.removeAll { $0 % 4 == 0 }
        current += Array(size..<(size + (size + 3) / 4))
    case "duplicates":
        current += current
        saved += original.reversed()
        saved += [size + 1, size + 1]
    case "duplicate-heavy":
        current = (0..<size).map { $0 % max(1, min(16, size)) }
        saved = Array((0..<min(16, size)).reversed()) + [size + 1]
    case "no-base":
        saved = []
    default:
        preconditionFailure("Unknown workload")
    }
    let unicode = workload == "unicode"
    let items = current.enumerated().map { offset, label in
        FolderPlaylistItem(
            url: URL(fileURLWithPath: key(label, unicode: unicode)),
            externalSubtitleURLs: (0..<(label % 3)).map {
                URL(fileURLWithPath: "/Subtitles/\(label)-\(offset)-\($0).srt")
            },
            dateAdded: Date(timeIntervalSince1970: Double(offset))
        )
    }

    // Independent integer-label oracle: sort current unique labels by the
    // earliest saved rank, followed by the earliest current rank for additions.
    var currentRank: [Int: Int] = [:]
    for (rank, label) in current.enumerated() where currentRank[label] == nil {
        currentRank[label] = rank
    }
    var savedRank: [Int: Int] = [:]
    for (rank, label) in saved.enumerated() where savedRank[label] == nil {
        savedRank[label] = rank
    }
    let expectedLabels = currentRank.keys.sorted { left, right in
        switch (savedRank[left], savedRank[right]) {
        case let (a?, b?): return a < b
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return currentRank[left]! < currentRank[right]!
        }
    }
    return Fixture(
        items: items,
        saved: saved.map { key($0, unicode: unicode) },
        expected: expectedLabels.map { key($0, unicode: unicode) }
    )
}

@inline(never)
private func reconcile(_ input: Fixture) -> [String] {
    #if CHECKPOINT_BASELINE
    return PlaylistMutation.restoringOrder(input.items, ids: input.saved).map(\.id)
    #else
    return PlaylistMutation.restoringIDs(input.items, ids: input.saved)
    #endif
}

private func bytes(_ values: [String]) -> [Data] {
    values.map { Data($0.utf8) }
}

private func fullChecksum(_ values: [String]) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for string in values {
        for byte in string.utf8 {
            value = (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
        value = (value ^ 255) &* 1_099_511_628_211
    }
    return String(value)
}

private func consume(_ output: [String], index: Int) -> UInt64 {
    var value = UInt64(output.count)
    if !output.isEmpty {
        let selected = output[index % output.count]
        value = value &* 1_099_511_628_211 &+ UInt64(selected.utf8.count)
        value = value &* 1_099_511_628_211 &+ UInt64(selected.utf8.first ?? 0)
        value = value &* 1_099_511_628_211 &+ UInt64(selected.utf8.last ?? 0)
    }
    return value
}

@inline(never)
private func oneIteration(_ input: Fixture, index: Int) -> UInt64 {
    // The result is consumed and destroyed before this noninlined call returns.
    consume(reconcile(input), index: index)
}

@inline(never)
private func measureIterations(_ input: Fixture, iterations: Int) -> UInt64 {
    var value: UInt64 = 14_695_981_039_346_656_037
    for index in 0..<iterations {
        value = (value ^ oneIteration(input, index: index)) &* 1_099_511_628_211
    }
    return value
}

private func expectedMeasuredChecksum(_ expected: [String], iterations: Int) -> UInt64 {
    var value: UInt64 = 14_695_981_039_346_656_037
    for index in 0..<iterations {
        value = (value ^ consume(expected, index: index)) &* 1_099_511_628_211
    }
    return value
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func main() throws {
    let arguments = CommandLine.arguments
    precondition(arguments.count >= 4, "usage: Harness verify|bench SIZE WORKLOAD [ITERATIONS]")
    let mode = arguments[1]
    guard let size = Int(arguments[2]), (0...100_000).contains(size) else {
        preconditionFailure("Invalid size")
    }
    let workload = arguments[3]
    let input = fixture(size: size, workload: workload)
    let before = reconcile(input)
    precondition(bytes(before) == bytes(input.expected), "Independent fixture oracle failed")
    let expectedChecksum = fullChecksum(input.expected)
    precondition(fullChecksum(before) == expectedChecksum)

    if mode == "verify" {
        try emit([
            "size": size, "workload": workload,
            "input_count": input.items.count, "saved_count": input.saved.count,
            "unique_count": input.expected.count,
            "ordered_utf8_base64": bytes(before).map { $0.base64EncodedString() },
            "full_checksum": expectedChecksum,
        ])
        return
    }
    precondition(mode == "bench" && arguments.count == 5)
    guard let iterations = Int(arguments[4]), (1...2_000_000).contains(iterations) else {
        preconditionFailure("Invalid iterations")
    }
    // Full comparison is outside timing. A small identical rotating consumption
    // inside the interval prevents dead-result elimination without hashing paths.
    let expectedMeasured = expectedMeasuredChecksum(input.expected, iterations: iterations)
    _ = measureIterations(input, iterations: min(3, iterations))
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let cpuStart = cpuNanoseconds()
    let measured = measureIterations(input, iterations: iterations)
    let cpuElapsed = cpuNanoseconds() - cpuStart
    let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    precondition(measured == expectedMeasured, "Timed output consumption mismatch")
    let after = reconcile(input)
    precondition(bytes(after) == bytes(input.expected), "Post-timing exact output mismatch")
    precondition(fullChecksum(after) == expectedChecksum)
    try emit([
        "size": size, "workload": workload, "iterations": iterations,
        "input_count": input.items.count, "saved_count": input.saved.count,
        "unique_count": input.expected.count,
        "cpu_ns": cpuElapsed, "wall_ns": wallElapsed,
        "measured_checksum": String(measured),
        "expected_measured_checksum": String(expectedMeasured),
        "full_checksum": expectedChecksum, "exact_output_verified": true,
    ])
}

try main()
