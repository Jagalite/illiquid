import CoreVideo
import Foundation
import IlliquidCore
import IOSurface

// Compiled beside the exact production sampler and PiPVideoMapping sources.
// Fixture creation and fills are outside the measured interval. Each measured
// process owns one reusable IOSurface-backed buffer; sampling includes the real
// CoreVideo lock/unlock, conversion, result allocation, and checksum consumption.
private enum PixelFormat: String, CaseIterable, Sendable {
    case bgra
    case yuv8Video = "yuv8-video"
    case yuv8Full = "yuv8-full"
    case yuv10Video = "yuv10-video"
    case yuv10Full = "yuv10-full"

    var code: OSType {
        switch self {
        case .bgra: kCVPixelFormatType_32BGRA
        case .yuv8Video: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .yuv8Full: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .yuv10Video: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .yuv10Full: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }

    var isTenBit: Bool { self == .yuv10Video || self == .yuv10Full }
}

private struct SamplingCase: Sendable {
    let format: PixelFormat
    let width: Int
    let height: Int
    var id: String { "\(format.rawValue)-\(width)x\(height)" }
}

private enum HarnessError: Error {
    case invalidArguments
    case failure(String)
}

@main
private struct VideoColorSamplingBenchmark {
    private static let hashOffset: UInt64 = 0xcbf29ce484222325
    private static let hashPrime: UInt64 = 0x100000001b3

    private static var cases: [SamplingCase] {
        PixelFormat.allCases.flatMap { format in
            [(48, 32), (1920, 1080), (3840, 2160)].map { width, height in
                SamplingCase(format: format, width: width, height: height)
            }
        }
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list"] {
            try emit(["cases": cases.map(\.id)])
            return
        }
        if arguments == ["--verify"] {
            try emit(verify())
            return
        }
        guard arguments.count == 5,
              arguments[0] == "--benchmark",
              arguments[1] == "--case",
              arguments[3] == "--iterations",
              let selected = cases.first(where: { $0.id == arguments[2] }),
              let iterations = Int(arguments[4]),
              iterations > 0,
              iterations <= 10_000_000
        else { throw HarnessError.invalidArguments }
        try emit(benchmark(selected, iterations: iterations))
    }

    private static func emit(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func hexadecimal(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    private static func makeBuffer(_ selected: SamplingCase) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
            selected.width, selected.height, selected.format.code,
            attributes as CFDictionary, &result)
        guard status == kCVReturnSuccess, let buffer = result else {
            throw HarnessError.failure("CVPixelBufferCreate \(selected.id): \(status)")
        }
        guard CVPixelBufferGetIOSurface(buffer) != nil else {
            throw HarnessError.failure("Missing IOSurface for \(selected.id)")
        }
        try fillPattern(buffer, format: selected.format)
        return buffer
    }

