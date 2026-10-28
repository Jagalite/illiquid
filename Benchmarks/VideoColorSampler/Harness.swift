import CoreVideo
import Darwin
import Foundation
import IlliquidCore
@testable import IlliquidNativePlayback

private enum Failure: Error {
    case message(String)
}

private enum Format: String, CaseIterable {
    case bgra, nv12Video, nv12Full, p010Video, p010Full, unsupported

    var code: OSType {
        switch self {
        case .bgra: kCVPixelFormatType_32BGRA
        case .nv12Video: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12Full: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .p010Video: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p010Full: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .unsupported: kCVPixelFormatType_OneComponent8
        }
    }

    var isTenBit: Bool { self == .p010Video || self == .p010Full }
}

private struct Fixture {
    let format: Format
    let width: Int
    let height: Int
    var seed = 1
    var matrix = "709"

    var name: String { "\(format.rawValue)-\(width)x\(height)-\(seed)-\(matrix)" }
}

private func makeBuffer(_ fixture: Fixture) throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferBytesPerRowAlignmentKey as String: 128,
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, fixture.width, fixture.height,
                                    fixture.format.code, attributes as CFDictionary, &value)
    guard status == kCVReturnSuccess, let buffer = value else {
        throw Failure.message("CVPixelBufferCreate \(fixture.name): \(status)")
    }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw Failure.message("Cannot lock fixture \(fixture.name)")
    }
    do {
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let seed = fixture.seed
        if fixture.format == .bgra || fixture.format == .unsupported {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw Failure.message("Missing packed fixture address")
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, 0xA5, stride * fixture.height)
            if fixture.format == .bgra {
                for y in 0..<fixture.height {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<fixture.width {
                        row[x * 4] = UInt8((x * 19 + y * 5 + seed * 11) & 255)
                        row[x * 4 + 1] = UInt8((x * 3 + y * 7 + seed * 31) & 255)
                        row[x * 4 + 2] = UInt8((x * 13 + y * 17 + seed * 29) & 255)
                        row[x * 4 + 3] = 255
                    }
                }
            }
        } else {
            guard CVPixelBufferGetPlaneCount(buffer) == 2 else {
                throw Failure.message("Expected two fixture planes")
            }
            for plane in 0..<2 {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                    throw Failure.message("Missing fixture plane")
                }
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, 0xA5, stride * height)
                let mask = fixture.format.isTenBit ? 1023 : 255
                for y in 0..<height {
                    for x in 0..<width {
                        let first = plane == 0
                            ? (x * 17 + y * 13 + seed * 7) & mask
                            : (x * 11 + y * 23 + seed * 31) & mask
                        let second = (x * 29 + y * 7 + seed * 19) & mask
                        let index = plane == 0 ? x : x * 2
                        if fixture.format.isTenBit {
                            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                            // Low bits deliberately differ; P010 reads the high ten bits.
                            row[index] = UInt16((first << 6) | ((x + y + seed) & 63))
                            if plane == 1 {
                                row[index + 1] = UInt16((second << 6) | ((x + y + seed + 17) & 63))
                            }
                        } else {
                            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                            row[index] = UInt8(first)
                            if plane == 1 { row[index + 1] = UInt8(second) }
                        }
                    }
                }
            }
        }
    }
    setMatrix(fixture.matrix, on: buffer)
    return buffer
}

private func setMatrix(_ name: String, on buffer: CVPixelBuffer) {
    let value: CFString
    switch name {
    case "none":
        CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
        return
    case "601": value = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    case "709": value = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case "2020": value = kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: value = "Unknown benchmark matrix" as CFString
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, value, .shouldPropagate)
}

private struct Layout: Encodable {
    let name: String
    let format: UInt32
    let width: Int
    let height: Int
    let planeWidths: [Int]
    let planeHeights: [Int]
    let bytesPerRow: [Int]

