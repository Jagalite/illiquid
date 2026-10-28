import CoreVideo
import Darwin
import Foundation
import IlliquidCore
import IOSurface

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private enum Format: String, CaseIterable, Sendable {
    case bgra, nv12Video = "nv12-video", nv12Full = "nv12-full"
    case p010Video = "p010-video", p010Full = "p010-full", unsupported
    var code: OSType {
        switch self {
        case .bgra: kCVPixelFormatType_32BGRA
        case .nv12Video: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12Full: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .p010Video: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p010Full: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .unsupported: kCVPixelFormatType_32ARGB
        }
    }
    var tenBit: Bool { self == .p010Video || self == .p010Full }
    var fullRange: Bool { self == .nv12Full || self == .p010Full }
}

private struct Case: Codable, Sendable {
    let name: String
    let format: String
    let width: Int
    let height: Int
    let matrix: String
    let mode: String
}

private let dimensions = [("1080p", 1920, 1080), ("padded", 122, 82), ("tiny", 2, 2)]
private let cases: [Case] = Format.allCases.flatMap { format in
    (format == .unsupported ? [dimensions[0]] : dimensions).map { size in
        Case(name: "\(format.rawValue)/\(size.0)", format: format.rawValue,
             width: size.1, height: size.2, matrix: "709", mode: "raw")
    }
} + ["stateful", "throttled"].map { mode in
    Case(name: "\(mode)/nv12-video/1080p", format: "nv12-video",
         width: 1920, height: 1080, matrix: "709", mode: mode)
}

private enum Fill { case gradient(Int), gray(Int), black, white }

private func setMatrix(_ buffer: CVPixelBuffer, _ matrix: String) {
    let value: CFString?
    switch matrix {
    case "601": value = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    case "709": value = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case "2020": value = kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: value = nil
    }
    if let value {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, value, .shouldPropagate)
    } else {
        CVBufferRemoveAttachment(buffer, kCVImageBufferYCbCrMatrixKey)
    }
}

private func makeBuffer(_ spec: Case, fill: Fill) throws -> CVPixelBuffer {
    guard let format = Format(rawValue: spec.format) else { throw Failure("unknown format") }
    var optional: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        kCVPixelBufferBytesPerRowAlignmentKey: 256,
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, spec.width, spec.height,
                                   format.code, attributes as CFDictionary, &optional)
    guard status == kCVReturnSuccess, let buffer = optional else {
        throw Failure("CVPixelBufferCreate \(spec.name): \(status)")
    }
    guard CVPixelBufferGetIOSurface(buffer) != nil else { throw Failure("missing IOSurface") }
    setMatrix(buffer, spec.matrix)
    try fillBuffer(buffer, format: format, fill: fill)
    if spec.name.hasSuffix("/padded") {
        let planes = CVPixelBufferGetPlaneCount(buffer)
        let stride = planes == 0 ? CVPixelBufferGetBytesPerRow(buffer)
            : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let packed = spec.width * (planes == 0 ? 4 : format.tenBit ? 2 : 1)
        guard stride > packed else { throw Failure("padded fixture has no row padding") }
    }
    return buffer
}

private func fillBuffer(_ buffer: CVPixelBuffer, format: Format, fill: Fill) throws {
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
        throw Failure("fixture lock failed")
    }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let edges = format.tenBit ? [0, 1, 64, 512, 940, 1022, 1023]
        : [0, 1, 16, 64, 128, 235, 255]
    let isWhite: Bool
    switch fill { case .white: isWhite = true; default: isWhite = false }
    func component(_ x: Int, _ y: Int, _ channel: Int, _ maximum: Int) -> Int {
        switch fill {
        case .gray(let level): return level // Used only for the BGRA smoothing sequence.
        case .black, .white:
            if format == .bgra || format == .unsupported { return isWhite ? 255 : 0 }
            if channel != 0 { return format.tenBit ? 512 : 128 }
            if format.fullRange { return isWhite ? maximum : 0 }
            return format.tenBit ? (isWhite ? 940 : 64) : (isWhite ? 235 : 16)
        case .gradient(let seed):
            let edge = (x + 3 * y + channel + seed) % 23
            return edge < edges.count ? edges[edge]
                : (17 * x + 31 * y + 67 * channel + 47 * seed) % (maximum + 1)
        }
    }
    let planeCount = CVPixelBufferGetPlaneCount(buffer)
    if planeCount == 0 {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure("packed base") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        memset(base, 0xA5, stride * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[4 * x] = UInt8(component(x, y, 0, 255))
                row[4 * x + 1] = UInt8(component(x, y, 1, 255))
                row[4 * x + 2] = UInt8(component(x, y, 2, 255))
                row[4 * x + 3] = 255
            }
        }
    } else {
        guard planeCount == 2 else { throw Failure("unexpected plane count") }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw Failure("plane base")
            }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0xA5, stride * height)
            let channels = plane == 0 ? 1 : 2
            for y in 0..<height {
                for x in 0..<width {
                    for c in 0..<channels {
                        let channel = plane == 0 ? 0 : c + 1
                        let value = component(x, y, channel, format.tenBit ? 1023 : 255)
                        if format.tenBit {
                            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                            // The sampler must ignore all six low storage bits.
                            row[x * channels + c] = UInt16(value << 6 | ((x + y + c) & 63))
                        } else {
                            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                            row[x * channels + c] = UInt8(value)
                        }
                    }
                }
            }
        }
    }
}

