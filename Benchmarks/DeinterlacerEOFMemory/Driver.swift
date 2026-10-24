import CFFmpeg
import CDeinterlacerProbe
import Foundation

private struct Workload {
    let width: Int32
    let height: Int32
    let count: Int
    var tenBit = false
    var topFirst = true
    var progressive = false
    var progressiveTail = false
    var changesFormat = false
    var holdsOutput = false

    static func named(_ name: String) throws -> Self {
        switch name {
        case "empty": return Self(width: 720, height: 576, count: 0)
        case "progressive": return Self(width: 1920, height: 1080, count: 6, progressive: true)
        case "one_tff": return Self(width: 720, height: 576, count: 1)
        case "sd_tff": return Self(width: 720, height: 576, count: 6)
        case "hd_tff": return Self(width: 1920, height: 1080, count: 6)
        case "hd_bff": return Self(width: 1920, height: 1080, count: 6, topFirst: false)
        case "uhd10_tff": return Self(width: 3840, height: 2160, count: 6, tenBit: true)
        case "mixed": return Self(width: 1920, height: 1080, count: 4, progressiveTail: true)
        case "format_change":
            return Self(width: 1920, height: 1080, count: 6, changesFormat: true)
        case "held_output":
            return Self(width: 1920, height: 1080, count: 4, progressiveTail: true, holdsOutput: true)
        default: throw PresentationError("Unknown workload \(name)")
        }
    }
}

private struct FrameRecord: Codable, Equatable {
    let width: Int32
    let height: Int32
    let pixelFormat: Int32
    let pts: Int64
    let duration: Int64
    let timeBaseNumerator: Int32
    let timeBaseDenominator: Int32
    let aspectNumerator: Int32
    let aspectDenominator: Int32
    let colorSpace: UInt32
    let colorRange: UInt32
    let colorPrimaries: UInt32
    let colorTransfer: UInt32
    let flags: Int32
    let filtered: Bool
    let copiedHardware: Bool
    let payloadBytes: Int
}

private struct AllocationSnapshot: Codable {
    let liveBytes: Int64
    let liveAllocations: Int64
    let freedAllocations: Int64
}

private struct Receipt: Codable {
    let workload: String
    let ffmpegVersion: String
    let inputCount: Int
    let outputCount: Int
    let expectedOutputCount: Int
    let totalInputBytes: Int64
    let totalInputAllocations: Int64
    let afterFeed: AllocationSnapshot
    let afterDrain: AllocationSnapshot
    let afterRepeatedDrain: AllocationSnapshot
    let afterConsumerRelease: AllocationSnapshot
    let afterReset: AllocationSnapshot
    let heldOutputSurvivedDrain: Bool
}

private func pixels(_ frame: UnsafeMutablePointer<AVFrame>) throws -> Data {
    let size = de_visible_size(frame)
    guard size > 0 else { throw PresentationError("Invalid visible output size") }
    var data = Data(count: Int(size))
    let copied = data.withUnsafeMutableBytes {
        de_copy_visible(frame, $0.bindMemory(to: UInt8.self).baseAddress, size)
    }
    guard copied == size else { throw PresentationError("Incomplete output snapshot") }
    return data
}

