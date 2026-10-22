import CoreGraphics
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import ImageIO
import IlliquidCore
import Metal

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Fixture: Sendable {
    let name: String
    let capture: NativeScreenshot
}

private struct DecodedPNG {
    let width: Int
    let height: Int
    let pixels: Data
    let metadata: [String: String]
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Result<Data, Error>] = [:]
    func set(_ result: Result<Data, Error>, at index: Int) {
        lock.withLock { values[index] = result }
    }
    func get(_ index: Int) throws -> Data {
        try lock.withLock {
            guard let result = values[index] else { throw HarnessError("Missing concurrent result") }
            return try result.get()
        }
    }
}

@main
private enum ScreenshotContextBenchmark {
    static let scenarios = ["bgra-1080p", "nv12-1080p", "p010-1080p", "bgra-4k", "subtitle-1080p"]

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else { throw HarnessError("Expected --verify, --first or --warm") }
        if mode == "--verify", args.count == 2 {
            try verify(directory: URL(fileURLWithPath: args[1], isDirectory: true))
            return
        }
        guard (mode == "--first" && args.count == 2) || (mode == "--warm" && args.count == 3),
              scenarios.contains(args[1]) else { throw HarnessError("Invalid benchmark arguments") }
        let iterations = mode == "--first" ? 1 : Int(args[2]) ?? 0
        guard iterations > 0 && iterations <= 1_000 else { throw HarnessError("Invalid iteration count") }
        try measure(scenario: args[1], warm: mode == "--warm", iterations: iterations)
    }

    static func buffer(width: Int, height: Int, format: OSType, seed: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attributes as CFDictionary, &result) == kCVReturnSuccess,
              let result else { throw HarnessError("Could not allocate pixel buffer") }
        guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
            throw HarnessError("Could not lock fixture")
        }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        if format == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(result) else { throw HarnessError("Missing BGRA bytes") }
            let stride = CVPixelBufferGetBytesPerRow(result)
            memset(base, 0, stride * height)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    bytes[offset] = UInt8((x + y / 4 + seed * 71) % 256)
                    bytes[offset + 1] = UInt8((x / 8 + y * 5 + seed * 53) % 256)
                    bytes[offset + 2] = UInt8((x * 3 + y + seed * 31) % 256)
                    bytes[offset + 3] = 255
                }
            }
            CVBufferSetAttachment(result, kCVImageBufferCGColorSpaceKey,
                                  CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
        } else {
            let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            for plane in 0..<2 {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) else {
                    throw HarnessError("Missing YUV plane")
                }
                let rows = CVPixelBufferGetHeightOfPlane(result, plane)
                let columns = CVPixelBufferGetWidthOfPlane(result, plane)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(result, plane)
                memset(base, 0, stride * rows)
                for y in 0..<rows {
                    for x in 0..<(columns * (plane == 0 ? 1 : 2)) {
                        let pattern = (x * 3 + y * 5 + seed * 47) % 220
                        if tenBit {
                            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
                            row[x] = UInt16(64 + pattern * 4) << 6
                        } else {
                            base.assumingMemoryBound(to: UInt8.self)[y * stride + x] = UInt8(16 + pattern)
                        }
                    }
                }
            }
            CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey,
                tenBit ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey,
                tenBit ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate)
            CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey,
                tenBit ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate)
        }
        return result
    }

    static func subtitleRegions(width: Int, height: Int, seed: Int) -> [ASSRenderedRegion] {
        let w = min(480, max(12, width / 3)), h = min(48, max(6, height / 12))
        let stride = w + 8
        var mask = Data(count: stride * h)
        mask.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<h { for x in 0..<w {
                bytes[y * stride + x] = UInt8((x * 13 + y * 17 + seed * 29) % 256)
            } }
        }
        let text = ASSRenderedRegion(bitmap: mask, color: 0xffe06020,
            frame: CGRect(x: CGFloat(width / 4), y: CGFloat(height - h - 4), width: CGFloat(w), height: CGFloat(h)),
            stride: stride)
        let bitmap = ASSRenderedRegion(bitmap: Data([0, 160, 0, 160, 100, 0, 0, 100,
                                                     0, 0, 255, 255, 0, 0, 0, 0]),
            color: 0, frame: CGRect(x: 4, y: 4, width: 20, height: 20), stride: 8,
            bitmapSize: CGSize(width: 2, height: 2), isPremultipliedBGRA: true)
        return [text, bitmap]
    }

    static func fixture(_ scenario: String, seed: Int, small: Bool = false,
                        rotation: Double = 0, mirrored: Bool = false,
                        adjustments: VideoAdjustmentState = .standard, aperture: Bool = false) throws -> Fixture {
        let width = small ? 192 : scenario == "bgra-4k" ? 3_840 : 1_920
        let height = small ? 108 : scenario == "bgra-4k" ? 2_160 : 1_080
        let format = scenario.hasPrefix("nv12") ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : scenario.hasPrefix("p010") ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let input = try buffer(width: width, height: height, format: format, seed: seed)
        if aperture {
            let clean: [String: Any] = [
                kCVImageBufferCleanApertureWidthKey as String: width - 16,
                kCVImageBufferCleanApertureHeightKey as String: height - 12,
                kCVImageBufferCleanApertureHorizontalOffsetKey as String: 2,
                kCVImageBufferCleanApertureVerticalOffsetKey as String: -2,
            ]
            CVBufferSetAttachment(input, kCVImageBufferCleanApertureKey, clean as CFDictionary, .shouldPropagate)
        }
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        return Fixture(name: "\(scenario)-\(seed)", capture: NativeScreenshot(
            buffer: input, displaySize: size, rotation: rotation, mirrored: mirrored, size: size,
            adjustments: adjustments,
            regions: scenario == "subtitle-1080p" ? subtitleRegions(width: width, height: height, seed: seed) : []))
    }

    static func decode(_ png: Data) throws -> DecodedPNG {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw HarnessError("Invalid PNG") }
        var data = Data(count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw HarnessError("Could not decode PNG pixels") }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        var metadata: [String: String] = [:]
        for key in [kCGImagePropertyColorModel, kCGImagePropertyDepth, kCGImagePropertyHasAlpha,
                    kCGImagePropertyProfileName, kCGImagePropertyOrientation] {
            if let value = properties[key as String] { metadata[key as String] = String(describing: value) }
        }
        return DecodedPNG(width: image.width, height: image.height, pixels: data, metadata: metadata)
    }

    static func verify(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fixtures: [Fixture] = []
        for scenario in scenarios {
            for seed in 0..<2 { fixtures.append(try fixture(scenario, seed: seed, small: true)) }
        }
        fixtures.append(try fixture("bgra-1080p", seed: 2, small: true, rotation: 90, mirrored: true))
        fixtures.append(try fixture("nv12-1080p", seed: 2, small: true, rotation: 180, aperture: true))
        fixtures.append(try fixture("p010-1080p", seed: 2, small: true, rotation: 270, mirrored: true))
        fixtures.append(try fixture("subtitle-1080p", seed: 2, small: true,
            adjustments: VideoAdjustmentState(aspectRatio: "4:3", crop: "1:1")))
        // Verify every timed format at its actual dimensions, including 4K.
        // These also exercise resolution changes on the same shared context.
        for scenario in scenarios { fixtures.append(try fixture(scenario, seed: 3)) }
        let first = fixtures[0]
        let concurrent = ConcurrentResults()
        let immutableFixtures = fixtures
        // Exercise the shared renderer's first initialization concurrently.
        DispatchQueue.concurrentPerform(iterations: immutableFixtures.count) { index in
            concurrent.set(Result { try autoreleasepool { try immutableFixtures[index].capture.png() } }, at: index)
        }
        var records: [[String: Any]] = []
        for (index, fixture) in fixtures.enumerated() {
            let decoded = try autoreleasepool { try decode(fixture.capture.png()) }
            let parallel = try decode(concurrent.get(index))
            guard decoded.width == parallel.width, decoded.height == parallel.height,
                  decoded.pixels == parallel.pixels, decoded.metadata == parallel.metadata else {
                throw HarnessError("Concurrent pixels or metadata differ for \(fixture.name)")
            }
            try decoded.pixels.write(to: directory.appendingPathComponent("\(index)-\(fixture.name).bin"))
            records.append(["case": fixture.name, "width": decoded.width, "height": decoded.height,
                "rgba_sha256": SHA256.hash(data: decoded.pixels).map { String(format: "%02x", $0) }.joined(),
                "metadata": decoded.metadata, "concurrent_equal": true])
        }
        let repeated = try decode(first.capture.png())
        let original = try Data(contentsOf: directory.appendingPathComponent("0-\(first.name).bin"))
        guard repeated.pixels == original else { throw HarnessError("Mixed captures contaminated the initial frame") }
        let receipt: [String: Any] = ["cases": records, "mixed_sequence_replay_equal": true,
            "concurrent_captures": fixtures.count, "metal_device": MTLCreateSystemDefaultDevice()?.name ?? "none"]
        let encoded = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try encoded.write(to: directory.appendingPathComponent("verification.json"))
        try printJSON(receipt)
    }

    static func usage() -> rusage {
        var value = rusage()
        _ = getrusage(RUSAGE_SELF, &value)
        return value
    }

    static func cpuNanoseconds(_ value: rusage) -> UInt64 {
        UInt64(value.ru_utime.tv_sec + value.ru_stime.tv_sec) * 1_000_000_000
            + UInt64(value.ru_utime.tv_usec + value.ru_stime.tv_usec) * 1_000
    }

    static func measure(scenario: String, warm: Bool, iterations: Int) throws {
        // Input generation, CoreVideo allocation, PNG verification and file IO
        // are outside the measured png() interval. Each capture sees new pixels.
        let fixtures = try (0..<3).map { try fixture(scenario, seed: $0) }
        let beforeWarmup = usage()
        if warm {
            for index in 0..<2 { _ = try autoreleasepool { try fixtures[index].capture.png() } }
        }
        var sizes: [Int] = []
        sizes.reserveCapacity(iterations)
        var checksum: UInt64 = 0
        let before = usage()
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<iterations {
            let count = try autoreleasepool {
                let data = try fixtures[iteration % fixtures.count].capture.png()
                checksum &+= UInt64(data.count)
                checksum &+= UInt64(data.first ?? 0) + UInt64(data.last ?? 0)
                return data.count
            }
            sizes.append(count)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let after = usage()
        guard sizes.allSatisfy({ $0 > 100 }) else { throw HarnessError("Empty PNG output") }
        try printJSON(["scenario": scenario, "mode": warm ? "warm" : "first",
            "operation_count": iterations, "wall_ns": elapsed,
            "cpu_ns": cpuNanoseconds(after) - cpuNanoseconds(before),
            "checksum": checksum, "png_sizes": sizes,
            "maxrss_before_warmup": beforeWarmup.ru_maxrss, "maxrss_before": before.ru_maxrss,
            "maxrss_after": after.ru_maxrss])
    }

    static func printJSON(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
