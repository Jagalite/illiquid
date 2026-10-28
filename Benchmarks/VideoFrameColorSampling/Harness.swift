import CoreVideo
import Darwin
import Foundation
import IlliquidCore
@testable import IlliquidNativePlayback

// Compile this driver separately from the optimized, unmodified production
// modules. Fixtures and warm-up are outside the measured sample() calls.
private struct Workload: Sendable {
    let name: String
    let format: OSType
    let width: Int
    let height: Int
    var throttled = false
}

private let formats: [(String, OSType)] = [
    ("bgra", kCVPixelFormatType_32BGRA),
    ("420v", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ("420f", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    ("x420", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
    ("xf20", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
]
private let workloads: [Workload] = formats.flatMap { entry in
    [
        Workload(name: entry.0 + "-1080p", format: entry.1, width: 1920, height: 1080),
        Workload(name: entry.0 + "-4k", format: entry.1, width: 3840, height: 2160),
        Workload(name: entry.0 + "-padded", format: entry.1, width: 26, height: 18),
    ]
} + [
    Workload(name: "unsupported-argb", format: kCVPixelFormatType_32ARGB, width: 26, height: 18),
    Workload(name: "throttled-bgra", format: kCVPixelFormatType_32BGRA,
             width: 1920, height: 1080, throttled: true),
]

private struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}
private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw HarnessFailure(description: message) }
    return value
}
private func setMatrix(_ name: String, on buffer: CVPixelBuffer) {
    let matrix: CFString?
    switch name {
    case "601": matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    case "709": matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case "2020": matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: matrix = nil
    }
    if let matrix {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    } else {
        CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
    }
}

private func makeBuffer(_ workload: Workload, seed: Int) throws -> CVPixelBuffer {
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferBytesPerRowAlignmentKey as String: 128,
    ]
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, workload.width, workload.height,
                                    workload.format, attributes as CFDictionary, &result)
    guard status == kCVReturnSuccess else {
        throw HarnessFailure(description: "CVPixelBufferCreate failed for \(workload.name): \(status)")
    }
    let buffer = try require(result, "Missing pixel buffer")
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw HarnessFailure(description: "Could not lock fixture")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let planar8 = workload.format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        || workload.format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let planar10 = workload.format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        || workload.format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    if planar8 || planar10 {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else {
            throw HarnessFailure(description: "Expected two planes")
        }
        for plane in 0..<2 {
            let base = try require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), "Missing plane")
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0xa5, stride * height)
            for y in 0..<height {
                for x in 0..<width {
                    if planar8 {
                        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                        if plane == 0 {
                            row[x] = UInt8((x * 11 + y * 17 + seed * 29) % 256)
                        } else {
                            row[x * 2] = UInt8((x * 23 + y * 7 + seed * 31 + 53) % 256)
                            row[x * 2 + 1] = UInt8((x * 5 + y * 19 + seed * 43 + 97) % 256)
                        }
                    } else {
                        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                        // Nonzero unused low bits also exercise the >> 6 interpretation.
                        if plane == 0 {
                            row[x] = UInt16(((x * 11 + y * 17 + seed * 29) % 1024) << 6 | (seed & 63))
                        } else {
                            row[x * 2] = UInt16(((x * 23 + y * 7 + seed * 31 + 211) % 1024) << 6 | 17)
                            row[x * 2 + 1] = UInt16(((x * 5 + y * 19 + seed * 43 + 389) % 1024) << 6 | 51)
                        }
                    }
                }
            }
        }
    } else {
        let base = try require(CVPixelBufferGetBaseAddress(buffer), "Missing packed address")
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0xa5, stride * workload.height)
        for y in 0..<workload.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<workload.width {
                row[x * 4] = UInt8((x * 11 + y * 3 + seed * 37) % 256)
                row[x * 4 + 1] = UInt8((x * 7 + y * 17 + seed * 53) % 256)
                row[x * 4 + 2] = UInt8((x * 19 + y * 5 + seed * 71) % 256)
                row[x * 4 + 3] = 255
            }
        }
    }
    setMatrix("709", on: buffer)
    return buffer
}