@main
private enum Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw PresentationError("Usage: Driver CASE METRICS_JSON PAYLOAD_BIN")
        }
        let workload = try Workload.named(arguments[1])
        guard let probe = de_probe_create() else { throw PresentationError("Cannot allocate probe") }
        defer { de_probe_destroy(probe) }
        let payloadURL = URL(fileURLWithPath: arguments[3])
        guard FileManager.default.createFile(atPath: payloadURL.path, contents: nil) else {
            throw PresentationError("Cannot create payload receipt")
        }
        let payload = try FileHandle(forWritingTo: payloadURL)
        defer { try? payload.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var outputCount = 0
        var held: UnsafeMutablePointer<AVFrame>?
        defer { av_frame_free(&held) }
        var heldPixels: Data?
        func snapshot() -> AllocationSnapshot {
            AllocationSnapshot(liveBytes: de_probe_live_bytes(probe),
                liveAllocations: de_probe_live_allocations(probe),
                freedAllocations: de_probe_freed_allocations(probe))
        }
        func accept(_ output: VideoDeinterlacer.Output) throws {
            let frame = output.frame.pointee
            let data = try pixels(output.frame)
            let record = FrameRecord(width: frame.width, height: frame.height,
                pixelFormat: frame.format, pts: frame.pts, duration: frame.duration,
                timeBaseNumerator: output.timeBase.numerator,
                timeBaseDenominator: output.timeBase.denominator,
                aspectNumerator: frame.sample_aspect_ratio.num,
                aspectDenominator: frame.sample_aspect_ratio.den,
                colorSpace: frame.colorspace.rawValue, colorRange: frame.color_range.rawValue,
                colorPrimaries: frame.color_primaries.rawValue, colorTransfer: frame.color_trc.rawValue,
                flags: frame.flags, filtered: output.filtered, copiedHardware: output.copiedHardware,
                payloadBytes: data.count)
            // Each JSON header ends in a newline and specifies the exact raw
            // visible-plane length that follows. No hashes replace pixel parity.
            try payload.write(contentsOf: encoder.encode(record))
            try payload.write(contentsOf: Data([10]))
            try payload.write(contentsOf: data)
            outputCount += 1
            if workload.holdsOutput {
                av_frame_free(&held)
                held = av_frame_clone(output.frame)
                guard held != nil else { throw PresentationError("Cannot retain emitted frame") }
                heldPixels = data
            }
        }
        let filter = try VideoDeinterlacer(timeBase: .init(numerator: 1, denominator: 25),
                                           nominalFrameRate: 25)
        let receipt = try withExtendedLifetime(filter) {
            for index in 0..<workload.count {
                var allocated = av_frame_alloc()
                guard let frame = allocated else { throw PresentationError("Cannot allocate input frame") }
                defer { av_frame_free(&allocated) }
                let firstFormat = workload.changesFormat && index < workload.count / 2
                frame.pointee.width = firstFormat ? 1280 : workload.width
                frame.pointee.height = firstFormat ? 720 : workload.height
                frame.pointee.format = Int32((workload.tenBit ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P).rawValue)
                frame.pointee.pts = Int64(index)
                frame.pointee.duration = 1
                frame.pointee.sample_aspect_ratio = .init(num: 1, den: 1)
                frame.pointee.colorspace = firstFormat ? AVCOL_SPC_BT709 : AVCOL_SPC_BT2020_NCL
                frame.pointee.color_range = AVCOL_RANGE_MPEG
                frame.pointee.color_primaries = firstFormat ? AVCOL_PRI_BT709 : AVCOL_PRI_BT2020
                frame.pointee.color_trc = workload.tenBit ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_BT709
                let interlaced = !workload.progressive && !(workload.progressiveTail && index == workload.count - 1)
                frame.pointee.flags = interlaced
                    ? AV_FRAME_FLAG_INTERLACED | (workload.topFirst ? AV_FRAME_FLAG_TOP_FIELD_FIRST : 0) : 0
                try checkFFmpeg(av_frame_get_buffer(frame, 32), operation: "Allocate input pixels")
                try checkFFmpeg(de_fill_frame(frame, Int32(index)), operation: "Fill input pixels")
                try checkFFmpeg(de_probe_tag_frame(probe, frame), operation: "Track input ownership")
                try filter.process(frame, while: { true }, emit: accept)
            }
            let afterFeed = snapshot()
            try filter.drain(while: { true }, emit: accept)
            let afterDrain = snapshot()
            let countAfterDrain = outputCount
            try filter.drain(while: { true }, emit: accept)
            guard outputCount == countAfterDrain else { throw PresentationError("Repeated drain emitted duplicates") }
            let afterRepeatedDrain = snapshot()
            var survivedDrain = true
            if let held {
                survivedDrain = try pixels(held) == heldPixels
            }
            av_frame_free(&held)
            heldPixels = nil
            let afterConsumerRelease = snapshot()
            filter.reset()
            let afterReset = snapshot()
            let expected = workload.progressive ? workload.count
                : workload.count * 2 - (workload.progressiveTail ? 1 : 0)
            guard outputCount == expected, survivedDrain,
                  afterReset.liveBytes == 0, afterReset.liveAllocations == 0 else {
                throw PresentationError("Output cadence, consumer ownership, or final cleanup failed")
            }
            return Receipt(workload: arguments[1], ffmpegVersion: String(cString: av_version_info()),
                inputCount: workload.count, outputCount: outputCount, expectedOutputCount: expected,
                totalInputBytes: de_probe_total_bytes(probe),
                totalInputAllocations: de_probe_total_allocations(probe),
                afterFeed: afterFeed, afterDrain: afterDrain,
                afterRepeatedDrain: afterRepeatedDrain, afterConsumerRelease: afterConsumerRelease,
                afterReset: afterReset, heldOutputSurvivedDrain: survivedDrain)
        }
        let data = try encoder.encode(receipt)
        try data.write(to: URL(fileURLWithPath: arguments[2]))
        print(String(decoding: data, as: UTF8.self))
    }
}
