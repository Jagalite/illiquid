import CoreVideo
import Darwin
import Foundation
import IlliquidCore
@testable import IlliquidNativePlayback

private let formats: [(String, OSType)] = [
    ("bgra", kCVPixelFormatType_32BGRA),
    ("nv12-video", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ("nv12-full", kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    ("p010-video", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
    ("p010-full", kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
]

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func makeBuffer(_ format: OSType, width: Int, height: Int,
                        alignment: Int, seed: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
        [kCVPixelBufferBytesPerRowAlignmentKey: alignment] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let buffer = result else {
        throw Failure("CVPixelBufferCreate failed: \(status), format=\(format), \(width)x\(height)")
    }
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw Failure("Fixture lock failed")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let planes = CVPixelBufferGetPlaneCount(buffer)
    if planes == 0 {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure("Missing packed base") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0xA5, stride * height)
        if format == kCVPixelFormatType_32BGRA {
            for y in 0..<height {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[4 * x] = UInt8((7 * x + 11 * y + 19 * seed) % 256)
                    row[4 * x + 1] = UInt8((13 * x + 5 * y + 43 * seed) % 256)
                    row[4 * x + 2] = UInt8((3 * x + 17 * y + 71 * seed) % 256)
                    row[4 * x + 3] = UInt8((x + y + seed) % 256)
                }
            }
        }
    } else {
        let ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let maximum = ten ? 1024 : 256
        for plane in 0..<planes {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw Failure("Missing plane")
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0xA5, stride * planeHeight)
            let components = plane == 0 ? 1 : 2
            for y in 0..<planeHeight {
                let row = base.advanced(by: y * stride)
                for x in 0..<(planeWidth * components) {
                    let value = (29 * x + 17 * y + 47 * seed + 101 * plane) % maximum
                    if ten {
                        row.assumingMemoryBound(to: UInt16.self)[x] =
                            UInt16(value * 64 + (x + y + seed) % 64)
                    } else {
                        row.assumingMemoryBound(to: UInt8.self)[x] = UInt8(value)
                    }
                }
            }
        }
    }
    return buffer
}

private func matrix(_ name: String, on buffer: CVPixelBuffer) {
    let value: CFString?
    switch name {
    case "601": value = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    case "709": value = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case "2020": value = kCVImageBufferYCbCrMatrix_ITU_R_2020
    case "unknown": value = "unrecognized-matrix" as CFString
    default: value = nil
    }
    if let value {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, value, .shouldPropagate)
    } else {
        CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
    }
}

private func layout(_ buffer: CVPixelBuffer) -> [String: Any] {
    let planes = CVPixelBufferGetPlaneCount(buffer)
    return [
        "format": CVPixelBufferGetPixelFormatType(buffer),
        "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
        "planes": planes,
        "strides": planes == 0 ? [CVPixelBufferGetBytesPerRow(buffer)]
            : (0..<planes).map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) },
    ]
}

private func receipt(_ sample: VideoColorSample?) -> [String: Any] {
    guard let sample else { return ["nil": true] }
    return [
        "columns": sample.columns, "rows": sample.rows,
        // Strings keep all 64 bits intact across JSON implementations.
        "rgb_bits": sample.colors.flatMap {
            [String($0.red.bitPattern, radix: 16), String($0.green.bitPattern, radix: 16),
             String($0.blue.bitPattern, radix: 16)]
        },
    ]
}

