import CoreVideo
import Foundation
import IlliquidCore
@testable import IlliquidNativePlayback

// Real IOSurface-backed buffers; preparation is outside every timed region.
// The runner compiles unchanged production sources into separate optimized
// modules, compares complete output receipts, then performs paired timings.
private enum Format: String, CaseIterable {
    case bgra, nv12Video, nv12Full, p010Video, p010Full, argb

    var pixelFormat: OSType {
        switch self {
        case .bgra: kCVPixelFormatType_32BGRA
        case .nv12Video: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12Full: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .p010Video: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p010Full: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .argb: kCVPixelFormatType_32ARGB
        }
    }

    var isPlanar: Bool {
        self != .bgra && self != .argb
    }

    var isTenBit: Bool {
        self == .p010Video || self == .p010Full
    }
}

private enum Matrix: String, CaseIterable {
    case absent, rec601, rec709, rec2020, unknown

    var attachment: CFString? {
        switch self {
        case .absent: nil
        case .rec601: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case .rec709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .rec2020: kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .unknown: "benchmark-unknown-matrix" as CFString
        }
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw HarnessError(description: message) }
}

private func makeBuffer(
    format: Format,
    width: Int,
    height: Int,
    matrix: Matrix,
    seed: Int
) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferBytesPerRowAlignmentKey as String: 256,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, format.pixelFormat,
        attributes as CFDictionary, &result
    )
    guard status == kCVReturnSuccess, let buffer = result else {
        throw HarnessError(description: "CVPixelBufferCreate failed for \(format.rawValue): \(status)")
    }
    try require(CVPixelBufferGetIOSurface(buffer) != nil, "Fixture is not IOSurface-backed")
    if let attachment = matrix.attachment {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, attachment, .shouldPropagate)
    }
    try require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, "Fixture lock failed")
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    if !format.isPlanar {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw HarnessError(description: "Missing packed address")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0xA5, stride * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4] = UInt8((x * 17 + y * 29 + seed * 37) & 255)
                row[x * 4 + 1] = UInt8((x * 31 + y * 11 + seed * 53) & 255)
                row[x * 4 + 2] = UInt8((x * 7 + y * 43 + seed * 19) & 255)
                row[x * 4 + 3] = UInt8((x + y + seed * 13) & 255)
            }
        }
    } else {
        try require(CVPixelBufferGetPlaneCount(buffer) == 2, "Expected two planes")
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw HarnessError(description: "Missing plane address")
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0xA5, stride * planeHeight)
            let components = plane == 0 ? 1 : 2
            for y in 0..<planeHeight {
                if format.isTenBit {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<(planeWidth * components) {
                        let value = (x * 37 + y * 53 + seed * 79 + plane * 211) & 1023
                        // Exercise the ignored low six bits as well as 10-bit extrema.
                        let lowBits = (x * 3 + y * 5 + seed * 7) & 63
                        row[x] = UInt16((value << 6) | lowBits)
                    }
                } else {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<(planeWidth * components) {
                        row[x] = UInt8((x * 37 + y * 53 + seed * 79 + plane * 101) & 255)
                    }
                }
            }
        }
    }
    return buffer
}

private struct Snapshot: Encodable {
    let columns: Int
    let rows: Int
    let componentBits: [[String]]

    init(_ sample: VideoColorSample) {
        columns = sample.columns
        rows = sample.rows
        componentBits = sample.colors.map {
            [String($0.red.bitPattern, radix: 16),
             String($0.green.bitPattern, radix: 16),
             String($0.blue.bitPattern, radix: 16)]
        }
    }
}

private struct FixtureReceipt: Encodable {
    let name: String
    let width: Int
    let height: Int
    let pixelFormat: UInt32
    let planeCount: Int
    let bytesPerRow: [Int]
    let matrix: String
    let seed: Int
    let sample: Snapshot?
}

private struct SequenceReceipt: Encodable {
    let name: String
    let uptime: UInt64
    let sample: Snapshot?
}