private func layout(_ buffer: CVPixelBuffer) -> [String: Any] {
    let planes = CVPixelBufferGetPlaneCount(buffer)
    return ["width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
            "format": CVPixelBufferGetPixelFormatType(buffer), "planeCount": planes,
            "rowBytes": planes == 0 ? [CVPixelBufferGetBytesPerRow(buffer)]
                : (0..<planes).map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) },
            "planeWidths": (0..<planes).map { CVPixelBufferGetWidthOfPlane(buffer, $0) },
            "planeHeights": (0..<planes).map { CVPixelBufferGetHeightOfPlane(buffer, $0) },
            "iosurface": CVPixelBufferGetIOSurface(buffer) != nil]
}

private func record(_ name: String, _ buffer: CVPixelBuffer, _ sample: VideoColorSample?) -> [String: Any] {
    var result: [String: Any] = ["name": name, "layout": layout(buffer),
        "columns": NSNull(), "rows": NSNull(), "bits": NSNull()]
    if let sample {
        result["columns"] = sample.columns
        result["rows"] = sample.rows
        result["bits"] = sample.colors.map { [$0.red.bitPattern, $0.green.bitPattern, $0.blue.bitPattern] }
    }
    return result
}

private func verify() throws -> [String: Any] {
    var records: [[String: Any]] = [], goldenChecks = 0
    for spec in cases where spec.mode == "raw" {
        let format = Format(rawValue: spec.format)!
        let buffer = try makeBuffer(spec, fill: .gradient(0))
        for matrix in ["missing", "601", "709", "2020"] {
            setMatrix(buffer, matrix)
            records.append(record("\(spec.name)/\(matrix)/gradient", buffer, VideoFrameColorSampler.sample(buffer)))
        }
        try fillBuffer(buffer, format: format, fill: .gradient(5))
        records.append(record("\(spec.name)/mutated", buffer, VideoFrameColorSampler.sample(buffer)))
        if format == .unsupported {
            guard VideoFrameColorSampler.sample(buffer) == nil else { throw Failure("unsupported accepted") }
            goldenChecks += 1
            continue
        }
        for (fill, expected, label) in [(Fill.black, 0.0, "black"), (.white, 1.0, "white")] {
            try fillBuffer(buffer, format: format, fill: fill)
            guard let sample = VideoFrameColorSampler.sample(buffer), sample.columns == 12,
                  sample.rows == 8, sample.colors.count == 96,
                  sample.colors.allSatisfy({
                      abs($0.red - expected) < 1e-12 && abs($0.green - expected) < 1e-12
                          && abs($0.blue - expected) < 1e-12
                  }) else { throw Failure("\(spec.name) \(label) golden failed") }
            records.append(record("\(spec.name)/\(label)", buffer, sample))
            goldenChecks += 1
        }
    }
    let spec = cases.first { $0.name == "bgra/padded" }!
    let buffer = try makeBuffer(spec, fill: .black)
    let other = try makeBuffer(cases.first { $0.name == "p010-video/tiny" }!, fill: .gradient(7))
    let sampler = VideoFrameColorSampler()
    for (index, now) in [UInt64(0), 0, 100_000_000, 250_000_000, 500_000_000,
                        750_000_000, 1_000_000_000, 999_999_999].enumerated() {
        if index == 3 { try fillBuffer(buffer, format: .bgra, fill: .gray(51)) }
        if index == 4 { try fillBuffer(buffer, format: .bgra, fill: .white) }
        let source = index >= 6 ? other : buffer
        let sampled = sampler.sampleIfNeeded(source, uptimeNanoseconds: now)
        if [1, 2, 5].contains(index) {
            guard sampled == nil else { throw Failure("throttle/unchanged publication golden failed") }
            goldenChecks += 1
        } else if index == 3 || index == 4 {
            let expected = index == 3 ? 0.2 * (1 - exp(-0.25 / 0.65)) : 1.0
            guard let sampled, sampled.colors.allSatisfy({
                abs($0.red - expected) < 1e-12 && abs($0.green - expected) < 1e-12
                    && abs($0.blue - expected) < 1e-12
            }) else { throw Failure("smoothing/scene-cut golden failed") }
            goldenChecks += 1
        }
        records.append(record("sequence/\(index)", source, sampled))
    }
    sampler.reset()
    let reset = sampler.sampleIfNeeded(buffer, uptimeNanoseconds: 0)
    guard reset != nil else { throw Failure("reset did not publish") }
    records.append(record("sequence/reset", buffer, reset))
    goldenChecks += 1
    return ["schema": 1, "records": records, "goldenChecks": goldenChecks]
}