private func verify() throws -> [String: Any] {
    var traces: [[String: Any]] = []
    var buffers: [CVPixelBuffer] = []
    for (formatIndex, format) in formats.enumerated() {
        let sizes = formatIndex == 0 ? [(1, 1), (13, 9), (26, 18), (1920, 1080)]
            : [(2, 2), (26, 18), (130, 74), (1920, 1080)]
        for (sizeIndex, size) in sizes.enumerated() {
            let buffer = try makeBuffer(format.1, width: size.0, height: size.1,
                alignment: sizeIndex % 2 == 0 ? 128 : 256, seed: 3 + formatIndex * 11 + sizeIndex)
            buffers.append(buffer)
            for name in ["none", "601", "709", "2020", "unknown", "601", "none"] {
                matrix(name, on: buffer)
                traces.append(["case": "\(format.0)-\(size.0)x\(size.1)-\(name)",
                    "layout": layout(buffer), "sample": receipt(VideoFrameColorSampler.sample(buffer))])
            }
        }
    }
    let unsupported = try makeBuffer(kCVPixelFormatType_OneComponent8,
        width: 26, height: 18, alignment: 128, seed: 0)
    traces.append(["case": "unsupported", "sample": receipt(VideoFrameColorSampler.sample(unsupported))])
    let sampler = VideoFrameColorSampler()
    let times: [UInt64] = [
        1_000_000_000, 1_249_999_999, 1_250_000_000, 1_500_000_000,
        1_500_000_001, 2_000_000_000, 1, 250_000_001, 500_000_001,
    ]
    for cycle in 0..<12 {
        for (index, time) in times.enumerated() {
            let buffer = index == 5 ? unsupported : buffers[(cycle * 7 + index) % buffers.count]
            matrix(["none", "601", "709", "2020"][cycle % 4], on: buffer)
            traces.append(["case": "state-\(cycle)-\(index)",
                "sample": receipt(sampler.sampleIfNeeded(buffer, uptimeNanoseconds: time))])
        }
        if cycle % 3 == 0 { sampler.reset() }
    }
    // Include repeated identical samples and gradual changes with persistent
    // smoothing state. Existing unit tests also assert their expected semantics.
    sampler.reset()
    for index in 0..<40 {
        let buffer = buffers[(index / 10) * 4]
        traces.append(["case": "steady-\(index)",
            "sample": receipt(sampler.sampleIfNeeded(buffer,
                uptimeNanoseconds: UInt64(index + 1) * 250_000_000))])
    }
    return ["traces": traces, "trace_count": traces.count]
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@inline(never)
private func consume(_ sample: VideoColorSample?, into checksum: inout UInt64) -> Int {
    guard let sample else {
        checksum = (checksum ^ 0x9e3779b97f4a7c15) &* 1099511628211
        return 0
    }
    checksum = (checksum ^ UInt64(sample.columns * 100 + sample.rows)) &* 1099511628211
    for color in sample.colors {
        checksum = (checksum ^ color.red.bitPattern) &* 1099511628211
        checksum = (checksum ^ color.green.bitPattern) &* 1099511628211
        checksum = (checksum ^ color.blue.bitPattern) &* 1099511628211
    }
    return 1
}

private func measure(_ name: String, iterations: Int, seed: Int) throws -> [String: Any] {
    var buffers: [CVPixelBuffer] = []
    if name == "mixed-layouts" {
        for (index, format) in formats.enumerated() {
            buffers.append(try makeBuffer(format.1, width: index % 2 == 0 ? 130 : 1920,
                height: index % 2 == 0 ? 74 : 1080, alignment: index % 2 == 0 ? 128 : 256,
                seed: seed + index))
        }
    } else {
        let format: OSType
        if name == "unsupported" {
            format = kCVPixelFormatType_OneComponent8
        } else {
            format = formats.first(where: { name.hasPrefix($0.0 + "-") })?.1
                ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        let width = name.hasSuffix("-4k") ? 3840 : 1920
        let height = name.hasSuffix("-4k") ? 2160 : 1080
        let count = name == "steady-nv12" || name == "throttled" || name == "unsupported" ? 1 : 2
        for index in 0..<count {
            buffers.append(try makeBuffer(format, width: width, height: height,
                alignment: index == 0 ? 128 : 256, seed: seed + index * 29))
        }
    }
    for (index, buffer) in buffers.enumerated() {
        matrix(index % 2 == 0 ? "709" : "2020", on: buffer)
    }
    let sampler = VideoFrameColorSampler()
    var checksum: UInt64 = 1469598103934665603
    var admitted = 0
    var counter: UInt64 = 0
    func operation(_ index: Int) -> VideoColorSample? {
        counter &+= 1
        let buffer = buffers[index % buffers.count]
        if name == "throttled" {
            return sampler.sampleIfNeeded(buffer, uptimeNanoseconds: 1_000_000_000)
        }
        if name == "admitted-nv12" || name == "steady-nv12" {
            return sampler.sampleIfNeeded(buffer, uptimeNanoseconds: counter * 250_000_000)
        }
        return VideoFrameColorSampler.sample(buffer)
    }
    for index in 0..<512 { _ = consume(operation(index), into: &checksum) }
    checksum = 1469598103934665603
    let cpuStart = cpuNanoseconds()
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
        admitted += consume(operation(index), into: &checksum)
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let cpuElapsed = cpuNanoseconds() - cpuStart
    return [
        "case": name, "iterations": iterations, "seed": seed,
        "wall_ns": elapsed, "cpu_ns": cpuElapsed,
        "published": admitted, "checksum": String(checksum),
        "layouts": buffers.map(layout),
    ]
}

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let value: [String: Any]
        if args == ["verify"] {
            value = try verify()
        } else if args.count == 4, args[0] == "measure",
                  let iterations = Int(args[2]), iterations > 0, let seed = Int(args[3]) {
            value = try measure(args[1], iterations: iterations, seed: seed)
        } else {
            throw Failure("Usage: Harness verify | measure CASE ITERATIONS SEED")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