    private static func fillPattern(_ buffer: CVPixelBuffer, format: PixelFormat) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw HarnessError.failure("Could not lock fixture")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if format == .bgra {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw HarnessError.failure("Missing BGRA storage")
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            memset(base, 0xa5, stride * height)
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4] = UInt8(truncatingIfNeeded: x * 13 + y * 17 + 37)
                    row[x * 4 + 1] = UInt8(truncatingIfNeeded: x * 7 + y * 29 + 73)
                    row[x * 4 + 2] = UInt8(truncatingIfNeeded: x * 23 + y * 3 + 11)
                    row[x * 4 + 3] = 255
                }
            }
            return
        }
        guard CVPixelBufferGetPlaneCount(buffer) == 2 else {
            throw HarnessError.failure("Expected two fixture planes")
        }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw HarnessError.failure("Missing plane \(plane)")
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0xa5, stride * height)
            for y in 0..<height {
                if format.isTenBit {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<width {
                        // Nonzero unused low bits also exercise the production
                        // right shift rather than pre-normalized UInt16 input.
                        let unused = UInt16((x + y + 1) & 63)
                        if plane == 0 {
                            row[x] = (UInt16((x * 11 + y * 19 + 29) & 1023) << 6) | unused
                        } else {
                            row[x * 2] = (UInt16((x * 7 + y * 13 + 401) & 1023) << 6) | unused
                            row[x * 2 + 1] = (UInt16((x * 17 + y * 3 + 597) & 1023) << 6) | unused
                        }
                    }
                } else {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        if plane == 0 {
                            row[x] = UInt8(truncatingIfNeeded: x * 11 + y * 19 + 29)
                        } else {
                            row[x * 2] = UInt8(truncatingIfNeeded: x * 7 + y * 13 + 101)
                            row[x * 2 + 1] = UInt8(truncatingIfNeeded: x * 17 + y * 3 + 149)
                        }
                    }
                }
            }
        }
    }

    private static func fillGray(_ buffer: CVPixelBuffer, value: UInt8) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw HarnessError.failure("Could not lock temporal fixture")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw HarnessError.failure("Missing temporal fixture storage")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }
    }

    private static func layout(_ buffer: CVPixelBuffer) -> [String: Any] {
        let count = CVPixelBufferGetPlaneCount(buffer)
        let strides = count == 0
            ? [CVPixelBufferGetBytesPerRow(buffer)]
            : (0..<count).map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) }
        return ["plane_count": count, "bytes_per_row": strides,
                "data_size": CVPixelBufferGetDataSize(buffer)]
    }

    private static func sampleRecord(_ sample: VideoColorSample?) -> Any {
        guard let sample else { return NSNull() }
        return [
            "columns": sample.columns,
            "rows": sample.rows,
            "colors": sample.colors.map { color in
                [hexadecimal(color.red.bitPattern),
                 hexadecimal(color.green.bitPattern),
                 hexadecimal(color.blue.bitPattern)]
            },
        ] as [String: Any]
    }

    private static func verifyCase(_ selected: SamplingCase) throws -> [[String: Any]] {
        let buffer = try makeBuffer(selected)
        let matrices: [(String, CFString?)] = [
            ("absent", nil),
            ("601", kCVImageBufferYCbCrMatrix_ITU_R_601_4),
            ("709", kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            ("2020", kCVImageBufferYCbCrMatrix_ITU_R_2020),
            ("unknown", "IlliquidBenchmarkUnknownMatrix" as CFString),
            ("absent-after-overrides", nil),
        ]
        var records: [[String: Any]] = []
        for (name, matrix) in matrices {
            if let matrix {
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
            }
            guard let sample = VideoFrameColorSampler.sample(buffer),
                  sample.columns == 12, sample.rows == 8, sample.colors.count == 96
            else { throw HarnessError.failure("Invalid sample for \(selected.id)/\(name)") }
            records.append([
                "case": selected.id,
                "matrix": name,
                "layout": layout(buffer),
                "sample": sampleRecord(sample),
            ])
        }
        return records
    }

    private static func verifyTemporalSequence() throws -> [[String: Any]] {
        let buffer = try makeBuffer(SamplingCase(format: .bgra, width: 48, height: 32))
        let sampler = VideoFrameColorSampler()
        var records: [[String: Any]] = []
        func record(_ label: String, value: UInt8, at now: UInt64) throws {
            try fillGray(buffer, value: value)
            records.append([
                "event": label,
                "uptime_ns": String(now),
                "sample": sampleRecord(sampler.sampleIfNeeded(buffer, uptimeNanoseconds: now)),
            ])
        }
        try record("initial-black", value: 0, at: 1_000_000_000)
        try record("throttled-white", value: 255, at: 1_249_999_999)
        try record("tiny-change", value: 1, at: 1_250_000_000)
        try record("smooth-gray", value: 51, at: 1_500_000_000)
        try record("scene-cut-white", value: 255, at: 1_750_000_000)
        try record("unchanged-white", value: 255, at: 2_000_000_000)
        try record("throttled-black", value: 0, at: 2_249_999_999)
        try record("scene-cut-black", value: 0, at: 2_250_000_000)
        try record("clock-regression", value: 51, at: 100_000_000)
        sampler.reset()
        try record("reset-publishes-again", value: 51, at: 100_000_000)
        return records
    }

    private static func verify() throws -> [String: Any] {
        var samples: [[String: Any]] = []
        for selected in cases {
            samples.append(contentsOf: try autoreleasepool { try verifyCase(selected) })
        }
        return [
            "samples": samples,
            "temporal": try verifyTemporalSequence(),
            "sample_grid": [12, 8],
            "component_encoding": "Double.bitPattern as 16-digit hexadecimal",
        ]
    }

    @inline(__always)
    private static func consume(_ sample: VideoColorSample, into checksum: inout UInt64) {
        // FNV-style word mixing: every RGB component's exact IEEE-754 bits
        // influence the observable result, without decimal formatting in timing.
        for color in sample.colors {
            checksum = (checksum ^ color.red.bitPattern) &* hashPrime
            checksum = (checksum ^ color.green.bitPattern) &* hashPrime
            checksum = (checksum ^ color.blue.bitPattern) &* hashPrime
        }
    }

    @inline(never)
    private static func measure(_ buffer: CVPixelBuffer, iterations: Int) throws -> (UInt64, UInt64) {
        var checksum = hashOffset
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            guard let sample = VideoFrameColorSampler.sample(buffer) else {
                throw HarnessError.failure("Sampling failed during measurement")
            }
            consume(sample, into: &checksum)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return (elapsed, checksum)
    }

    private static func benchmark(_ selected: SamplingCase, iterations: Int) throws -> [String: Any] {
        let buffer = try makeBuffer(selected)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var warmupChecksum = hashOffset
        for _ in 0..<64 {
            guard let sample = VideoFrameColorSampler.sample(buffer) else {
                throw HarnessError.failure("Sampling failed during warmup")
            }
            consume(sample, into: &warmupChecksum)
        }
        let (elapsed, checksum) = try measure(buffer, iterations: iterations)
        return [
            "case": selected.id,
            "format": selected.format.rawValue,
            "width": selected.width,
            "height": selected.height,
            "iterations": iterations,
            "elapsed_ns": elapsed,
            "checksum": hexadecimal(checksum),
            "warmup_checksum": hexadecimal(warmupChecksum),
            "layout": layout(buffer),
        ]
    }
}