private struct VerificationReceipt: Encodable {
    let cases: [String]
    let fixtures: [FixtureReceipt]
    let sequence: [SequenceReceipt]
}

private let cases = [
    "bgra-1080p", "nv12-video-1080p", "nv12-full-1080p",
    "p010-video-1080p", "p010-full-1080p", "bgra-small",
    "unsupported-argb", "due-nv12-video-1080p", "throttled",
]

private func verify() throws -> VerificationReceipt {
    var fixtures: [FixtureReceipt] = []
    for format in Format.allCases {
        var sizes = [(2, 2), (26, 18), (1920, 1080)]
        if !format.isPlanar { sizes += [(1, 1), (13, 9), (27, 19)] }
        for (width, height) in sizes {
            for matrix in Matrix.allCases {
                for seed in [0, 1, 17] {
                    let buffer = try makeBuffer(
                        format: format, width: width, height: height, matrix: matrix, seed: seed
                    )
                    let sample = VideoFrameColorSampler.sample(buffer)
                    try require((sample != nil) == (format != .argb), "Unexpected format admission")
                    if let sample {
                        try require(sample.columns == 12 && sample.rows == 8 && sample.colors.count == 96,
                                    "Unexpected sampling grid")
                    }
                    let planes = CVPixelBufferGetPlaneCount(buffer)
                    let strides = planes == 0
                        ? [CVPixelBufferGetBytesPerRow(buffer)]
                        : (0..<planes).map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) }
                    fixtures.append(FixtureReceipt(
                        name: "\(format.rawValue)-\(width)x\(height)-\(matrix.rawValue)-\(seed)",
                        width: width, height: height, pixelFormat: format.pixelFormat,
                        planeCount: planes, bytesPerRow: strides, matrix: matrix.rawValue,
                        seed: seed, sample: sample.map(Snapshot.init)
                    ))
                }
            }
        }
    }

    // Keep one sampler alive while format, allocation, pitch and matrix change.
    // Include throttled, backward-time, reset, unsupported and unchanged frames.
    let buffers = try Format.allCases.enumerated().map { offset, format in
        try makeBuffer(format: format, width: 26, height: 18,
                       matrix: Matrix.allCases[offset % Matrix.allCases.count], seed: offset)
    }
    let sampler = VideoFrameColorSampler()
    var sequence: [SequenceReceipt] = []
    for index in 0..<48 {
        let timestamp = UInt64(1_000_000_000 + index * 250_000_000)
        let sample = sampler.sampleIfNeeded(buffers[index % buffers.count],
                                            uptimeNanoseconds: timestamp)
        sequence.append(SequenceReceipt(
            name: "alternating-\(index)", uptime: timestamp, sample: sample.map(Snapshot.init)
        ))
        let throttled = sampler.sampleIfNeeded(buffers[(index + 1) % buffers.count],
                                               uptimeNanoseconds: timestamp + 1)
        try require(throttled == nil, "Throttled call unexpectedly published")
        sequence.append(SequenceReceipt(
            name: "throttled-\(index)", uptime: timestamp + 1, sample: throttled.map(Snapshot.init)
        ))
    }
    let backwards = sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 10)
    sequence.append(SequenceReceipt(name: "backwards-time", uptime: 10,
                                    sample: backwards.map(Snapshot.init)))
    sampler.reset()
    let reset = sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 10)
    try require(reset != nil, "First sample after reset must publish")
    sequence.append(SequenceReceipt(name: "reset", uptime: 10, sample: reset.map(Snapshot.init)))
    let unchanged = sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 250_000_010)
    try require(unchanged == nil, "Unchanged frame unexpectedly published")
    sequence.append(SequenceReceipt(name: "unchanged", uptime: 250_000_010,
                                    sample: unchanged.map(Snapshot.init)))
    return VerificationReceipt(cases: cases, fixtures: fixtures, sequence: sequence)
}

private enum Mode {
    case raw, due, throttled
}

private struct Workload {
    let format: Format
    let width: Int
    let height: Int
    let mode: Mode

