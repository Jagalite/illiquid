import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import IlliquidFormatBenchmark

// The production-backed adapter is compiled as a separate optimized module.
// Do not enable cross-module optimization. This driver cannot inline away the
// native creation or the candidate cache. These are metadata/sample-construction
// measurements; no decoding, display layer, or renderer is exercised.
private struct Workload: Codable {
    let id: String
    let api: String
    let count: Int
    let scenario: String
    let unitsPerCall: Int
    let unit: String
}

private struct Observation: Encodable {
    let workload: Workload
    let iterations: Int
    let warmupCalls: Int
    let expectedChecksumPerCall: UInt64
    let checksum: UInt64
    let elapsedMilliseconds: Double
    let nanosecondsPerCall: Double
    let nanosecondsPerUnit: Double
}

private enum HarnessError: Error {
    case invalidArguments
    case nativeFailure(String, Int32)
    case invalidFixture(String)
    case incorrectResult(String)
}

private func workloads() -> [Workload] {
    [
        Workload(id: "format-bgra-stable", api: "format", count: 120,
                 scenario: "bgra", unitsPerCall: 120, unit: "frame"),
        Workload(id: "format-nv12-sdr-stable", api: "format", count: 120,
                 scenario: "nv12", unitsPerCall: 120, unit: "frame"),
        Workload(id: "format-p010-hdr-stable", api: "format", count: 120,
                 scenario: "p010-hdr", unitsPerCall: 120, unit: "frame"),
        Workload(id: "format-nv12-ring", api: "format", count: 120,
                 scenario: "equal-ring", unitsPerCall: 120, unit: "frame"),
        Workload(id: "format-dimensions-every60", api: "format", count: 120,
                 scenario: "dimensions-every60", unitsPerCall: 120, unit: "frame"),
        Workload(id: "format-metadata-every-frame", api: "format", count: 120,
                 scenario: "metadata-every-frame", unitsPerCall: 120, unit: "frame"),
        Workload(id: "format-same-buffer-metadata-every60", api: "format", count: 120,
                 scenario: "same-buffer-metadata-every60",
                 unitsPerCall: 120, unit: "frame"),
        Workload(id: "sample-nv12-sdr-stable", api: "sample", count: 120,
                 scenario: "nv12", unitsPerCall: 120, unit: "frame"),
        Workload(id: "sample-p010-hdr-stable", api: "sample", count: 120,
                 scenario: "p010-hdr", unitsPerCall: 120, unit: "frame"),
        Workload(id: "sample-nv12-ring", api: "sample", count: 120,
                 scenario: "equal-ring", unitsPerCall: 120, unit: "frame"),
    ]
}

private enum PixelKind: Equatable {
    case bgra
    case nv12
    case p010HDR

    var pixelFormat: OSType {
        switch self {
        case .bgra: return kCVPixelFormatType_32BGRA
        case .nv12: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .p010HDR: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
    }
}

private func makeBuffer(
    _ kind: PixelKind,
    width: Int = 1_920,
    height: Int = 1_080
) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kind.pixelFormat,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
        throw HarnessError.nativeFailure("CVPixelBufferCreate", status)
    }

    if kind == .p010HDR {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        // The repository's independently specified HDR10 fixture payloads:
        // G(13250,34500), B(7500,3000), R(34000,16000), WP(15635,16450),
        // L(10000000,50), MaxCLL=1000, MaxFALL=400, all big-endian.
        let mastering = Data([
            0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
            0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
            0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
        ])
        let contentLight = Data([0x03, 0xe8, 0x01, 0x90])
        CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                              mastering as CFData, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey,
                              contentLight as CFData, .shouldPropagate)
    } else {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if kind == .nv12 {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
    }
    return buffer
}

private func freshDescription(_ buffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
    var result: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        formatDescriptionOut: &result
    )
    guard status == noErr, let result else {
        throw HarnessError.nativeFailure("Reference format description", status)
    }
    return result
}

// Read native results, rather than hashing fixture inputs, inside timing.
// Identical checksum work is included in baseline and candidate measurements.
private func formatChecksum(_ format: CMVideoFormatDescription) -> UInt64 {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return UInt64(dimensions.width) &* 1_000_003
        &+ UInt64(dimensions.height) &* 257
        &+ UInt64(CMFormatDescriptionGetMediaSubType(format))
}