    init(_ fixture: Fixture, _ buffer: CVPixelBuffer) {
        name = fixture.name
        format = CVPixelBufferGetPixelFormatType(buffer)
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        let count = CVPixelBufferGetPlaneCount(buffer)
        planeWidths = count == 0 ? [width] : (0..<count).map { CVPixelBufferGetWidthOfPlane(buffer, $0) }
        planeHeights = count == 0 ? [height] : (0..<count).map { CVPixelBufferGetHeightOfPlane(buffer, $0) }
        bytesPerRow = count == 0 ? [CVPixelBufferGetBytesPerRow(buffer)]
            : (0..<count).map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) }
    }
}

private struct Trace: Encodable {
    let name: String
    let columns: Int?
    let rows: Int?
    let components: [String]?

    init(_ name: String, _ sample: VideoColorSample?) {
        self.name = name
        columns = sample?.columns
        rows = sample?.rows
        components = sample.map { value in
            (value.colors + [value.overall, value.leading, value.bottom]).flatMap {
                [$0.red.bitPattern, $0.green.bitPattern, $0.blue.bitPattern].map { String($0, radix: 16) }
            }
        }
    }
}

private struct Verification: Encodable {
    let layouts: [Layout]
    let traces: [Trace]
}

private func verify() throws -> Verification {
    var traces: [Trace] = []
    var layouts: [Layout] = []
    let formats = Format.allCases.filter { $0 != .unsupported }
    for format in formats {
        for (width, height) in [(2, 2), (26, 18), (128, 72), (1920, 1080)] {
            for seed in [1, 7] {
                try autoreleasepool {
                    let fixture = Fixture(format: format, width: width, height: height, seed: seed)
                    let buffer = try makeBuffer(fixture)
                    layouts.append(Layout(fixture, buffer))
                    let matrices = format == .bgra ? ["none"] : ["none", "601", "709", "2020", "unknown"]
                    // Reuse one buffer while its attachment changes: there is no cross-call cache.
                    for matrix in matrices {
                        setMatrix(matrix, on: buffer)
                        traces.append(Trace("\(fixture.name)-attachment-\(matrix)",
                                            VideoFrameColorSampler.sample(buffer)))
                    }
                }
            }
        }
    }
    for fixture in [
        Fixture(format: .bgra, width: 1, height: 1),
        Fixture(format: .bgra, width: 3, height: 2),
        Fixture(format: .bgra, width: 19, height: 13),
        Fixture(format: .p010Full, width: 3840, height: 2160),
        Fixture(format: .unsupported, width: 26, height: 18),
    ] {
        try autoreleasepool {
            let buffer = try makeBuffer(fixture)
            layouts.append(Layout(fixture, buffer))
            traces.append(Trace(fixture.name, VideoFrameColorSampler.sample(buffer)))
        }
    }

    let fixtures = formats.enumerated().map {
        Fixture(format: $0.element, width: 26 + $0.offset * 8, height: 18 + $0.offset * 4,
                seed: $0.offset + 2, matrix: $0.offset % 2 == 0 ? "601" : "2020")
    }
    let buffers = try fixtures.map(makeBuffer)
    let sampler = VideoFrameColorSampler()
    let times: [UInt64] = [0, 1, 249_999_999, 250_000_000, 500_000_000, 750_000_000,
                           1_000_000_000, 999_999_999, 1_250_000_000, 4_000_000_000]
    for (index, time) in times.enumerated() {
        let buffer = buffers[index % buffers.count]
        traces.append(Trace("stateful-\(index)-\(time)",
                            sampler.sampleIfNeeded(buffer, uptimeNanoseconds: time)))
    }
    sampler.reset()
    traces.append(Trace("stateful-reset", sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 0)))
    return Verification(layouts: layouts, traces: traces)
}

private enum Mode { case sample, cadence, throttled }