    init(_ name: String) throws {
        width = name == "bgra-small" ? 26 : 1920
        height = name == "bgra-small" ? 18 : 1080
        mode = name == "throttled" ? .throttled
            : name == "due-nv12-video-1080p" ? .due : .raw
        switch name {
        case "bgra-1080p", "bgra-small": format = .bgra
        case "nv12-video-1080p", "due-nv12-video-1080p", "throttled": format = .nv12Video
        case "nv12-full-1080p": format = .nv12Full
        case "p010-video-1080p": format = .p010Video
        case "p010-full-1080p": format = .p010Full
        case "unsupported-argb": format = .argb
        default: throw HarnessError(description: "Unknown case: \(name)")
        }
    }
}

private struct Measurement: Encodable {
    let caseName: String
    let iterations: Int
    let operations: Int
    let elapsedNanoseconds: UInt64
    let checksum: String
    let publishedSamples: Int

    private enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case iterations, operations, checksum
        case elapsedNanoseconds = "elapsed_ns"
        case publishedSamples = "published_samples"
    }
}

@inline(never)
private func perform(
    buffers: [CVPixelBuffer], sampler: VideoFrameColorSampler, mode: Mode, iterations: Int
) -> (checksum: UInt64, published: Int) {
    var checksum: UInt64 = 0xCBF29CE484222325
    var published = 0
    for index in 0..<iterations {
        let buffer = buffers[index & 3]
        let sample: VideoColorSample?
        switch mode {
        case .raw:
            sample = VideoFrameColorSampler.sample(buffer)
        case .due:
            sample = sampler.sampleIfNeeded(
                buffer, uptimeNanoseconds: 1_000_000_000 + UInt64(index) * 250_000_000
            )
        case .throttled:
            sample = sampler.sampleIfNeeded(buffer, uptimeNanoseconds: 1_000_000_000)
        }
        if let sample {
            published += 1
            // Rotate through the entire grid and consume all three components.
            // The separate production module and changing input prevent hoisting.
            let color = sample.colors[index % sample.colors.count]
            checksum = (checksum ^ color.red.bitPattern) &* 0x100000001B3
            checksum = (checksum ^ color.green.bitPattern) &* 0x100000001B3
            checksum = (checksum ^ color.blue.bitPattern) &* 0x100000001B3
        } else {
            checksum = (checksum ^ UInt64(index)) &* 0x100000001B3
        }
    }
    return (checksum, published)
}

private func measure(name: String, iterations: Int) throws -> Measurement {
    try require(iterations > 0, "Iterations must be positive")
    let workload = try Workload(name)
    let buffers = try (0..<4).map {
        try makeBuffer(format: workload.format, width: workload.width, height: workload.height,
                       matrix: .rec709, seed: $0)
    }
    let warmupSampler = VideoFrameColorSampler()
    if workload.mode == .throttled {
        _ = warmupSampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 1_000_000_000)
    }
    _ = perform(buffers: buffers, sampler: warmupSampler, mode: workload.mode, iterations: 512)
    let sampler = VideoFrameColorSampler()
    if workload.mode == .throttled {
        _ = sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 1_000_000_000)
    }
    let start = DispatchTime.now().uptimeNanoseconds
    let result = perform(buffers: buffers, sampler: sampler, mode: workload.mode, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    if workload.mode == .raw {
        try require(result.published == (workload.format == .argb ? 0 : iterations),
                    "Unexpected sample count in measured workload")
    } else if workload.mode == .throttled {
        try require(result.published == 0, "Throttled workload published")
    }
    return Measurement(
        caseName: name, iterations: iterations, operations: iterations,
        elapsedNanoseconds: elapsed, checksum: String(result.checksum, radix: 16),
        publishedSamples: result.published
    )
}

private func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

@main
struct VideoColorSamplingBenchmark {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["verify"] {
                try emit(verify())
            } else if arguments.count == 3, arguments[0] == "measure",
                      let iterations = Int(arguments[2]) {
                try emit(measure(name: arguments[1], iterations: iterations))
            } else {
                throw HarnessError(description: "Usage: Harness verify | measure CASE ITERATIONS")
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
