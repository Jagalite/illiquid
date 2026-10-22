import CFFmpeg
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Fixture creation and destruction are deliberately outside measured regions.
final class AudioFixture {
    var frame: UnsafeMutablePointer<AVFrame>?

    init(layout: String, rate: Int32 = 48_000, format: AVSampleFormat = AV_SAMPLE_FMT_FLTP) {
        frame = av_frame_alloc()
        precondition(frame != nil)
        precondition(av_channel_layout_from_string(&frame!.pointee.ch_layout, layout) >= 0)
        frame!.pointee.sample_rate = rate
        frame!.pointee.format = Int32(format.rawValue)
        frame!.pointee.nb_samples = 1_024
    }

    init(customName: String) {
        frame = av_frame_alloc()
        precondition(frame != nil)
        precondition(benchmark_custom_layout(frame!, customName) >= 0)
        frame!.pointee.sample_rate = 48_000
        frame!.pointee.format = Int32(AV_SAMPLE_FMT_FLTP.rawValue)
        frame!.pointee.nb_samples = 1_024
    }

    deinit { av_frame_free(&frame) }
}

struct Workload {
    let name: String
    let frames: [AudioFixture]
    let outputChannels: [Int]
    let changeInterval: Int

    func index(_ iteration: Int) -> Int {
        (iteration / changeInterval) % frames.count
    }
}

func workloads() -> [Workload] {
    [
        Workload(name: "stable_mono", frames: [AudioFixture(layout: "mono")],
                 outputChannels: [2], changeInterval: 256),
        Workload(name: "stable_stereo", frames: [AudioFixture(layout: "stereo")],
                 outputChannels: [2], changeInterval: 256),
        Workload(name: "stable_5_1", frames: [AudioFixture(layout: "5.1")],
                 outputChannels: [6], changeInterval: 256),
        Workload(name: "stable_7_1", frames: [AudioFixture(layout: "7.1")],
                 outputChannels: [8], changeInterval: 256),
        Workload(name: "stable_unspecified", frames: [AudioFixture(layout: "2 channels")],
                 outputChannels: [2], changeInterval: 256),
        Workload(name: "stable_custom", frames: [AudioFixture(customName: "front")],
                 outputChannels: [2], changeInterval: 256),
        Workload(name: "stable_ambisonic", frames: [AudioFixture(layout: "ambisonic 1+stereo")],
                 outputChannels: [2], changeInterval: 256),
        Workload(name: "rate_changes", frames: [AudioFixture(layout: "stereo", rate: 44_100),
                                               AudioFixture(layout: "stereo", rate: 48_000)],
                 outputChannels: [2, 2], changeInterval: 256),
        Workload(name: "sample_format_changes", frames: [AudioFixture(layout: "stereo", format: AV_SAMPLE_FMT_FLTP),
                                                        AudioFixture(layout: "stereo", format: AV_SAMPLE_FMT_S16)],
                 outputChannels: [2, 2], changeInterval: 256),
        Workload(name: "output_changes", frames: [AudioFixture(layout: "5.1"), AudioFixture(layout: "5.1")],
                 outputChannels: [6, 2], changeInterval: 256),
        Workload(name: "same_count_layout_changes", frames: [AudioFixture(layout: "5.1"),
                                                            AudioFixture(layout: "5.1(side)")],
                 outputChannels: [6, 6], changeInterval: 256),
        Workload(name: "native_changes_every_frame", frames: [AudioFixture(layout: "5.1"),
                                                             AudioFixture(layout: "5.1(side)")],
                 outputChannels: [6, 6], changeInterval: 1),
        Workload(name: "custom_changes_every_frame", frames: [AudioFixture(customName: "front"),
                                                             AudioFixture(customName: "alternate")],
                 outputChannels: [2, 2], changeInterval: 1),
    ]
}

struct TimedResult: Encodable {
    let workload: String
    let iterations: Int
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: Double
    let checksum: UInt64
    let last: MetadataResult
}

@inline(never)
func run(_ workload: Workload, iterations: Int) throws -> TimedResult {
    // Warm a different tracker so first-use metadata work is still measured.
    var warmup = MetadataTracker()
    for iteration in 0..<2_048 {
        let index = workload.index(iteration)
        _ = try warmup.prepare(workload.frames[index].frame!, outputChannels: workload.outputChannels[index])
    }
    var tracker = MetadataTracker()
    var checksum: UInt64 = 0
    var last: MetadataResult?
    let cpuStart = clock()
    let start = DispatchTime.now().uptimeNanoseconds
    for iteration in 0..<iterations {
        let index = workload.index(iteration)
        let value = try tracker.prepare(workload.frames[index].frame!, outputChannels: workload.outputChannels[index])
        // Consume every result without re-hashing a layout string in the timer.
        // Full strings and change decisions are compared by the separate trace.
        checksum &+= UInt64(value.sampleRate) &+ UInt64(value.channelCount)
            &+ UInt64(value.outputChannelCount) &+ value.revision
            &+ (value.changed ? 1 : 0)
        last = value
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpu = Double(clock() - cpuStart) * 1_000_000_000 / Double(CLOCKS_PER_SEC)
    return TimedResult(workload: workload.name, iterations: iterations,
                       elapsedNanoseconds: elapsed, cpuNanoseconds: cpu,
                       checksum: checksum, last: last!)
}

struct Trace: Encodable {
    let ffmpegVersion: String
    let libavutilVersion: UInt32
    let workloads: [String: [MetadataResult]]
    let mutatedFrame: [MetadataResult]
}

func verify(_ workloads: [Workload]) throws -> Trace {
    var traces: [String: [MetadataResult]] = [:]
    for workload in workloads {
        var tracker = MetadataTracker()
        var trace: [MetadataResult] = []
        for iteration in 0..<1_025 {
            let index = workload.index(iteration)
            trace.append(try tracker.prepare(workload.frames[index].frame!, outputChannels: workload.outputChannels[index]))
        }
        traces[workload.name] = trace
    }
    // Reuse one AVFrame's address, as the production decoder does. A pointer
    // identity cache would fail this trace when its layout changes in place.
    let fixture = AudioFixture(layout: "stereo")
    var tracker = MetadataTracker()
    var mutated: [MetadataResult] = []
    for name in ["stereo", "5.1", "5.1(side)", "2 channels", "stereo", "ambisonic 1+stereo", "stereo"] {
        av_channel_layout_uninit(&fixture.frame!.pointee.ch_layout)
        precondition(av_channel_layout_from_string(&fixture.frame!.pointee.ch_layout, name) >= 0)
        for _ in 0..<3 {
            mutated.append(try tracker.prepare(fixture.frame!, outputChannels: 2))
        }
    }
    for name in ["front", "alternate", "front"] {
        precondition(benchmark_custom_layout(fixture.frame!, name) >= 0)
        for _ in 0..<3 {
            mutated.append(try tracker.prepare(fixture.frame!, outputChannels: 2))
        }
    }
    return Trace(ffmpegVersion: String(cString: av_version_info()), libavutilVersion: avutil_version(),
                 workloads: traces, mutatedFrame: mutated)
}

@main
struct Main {
    static func main() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let args = Array(CommandLine.arguments.dropFirst())
        let all = workloads()
        let data: Data
        if args == ["verify"] {
            data = try encoder.encode(verify(all))
        } else {
            precondition(args.count == 3 && args[0] == "measure")
            let workload = all.first { $0.name == args[1] }!
            let iterations = Int(args[2])!
            precondition(iterations > 0)
            data = try encoder.encode(run(workload, iterations: iterations))
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