private func fillSolidBGRA(_ buffer: CVPixelBuffer, value: UInt8) throws {
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw HarnessFailure(description: "Could not lock solid fixture")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try require(CVPixelBufferGetBaseAddress(buffer), "Missing solid fixture address")
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

private func receipt(_ sample: VideoColorSample?) -> Any {
    guard let sample else { return NSNull() }
    return [
        "columns": sample.columns,
        "rows": sample.rows,
        "rgb_bit_patterns": sample.colors.map {
            [String($0.red.bitPattern), String($0.green.bitPattern), String($0.blue.bitPattern)]
        },
    ] as [String: Any]
}

private func verify() throws -> [String: Any] {
    var direct: [[String: Any]] = []
    var stateful: [[String: Any]] = []
    let matrices = ["unspecified", "601", "709", "2020", "unspecified"]
    for workload in workloads where !workload.throttled {
        for seed in 0..<2 {
            let buffer = try makeBuffer(workload, seed: seed)
            let strides = CVPixelBufferIsPlanar(buffer)
                ? (0..<CVPixelBufferGetPlaneCount(buffer)).map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) }
                : [CVPixelBufferGetBytesPerRow(buffer)]
            for (step, matrix) in matrices.enumerated() {
                // Change attachments on the same physical buffer, then remove them.
                setMatrix(matrix, on: buffer)
                let sample = VideoFrameColorSampler.sample(buffer)
                if workload.format == kCVPixelFormatType_32ARGB {
                    guard sample == nil else {
                        throw HarnessFailure(description: "Unsupported format unexpectedly produced a sample")
                    }
                } else {
                    guard let sample, sample.columns == 12, sample.rows == 8,
                          sample.colors.count == 96 else {
                        throw HarnessFailure(description: "Missing or malformed sample for \(workload.name), \(matrix), seed \(seed)")
                    }
                }
                direct.append([
                    "workload": workload.name, "seed": seed, "step": step,
                    "matrix": matrix, "strides": strides,
                    "sample": receipt(sample),
                ])
            }
        }
    }
    for (name, format) in formats {
        let workload = Workload(name: name, format: format, width: 26, height: 18)
        let buffers = try (0..<3).map { try makeBuffer(workload, seed: $0) }
        let sampler = VideoFrameColorSampler()
        let times: [UInt64] = [0, 100_000_000, 250_000_000, 500_000_000,
                               750_000_000, 1_000_000_000, 900_000_000]
        for (step, now) in times.enumerated() {
            let buffer = buffers[step % buffers.count]
            setMatrix(matrices[step % matrices.count], on: buffer)
            stateful.append([
                "workload": name, "step": step, "uptime_ns": String(now),
                "sample": receipt(sampler.sampleIfNeeded(buffer, uptimeNanoseconds: now)),
            ])
        }
        sampler.reset()
        stateful.append([
            "workload": name, "step": "reset", "uptime_ns": "0",
            "sample": receipt(sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 0)),
        ])
    }
    let solidWorkload = Workload(name: "solid-bgra", format: kCVPixelFormatType_32BGRA,
                                 width: 26, height: 18)
    let solids = try [UInt8(0), 1, 51, 255].map { value -> CVPixelBuffer in
        let buffer = try makeBuffer(solidWorkload, seed: 0)
        try fillSolidBGRA(buffer, value: value)
        return buffer
    }
    let sampler = VideoFrameColorSampler()
    for (step, index) in [0, 3, 1, 2, 3, 3].enumerated() {
        let now: UInt64 = step == 1 ? 100_000_000 : UInt64(max(0, step - 1)) * 250_000_000
        stateful.append([
            "workload": "solid-throttle-smooth-scene-cut", "step": step,
            "uptime_ns": String(now),
            "sample": receipt(sampler.sampleIfNeeded(solids[index], uptimeNanoseconds: now)),
        ])
    }
    return ["schema_version": 1, "direct": direct, "stateful": stateful,
            "comparison": "All 96 RGB Double bit patterns, dimensions, and nil results"]
}

private struct BatchResult {
    let checksum: UInt64
    let sampledCount: Int
}

@inline(never)
private func batch(_ buffers: [CVPixelBuffer], sampler: VideoFrameColorSampler?,
                   iterations: Int) -> BatchResult {
    var checksum: UInt64 = 0
    var sampledCount = 0
    for index in 0..<iterations {
        let buffer = buffers[index % buffers.count]
        let sample = if let sampler {
            sampler.sampleIfNeeded(buffer, uptimeNanoseconds: 1_000_000_000)
        } else {
            VideoFrameColorSampler.sample(buffer)
        }
        if let sample {
            sampledCount += 1
            // Full RGB parity is checked outside timing. A varying cell keeps
            // results observable without making full-array hashing the workload.
            let color = sample.colors[(index &* 17) % sample.colors.count]
            checksum &+= color.red.bitPattern
            checksum = (checksum ^ color.green.bitPattern) &* 0x9e37_79b9_7f4a_7c15
            checksum ^= color.blue.bitPattern
        } else {
            checksum &+= 0xd1b5_4a32_d192_ed03
        }
    }
    return BatchResult(checksum: checksum, sampledCount: sampledCount)
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
        throw HarnessFailure(description: "clock_gettime failed")
    }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func benchmark(_ workload: Workload, iterations: Int) throws -> [String: Any] {
    // Two buffers bound retained 4K fixture memory and vary the sampled input.
    let buffers = try (0..<2).map { try makeBuffer(workload, seed: $0) }
    let sampler = workload.throttled ? VideoFrameColorSampler() : nil
    if let sampler {
        guard sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 1_000_000_000) != nil else {
            throw HarnessFailure(description: "Throttle control failed to prime a real sample")
        }
    }
    let warmupIterations = min(iterations, 512)
    let warmup = batch(buffers, sampler: sampler, iterations: warmupIterations)
    let cpuStart = try cpuNanoseconds()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let result = batch(buffers, sampler: sampler, iterations: iterations)
    let elapsed = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = try cpuNanoseconds() - cpuStart
    return [
        "schema_version": 1, "workload": workload.name, "iterations": iterations,
        "operations": iterations, "elapsed_ns": elapsed, "cpu_ns": cpu,
        "checksum": String(result.checksum), "sampled_count": result.sampledCount,
        "warmup_iterations": warmupIterations, "warmup_checksum": String(warmup.checksum),
        "warmup_sampled_count": warmup.sampledCount,
    ]
}

@main
private struct VideoFrameColorSamplingHarness {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let result: Any
            if arguments == ["list"] {
                result = workloads.map(\.name)
            } else if arguments == ["verify"] {
                result = try verify()
            } else if arguments.count == 3, arguments[0] == "bench",
                      let workload = workloads.first(where: { $0.name == arguments[1] }),
                      let iterations = Int(arguments[2]), iterations > 0,
                      iterations <= 100_000_000 {
                result = try benchmark(workload, iterations: iterations)
            } else {
                throw HarnessFailure(description: "Expected list, verify, or bench <workload> <iterations>")
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }
    }
}