private func timingChecksum(_ time: CMTime, _ duration: CMTime) -> UInt64 {
    UInt64(bitPattern: time.value) &* 31 &+ UInt64(time.timescale) &* 17
        &+ UInt64(bitPattern: duration.value) &* 13 &+ UInt64(duration.timescale)
}

private func sampleChecksum(_ sample: CMSampleBuffer) throws -> UInt64 {
    guard let format = CMSampleBufferGetFormatDescription(sample) else {
        throw HarnessError.incorrectResult("Sample has no format description")
    }
    return formatChecksum(format) &+ timingChecksum(
        CMSampleBufferGetPresentationTimeStamp(sample),
        CMSampleBufferGetDuration(sample)
    )
}

private struct Frame {
    let buffer: CVPixelBuffer
    let time: CMTime
    let duration: CMTime
    let matrixBefore: CFString?

    func applyMutation() {
        if let matrixBefore {
            // Precreated attachment values; only the actual metadata mutation
            // is timed. This cost is included identically in both variants.
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                  matrixBefore, .shouldPropagate)
        }
    }
}

private struct Fixture {
    let frames: [Frame]
    let expectedTransitionsWithinCall: Int

    init(_ workload: Workload) throws {
        guard workload.count == 120, workload.unitsPerCall == workload.count else {
            throw HarnessError.invalidFixture(workload.id)
        }
        let buffers: [CVPixelBuffer]
        switch workload.scenario {
        case "bgra":
            buffers = [try makeBuffer(.bgra)]
            expectedTransitionsWithinCall = 0
        case "nv12":
            buffers = [try makeBuffer(.nv12)]
            expectedTransitionsWithinCall = 0
        case "p010-hdr":
            buffers = [try makeBuffer(.p010HDR)]
            expectedTransitionsWithinCall = 0
        case "equal-ring":
            buffers = try (0..<3).map { _ in try makeBuffer(.nv12) }
            expectedTransitionsWithinCall = 0
            let identities = buffers.map {
                UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque())
            }
            guard Set(identities).count == 3 else {
                throw HarnessError.invalidFixture("Ring buffers are not distinct")
            }
        case "dimensions-every60":
            buffers = [
                try makeBuffer(.nv12),
                try makeBuffer(.nv12, width: 1_280, height: 720),
            ]
            expectedTransitionsWithinCall = 1
        case "metadata-every-frame":
            buffers = [try makeBuffer(.nv12), try makeBuffer(.nv12)]
            CVBufferSetAttachment(buffers[0], kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            expectedTransitionsWithinCall = workload.count - 1
        case "same-buffer-metadata-every60":
            buffers = [try makeBuffer(.nv12)]
            expectedTransitionsWithinCall = 1
        default:
            throw HarnessError.invalidFixture(workload.id)
        }

        var created: [Frame] = []
        created.reserveCapacity(workload.count)
        for index in 0..<workload.count {
            let bufferIndex: Int
            switch workload.scenario {
            case "equal-ring": bufferIndex = index % buffers.count
            case "dimensions-every60": bufferIndex = index / 60
            case "metadata-every-frame": bufferIndex = index % 2
            default: bufferIndex = 0
            }
            let matrix: CFString?
            if workload.scenario == "same-buffer-metadata-every60",
               index.isMultiple(of: 60) {
                matrix = index == 0
                    ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
                    : kCVImageBufferYCbCrMatrix_ITU_R_709_2
            } else {
                matrix = nil
            }
            created.append(Frame(
                buffer: buffers[bufferIndex],
                time: CMTime(value: Int64(index), timescale: 60),
                duration: CMTime(value: 1, timescale: 60),
                matrixBefore: matrix
            ))
        }
        frames = created
    }