private func workload(_ name: String) throws -> (Mode, [Fixture]) {
    switch name {
    case "bgra_tiny": return (.sample, [Fixture(format: .bgra, width: 3, height: 2)])
    case "bgra_1080p": return (.sample, [Fixture(format: .bgra, width: 1920, height: 1080)])
    case "nv12_video_1080p": return (.sample, [Fixture(format: .nv12Video, width: 1920, height: 1080)])
    case "nv12_full_1080p": return (.sample, [Fixture(format: .nv12Full, width: 1920, height: 1080)])
    case "p010_video_2160p": return (.sample, [Fixture(format: .p010Video, width: 3840, height: 2160)])
    case "p010_full_2160p": return (.sample, [Fixture(format: .p010Full, width: 3840, height: 2160)])
    case "mixed_padded", "cadence_60fps", "throttled":
        let fixtures = Format.allCases.filter { $0 != .unsupported }.enumerated().map {
            Fixture(format: $0.element, width: 26 + $0.offset * 8, height: 18 + $0.offset * 4,
                    seed: $0.offset + 1, matrix: $0.offset % 2 == 0 ? "601" : "2020")
        }
        return (name == "mixed_padded" ? .sample : name == "cadence_60fps" ? .cadence : .throttled, fixtures)
    default: throw Failure.message("Unknown workload \(name)")
    }
}

private func cpuNanoseconds() -> UInt64 {
    var time = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
    return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

private struct LoopResult: Encodable {
    let elapsedNanoseconds: UInt64
    let cpuNanoseconds: UInt64
    let checksum: String
    let published: Int
}

@inline(never)
private func run(_ mode: Mode, buffers: [CVPixelBuffer], iterations: Int) -> LoopResult {
    let sampler = VideoFrameColorSampler()
    if mode == .throttled {
        _ = sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 1_000_000_000)
    }
    var checksum: UInt64 = 14695981039346656037
    var published = 0
    let cpuStart = cpuNanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    for iteration in 0..<iterations {
        autoreleasepool {
            let sample: VideoColorSample?
            switch mode {
            case .sample:
                sample = VideoFrameColorSampler.sample(buffers[iteration % buffers.count])
            case .cadence:
                sample = sampler.sampleIfNeeded(
                    buffers[(iteration / 15) % buffers.count],
                    uptimeNanoseconds: 1_000_000_000 + UInt64(iteration) * 16_666_667
                )
            case .throttled:
                sample = sampler.sampleIfNeeded(buffers[iteration % buffers.count],
                                                uptimeNanoseconds: 1_000_000_001)
            }
            if let sample {
                // Rotating coordinates consume actual results with little measurement overhead.
                let color = sample.colors[iteration % sample.colors.count]
                checksum = (checksum &* 1099511628211) ^ color.red.bitPattern
                checksum = (checksum &* 1099511628211) ^ color.green.bitPattern
                checksum = (checksum &* 1099511628211) ^ color.blue.bitPattern
                published += 1
            } else {
                checksum = (checksum &* 1099511628211) ^ 0x9E3779B97F4A7C15
            }
        }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpu = cpuNanoseconds() - cpuStart
    return LoopResult(elapsedNanoseconds: elapsed, cpuNanoseconds: cpu,
                      checksum: String(checksum, radix: 16), published: published)
}

private struct Measurement: Encodable {
    let workload: String
    let iterations: Int
    let layouts: [Layout]
    let warmup: LoopResult
    let measured: LoopResult
}

@main
private struct Main {
    static func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["verify"] {
            try emit(verify())
        } else if arguments.count == 3, arguments[0] == "measure",
                  let iterations = Int(arguments[2]), iterations > 0 {
            let (mode, fixtures) = try workload(arguments[1])
            let buffers = try fixtures.map(makeBuffer)
            let layouts = zip(fixtures, buffers).map { Layout($0.0, $0.1) }
            let warmup = run(mode, buffers: buffers, iterations: 1024)
            let measured = run(mode, buffers: buffers, iterations: iterations)
            try emit(Measurement(workload: arguments[1], iterations: iterations,
                                 layouts: layouts, warmup: warmup, measured: measured))
        } else {
            throw Failure.message("Usage: ColorSamplerBenchmark verify | measure CASE ITERATIONS")
        }
    }
}
