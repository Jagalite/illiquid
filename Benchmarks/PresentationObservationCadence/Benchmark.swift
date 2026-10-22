import CoreMedia
import Foundation

// The runner adds the exact production setter in a separate extension. Its
// serial DispatchQueue and interval state are real; observer replacement is a
// recorder because this experiment isolates admission, not AVFoundation work.
final class BenchmarkPresentationReceiver: @unchecked Sendable {
    let commitQueue = DispatchQueue(
        label: "illiquid.cadence-benchmark.presentation", qos: .userInteractive
    )
    var terminated = false
    var presentationTimeObservationInterval = CMTime(value: 1, timescale: 30)
    private(set) var setterEntries = 0
    private(set) var replacementCount = 0
    private var history: [CMTime] = []
    private let recordsHistory: Bool

    init(recordsHistory: Bool) { self.recordsHistory = recordsHistory }

    func apply(_ interval: CMTime) {
        // Every fixture is a positive numeric interval, so every setter entry
        // reaches exactly one commitQueue.sync in the unmodified setter.
        setterEntries += 1
        setPresentationTimeObservationInterval(interval)
    }

    func replacePresentationTimeObserver() {
        replacementCount += 1
        if recordsHistory { history.append(presentationTimeObservationInterval) }
    }

    func trace() -> [[String: Any]] {
        commitQueue.sync {
            history.map { ["value": $0.value, "timescale": $0.timescale,
                           "epoch": $0.epoch, "flags": $0.flags.rawValue] }
        }
    }

    func terminate() { commitQueue.sync { terminated = true } }

    func finalInterval() -> String {
        commitQueue.sync {
            "\(presentationTimeObservationInterval.value)/\(presentationTimeObservationInterval.timescale)"
        }
    }
}

@MainActor
private final class Driver {
    let receiver: BenchmarkPresentationReceiver
    #if CANDIDATE
    private var cadence = PresentationObservationCadence()
    #endif

    init(recordsHistory: Bool) {
        receiver = BenchmarkPresentationReceiver(recordsHistory: recordsHistory)
    }

    @inline(never)
    func request(_ interval: CMTime) {
        #if CANDIDATE
        cadence.update(interval) { receiver.apply($0) }
        #else
        receiver.apply(interval)
        #endif
    }
}

private struct Workload {
    let name: String
    let intervals: [CMTime]
}

private func workloads() -> [Workload] {
    func interval(_ rate: Double, subtitles: Bool = true) -> CMTime {
        NativeSubtitleRenderPolicy.observationInterval(hasSubtitles: subtitles, frameRate: rate)
    }
    let off = interval(24, subtitles: false)
    var cases = [Workload(name: "steady-4hz", intervals: [off])]
    for rate in [24.0, 30, 60, 120] {
        cases.append(Workload(name: "steady-\(Int(rate))hz", intervals: [interval(rate)]))
    }
    // Subtitle off/on and a 30 -> 60 Hz deinterlacing transition. Changes are
    // separated by repeated requests; these are fixtures, not playback traces.
    let transitions = [off, interval(24), off, interval(30), interval(60), off]
        .flatMap { Array(repeating: $0, count: 128) }
    cases.append(Workload(name: "periodic-transitions", intervals: transitions))
    cases.append(Workload(name: "alternating-control", intervals: [off, interval(60)]))
    precondition(cases.allSatisfy { $0.intervals.allSatisfy { $0.isNumeric && $0.seconds > 0 } })
    return cases
}

@MainActor
@inline(never)
private func exercise(_ driver: Driver, intervals: [CMTime], requests: Int) {
    for index in 0..<requests { driver.request(intervals[index % intervals.count]) }
}

private func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

@main
private enum CadenceBenchmark {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let cases = workloads()
        if arguments == ["verify"] {
            var records: [[String: Any]] = []
            for workload in cases {
                let driver = Driver(recordsHistory: true)
                exercise(driver, intervals: workload.intervals, requests: 4_096)
                records.append([
                    "workload": workload.name, "requests": 4_096,
                    "queue_sync_entries": driver.receiver.setterEntries,
                    "effective_changes": driver.receiver.replacementCount,
                    "final_interval": driver.receiver.finalInterval(),
                    "trace": driver.receiver.trace(),
                ])
            }
            // Each runtime/receiver lifetime owns a new gate. Repeating the same
            // initial request in a new owner must still reach that new receiver.
            for owner in 0..<2 {
                let driver = Driver(recordsHistory: true)
                let interval = cases[0].intervals[0]
                exercise(driver, intervals: [interval], requests: 8)
                let before = driver.receiver.replacementCount
                driver.receiver.terminate()
                exercise(driver, intervals: cases.last!.intervals, requests: 8)
                precondition(driver.receiver.replacementCount == before)
                records.append([
                    "workload": "receiver-lifetime-\(owner)", "requests": 16,
                    "queue_sync_entries": driver.receiver.setterEntries,
                    "effective_changes": driver.receiver.replacementCount,
                    "final_interval": driver.receiver.finalInterval(),
                    "trace": driver.receiver.trace(),
                ])
            }
            try printJSON(records)
            return
        }
        guard arguments.count == 3, arguments[0] == "measure",
              let workload = cases.first(where: { $0.name == arguments[1] }),
              let requests = Int(arguments[2]), requests > 0 else {
            fatalError("Usage: CadenceBenchmark verify | measure WORKLOAD REQUESTS")
        }
        // Warm a separate owner. Timed work includes first-request admission.
        let warmup = Driver(recordsHistory: false)
        exercise(warmup, intervals: workload.intervals, requests: min(requests, 10_000))
        let driver = Driver(recordsHistory: false)
        let start = DispatchTime.now().uptimeNanoseconds
        exercise(driver, intervals: workload.intervals, requests: requests)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        try printJSON([
            "workload": workload.name, "requests": requests, "wall_ns": elapsed,
            "ns_per_request": Double(elapsed) / Double(requests),
            "queue_sync_entries": driver.receiver.setterEntries,
            "effective_changes": driver.receiver.replacementCount,
            "final_interval": driver.receiver.finalInterval(),
            "warmup_requests": min(requests, 10_000),
        ])
    }
}
