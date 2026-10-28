import Foundation

@_silgen_name("subtitle_key_heap_bytes") private func heapBytes() -> UInt64
@_silgen_name("subtitle_key_heap_metric") private func heapMetric() -> UnsafePointer<CChar>
@_silgen_name("subtitle_key_cpu_nanoseconds") private func cpuNanoseconds() -> UInt64

#if ALLOCATION_METER
@_silgen_name("subtitle_key_meter_reset") private func meterReset()
@_silgen_name("subtitle_key_meter_enable") private func meterEnable()
@_silgen_name("subtitle_key_meter_disable") private func meterDisable()
@_silgen_name("subtitle_key_meter_requests") private func meterRequests() -> UInt64
@_silgen_name("subtitle_key_meter_bytes") private func meterBytes() -> UInt64
#endif

private struct Fixture {
    let scenario: String
    let suffix: String
    let longPrefix = String(repeating: "9", count: 4_096)
    let padding = String(repeating: "p", count: 4_096)

    init(_ scenario: String) {
        self.scenario = scenario
        let bytes: Int
        switch scenario {
        case "tiny": bytes = 32
        case "text", "long-prefix", "offset-input", "no-comma": bytes = 128
        case "dense", "duplicate", "overallocated": bytes = 4_096
        case "drawing": bytes = 65_536
        default: preconditionFailure("Unknown scenario: \(scenario)")
        }
        let fields = "0,Default,,0,0,0,,"
        suffix = fields + String(repeating: "x", count: bytes - fields.utf8.count)
    }

    /// The ordinary path mirrors SubtitleDecoder's fresh Data(String.utf8).
    /// Neither the returned Data nor the event String is kept outside ingestion.
    @inline(never)
    func packet(_ index: Int) -> Data {
        if scenario == "no-comma" {
            return Data(String(repeating: "x", count: suffix.utf8.count).utf8)
        }
        let prefix = scenario == "long-prefix" ? longPrefix : String(index + 10_000)
        let text = "\(prefix),\(suffix)"
        if scenario == "offset-input" {
            let backing = Data("\(padding)\(text)\(padding)".utf8)
            return backing[padding.utf8.count..<(padding.utf8.count + text.utf8.count)]
        }
        var data = Data(text.utf8)
        if scenario == "overallocated" {
            // Deliberate nonproduction negative control: zero-based Data does
            // not reveal spare capacity. The sharing policy cannot detect this.
            data.reserveCapacity(data.count * 4)
        }
        return data
    }

    func identity(_ index: Int) -> Int64 {
        Int64(scenario == "duplicate" ? index % 64 : index) * 20
    }
}

private typealias History = [Set<ProcessedSubtitlePacketKey>]

@inline(never)
private func ingest(_ fixture: Fixture, packets: Int, pipelines: Int, metered: Bool = false) -> History {
    var history = Array(repeating: Set<ProcessedSubtitlePacketKey>(), count: pipelines)
    for index in 0..<packets {
        let data = fixture.packet(index)
        let start = fixture.identity(index)
        #if ALLOCATION_METER
        if metered { meterEnable() }
        #endif
        for pipeline in 0..<pipelines {
            history[pipeline].insert(ProcessedSubtitlePacketKey(
                presentationMilliseconds: start, durationMilliseconds: 2_000, packetData: data
            ))
        }
        #if ALLOCATION_METER
        if metered { meterDisable() }
        #endif
    }
    return history
}

/// Order-independent check, outside measured intervals. The tests separately
/// compare exact Data equality and Set decisions against the old expression.
private func checksum(_ history: History) -> UInt64 {
    var result: UInt64 = 0
    for keys in history {
        for key in keys {
            var bytes: UInt64 = 14_695_981_039_346_656_037
            for byte in key.data { bytes = (bytes ^ UInt64(byte)) &* 1_099_511_628_211 }
            result &+= bytes ^ UInt64(bitPattern: key.presentationMilliseconds)
                ^ UInt64(bitPattern: key.durationMilliseconds)
        }
    }
    return result
}

private func keyCount(_ history: History) -> Int { history.reduce(0) { $0 + $1.count } }

@main
private struct Harness {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 6, "mode scenario pipelines packets iterations")
        let mode = args[1], scenario = args[2]
        guard let pipelines = Int(args[3]), (1...2).contains(pipelines),
              let packets = Int(args[4]), packets > 0,
              let iterations = Int(args[5]), iterations > 0 else {
            preconditionFailure("Positive counts and one/two pipelines required")
        }
        let fixture = Fixture(scenario)
        // Warm shared runtime/collection paths before heap/timing snapshots.
        for _ in 0..<2 {
            let warm = ingest(fixture, packets: 64, pipelines: pipelines)
            precondition(keyCount(warm) > 0)
            withExtendedLifetime(warm) {}
        }

        var fields: [String: Any] = [
            "mode": mode, "scenario": scenario, "pipelines": pipelines,
            "input_packets": packets, "iterations": iterations,
            "suffix_bytes": fixture.suffix.utf8.count,
        ]
        switch mode {
        case "retain":
            let before = heapBytes()
            var history = ingest(fixture, packets: packets, pipelines: pipelines)
            let retained = heapBytes()
            let count = keyCount(history)
            let digest = checksum(history)
            withExtendedLifetime(history) {}
            history.removeAll(keepingCapacity: false)
            let released = heapBytes()
            fields["allocator_metric"] = String(cString: heapMetric())
            fields["retained_allocator_delta_bytes"] = Int64(retained) - Int64(before)
            fields["released_allocator_delta_bytes"] = Int64(released) - Int64(before)
            fields["unique_keys"] = count
            fields["payload_checksum"] = String(digest)
        case "time":
            var final: History = []
            var observed = 0
            let cpuStart = cpuNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            for iteration in 0..<iterations {
                let history = ingest(fixture, packets: packets, pipelines: pipelines)
                observed &+= keyCount(history)
                if iteration == iterations - 1 { final = history }
            }
            let wall = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpu = cpuNanoseconds() - cpuStart
            precondition(observed == keyCount(final) * iterations)
            fields["wall_nanoseconds"] = wall
            fields["cpu_nanoseconds"] = cpu
            fields["unique_keys"] = keyCount(final)
            fields["payload_checksum"] = String(checksum(final))
            withExtendedLifetime(final) {}
        case "allocation":
            #if ALLOCATION_METER
            meterReset()
            let history = ingest(fixture, packets: packets, pipelines: pipelines, metered: true)
            meterDisable()
            fields["allocation_requests"] = meterRequests()
            fields["requested_bytes"] = meterBytes()
            fields["unique_keys"] = keyCount(history)
            fields["payload_checksum"] = String(checksum(history))
            withExtendedLifetime(history) {}
            #else
            preconditionFailure("Use the separate allocation-instrumented binary")
            #endif
        default: preconditionFailure("Unknown mode: \(mode)")
        }
        let output = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