@inline(never)
private func consume(_ sample: VideoColorSample?, _ checksum: inout UInt64) {
    guard let sample else { checksum = (checksum ^ 0xFF) &* 1_099_511_628_211; return }
    for color in sample.colors {
        checksum = (checksum ^ color.red.bitPattern) &* 1_099_511_628_211
        checksum = (checksum ^ color.green.bitPattern) &* 1_099_511_628_211
        checksum = (checksum ^ color.blue.bitPattern) &* 1_099_511_628_211
    }
}

private func run(_ spec: Case, _ buffers: [CVPixelBuffer], _ iterations: Int,
                 sampler: VideoFrameColorSampler) -> UInt64 {
    var checksum: UInt64 = 14_695_981_039_346_656_037
    for start in stride(from: 0, to: iterations, by: 1024) {
        let end = min(start + 1024, iterations)
        autoreleasepool {
            switch spec.mode {
            case "stateful":
                for index in start..<end {
                    consume(sampler.sampleIfNeeded(buffers[index & 1],
                            uptimeNanoseconds: UInt64(index) * 250_000_000), &checksum)
                }
            case "throttled":
                for _ in start..<end {
                    consume(sampler.sampleIfNeeded(buffers[1], uptimeNanoseconds: 1), &checksum)
                }
            default:
                for index in start..<end {
                    consume(VideoFrameColorSampler.sample(buffers[index & 1]), &checksum)
                }
            }
        }
    }
    return checksum
}

private func cpuNanoseconds() throws -> UInt64 {
    var value = timespec()
    guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { throw Failure("CPU clock failed") }
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func benchmark(_ name: String, iterations: Int) throws -> [String: Any] {
    guard let spec = cases.first(where: { $0.name == name }), (1...100_000_000).contains(iterations)
    else { throw Failure("unknown case or invalid iterations") }
    let buffers = try [makeBuffer(spec, fill: spec.mode == "raw" ? .gradient(0) : .black),
                       makeBuffer(spec, fill: spec.mode == "raw" ? .gradient(1) : .white)]
    func preparedSampler() -> VideoFrameColorSampler {
        let sampler = VideoFrameColorSampler()
        if spec.mode == "throttled" { _ = sampler.sampleIfNeeded(buffers[0], uptimeNanoseconds: 0) }
        return sampler
    }
    let warmupChecksum = run(spec, buffers, 2048, sampler: preparedSampler())
    let sampler = preparedSampler()
    let cpuStart = try cpuNanoseconds(), wallStart = DispatchTime.now().uptimeNanoseconds
    let checksum = run(spec, buffers, iterations, sampler: sampler)
    let wall = DispatchTime.now().uptimeNanoseconds - wallStart
    let cpu = try cpuNanoseconds() - cpuStart
    return ["case": name, "iterations": iterations, "wallNanoseconds": wall,
            "cpuNanoseconds": cpu, "checksum": String(checksum),
            "warmupChecksum": String(warmupChecksum), "layout": layout(buffers[0])]
}

@main
private enum Main {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let result: Any
        if args == ["--list"] {
            result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cases))
        } else if args == ["--verify"] {
            result = try verify()
        } else if args.count == 3, args[0] == "--bench", let count = Int(args[2]) {
            result = try benchmark(args[1], iterations: count)
        } else {
            throw Failure("usage: --list | --verify | --bench CASE ITERATIONS")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