    func validate(
        _ workload: Workload,
        using benchmark: FormatDescriptionBenchmark
    ) throws -> UInt64 {
        var checksum: UInt64 = 0
        var previous: CMVideoFormatDescription?
        var transitions = 0
        for (index, frame) in frames.enumerated() {
            frame.applyMutation()
            // Every preflight frame has an independent native reference,
            // including attachment changes on a reused pixel-buffer object.
            let reference = try freshDescription(frame.buffer)
            if let previous,
               !CMFormatDescriptionEqual(previous, otherFormatDescription: reference) {
                transitions += 1
            }
            previous = reference
            let actual: CMVideoFormatDescription
            if workload.api == "format" {
                actual = try benchmark.formatDescription(for: frame.buffer)
                checksum &+= formatChecksum(reference)
            } else {
                let sample = try benchmark.sampleBuffer(
                    for: frame.buffer, time: frame.time, duration: frame.duration
                )
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let image = CMSampleBufferGetImageBuffer(sample),
                      image === frame.buffer,
                      CMSampleBufferDataIsReady(sample),
                      CMSampleBufferGetNumSamples(sample) == 1 else {
                    throw HarnessError.incorrectResult(
                        "\(workload.id) sample structure at frame \(index)"
                    )
                }
                actual = format
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                guard time.value == frame.time.value,
                      time.timescale == frame.time.timescale,
                      time.epoch == frame.time.epoch,
                      time.flags == frame.time.flags,
                      duration.value == frame.duration.value,
                      duration.timescale == frame.duration.timescale,
                      duration.flags == frame.duration.flags,
                      !CMSampleBufferGetDecodeTimeStamp(sample).isValid else {
                    throw HarnessError.incorrectResult(
                        "\(workload.id) sample timing at frame \(index)"
                    )
                }
                checksum &+= formatChecksum(reference)
                    &+ timingChecksum(frame.time, frame.duration)
            }
            guard CMFormatDescriptionEqual(reference, otherFormatDescription: actual),
                  CMVideoFormatDescriptionMatchesImageBuffer(
                    actual, imageBuffer: frame.buffer
                  ) else {
                throw HarnessError.incorrectResult(
                    "\(workload.id) format equality at frame \(index)"
                )
            }
        }
        // Confirm that the nominal hit/miss patterns are real native format
        // changes, rather than assumptions about the attachment key's effect.
        guard transitions == expectedTransitionsWithinCall else {
            throw HarnessError.invalidFixture(
                "\(workload.id) had \(transitions) native format transitions"
            )
        }
        return checksum
    }
}

@inline(never)
private func perform(
    _ workload: Workload,
    _ fixture: Fixture,
    using benchmark: FormatDescriptionBenchmark
) throws -> UInt64 {
    var checksum: UInt64 = 0
    if workload.api == "format" {
        for frame in fixture.frames {
            frame.applyMutation()
            checksum &+= formatChecksum(try benchmark.formatDescription(for: frame.buffer))
        }
    } else {
        for frame in fixture.frames {
            frame.applyMutation()
            checksum &+= try sampleChecksum(benchmark.sampleBuffer(
                for: frame.buffer, time: frame.time, duration: frame.duration
            ))
        }
    }
    return checksum
}

@inline(never)
private func measure(
    _ workload: Workload,
    _ fixture: Fixture,
    iterations: Int
) throws -> Observation {
    let benchmark = FormatDescriptionBenchmark()
    let expected = try fixture.validate(workload, using: benchmark)
    // A second pass also verifies transitions across sequence boundaries.
    guard try fixture.validate(workload, using: benchmark) == expected else {
        throw HarnessError.incorrectResult("Preflight sequence checksum changed")
    }
    benchmark.reset()
    let warmupCalls = 3
    for _ in 0..<warmupCalls {
        guard try perform(workload, fixture, using: benchmark) == expected else {
            throw HarnessError.incorrectResult("Warmup checksum changed")
        }
    }

    // Retain one adapter across all timed calls, as the presenter does across
    // frames. Resetting each iteration would manufacture extra cache misses.
    var checksum: UInt64 = 0
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
        checksum &+= try perform(workload, fixture, using: benchmark)
    }
    let ended = DispatchTime.now().uptimeNanoseconds
    guard checksum == expected &* UInt64(iterations) else {
        throw HarnessError.incorrectResult("Timed checksum changed")
    }
    let elapsed = Double(ended - started)
    let perCall = elapsed / Double(iterations)
    return Observation(
        workload: workload,
        iterations: iterations,
        warmupCalls: warmupCalls,
        expectedChecksumPerCall: expected,
        checksum: checksum,
        elapsedMilliseconds: elapsed / 1_000_000,
        nanosecondsPerCall: perCall,
        nanosecondsPerUnit: perCall / Double(workload.unitsPerCall)
    )
}

@main
private enum Harness {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output: Data
        if arguments == ["--list"] {
            output = try encoder.encode(workloads())
        } else {
            guard arguments.count == 2,
                  let workload = workloads().first(where: { $0.id == arguments[0] }),
                  let iterations = Int(arguments[1]), iterations > 0 else {
                throw HarnessError.invalidArguments
            }
            output = try encoder.encode(measure(
                workload, try Fixture(workload), iterations: iterations
            ))
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}
