import Dispatch
import Foundation
@testable import IlliquidNativePlayback
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

private func pixel(row: Int, column: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: row &* 71 &+ column &* 13 &+ 7)
}

@main
struct Driver {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 7, let width = Int(args[3]), let height = Int(args[4]),
              let stride = Int(args[5]), let iterations = Int(args[6]),
              width > 0, height > 0, stride >= width, iterations > 0,
              stride <= 1_048_576, height <= 1_048_576,
              stride <= 128 * 1_024 * 1_024 / height else {
            fatalError("Usage: bitmap-copy verify|bench NAME WIDTH HEIGHT STRIDE ITERATIONS")
        }
        let mode = args[1]
        precondition(mode == "verify" || mode == "bench")
        // Both variants receive fully initialized, fully padded storage. The
        // original copy is unsafe on minimum-size real libass allocations;
        // the separate guard-page regression tests the new helper's boundary.
        let sourceBytes = stride * height
        let source = UnsafeMutableRawPointer.allocate(byteCount: sourceBytes, alignment: 64)
        defer { source.deallocate() }
        func fillSource() {
            source.initializeMemory(as: UInt8.self, repeating: 0xE5, count: sourceBytes)
            for row in 0..<height {
                for column in 0..<width {
                    source.storeBytes(of: pixel(row: row, column: column),
                                      toByteOffset: row * stride + column, as: UInt8.self)
                }
            }
        }
        fillSource()
        let resultStride = copiedBitmapStride(width: width, sourceStride: stride)
        let expectedBytes = resultStride * height
        let output = copyBitmap(from: source, width: width, height: height, sourceStride: stride)
        precondition(output.count == expectedBytes)
        var pixelChecksum: UInt64 = 0xcbf29ce484222325
        for row in 0..<height {
            for column in 0..<width {
                let value = output[row * resultStride + column]
                precondition(value == pixel(row: row, column: column), "Visible pixel mismatch")
                pixelChecksum = (pixelChecksum ^ UInt64(value)) &* 0x100000001b3
            }
        }
        // Verify independent ownership after every source byte changes.
        source.initializeMemory(as: UInt8.self, repeating: 0, count: sourceBytes)
        for row in 0..<height {
            for column in 0..<width {
                precondition(output[row * resultStride + column] == pixel(row: row, column: column))
            }
        }
        fillSource()
        var receipt: [String: Any] = [
            "mode": mode, "name": args[2], "width": width, "height": height,
            "source_stride": stride, "output_stride": resultStride,
            "source_fixture_bytes": sourceBytes,
            "source_valid_extent_bytes": stride * (height - 1) + width,
            "visible_bytes": width * height, "owned_data_count": output.count,
            "visible_checksum": String(pixelChecksum, radix: 16),
            "all_visible_pixels_equal": true, "independent_ownership": true,
        ]
        if mode == "verify" {
            let retained = (0..<32).map { _ in
                copyBitmap(from: source, width: width, height: height, sourceStride: stride)
            }
            receipt["retained_copies"] = retained.count
            receipt["retained_data_count_total"] = retained.reduce(0) { $0 + $1.count }
            withExtendedLifetime(retained) {}
        } else {
            @inline(never) func batch(_ count: Int) -> UInt64 {
                var checksum: UInt64 = 0
                for index in 0..<count {
                    let bytes = copyBitmap(from: source, width: width, height: height, sourceStride: stride)
                    let row = index % height
                    let column = (index &* 17) % width
                    checksum = checksum &* 31 &+ UInt64(bytes[row * resultStride + column])
                }
                return checksum
            }
            let warmupChecksum = batch(min(iterations, 1_024))
            let startCPU = cpuNanoseconds()
            let startWall = DispatchTime.now().uptimeNanoseconds
            let checksum = batch(iterations)
            let wall = DispatchTime.now().uptimeNanoseconds - startWall
            let cpu = cpuNanoseconds() - startCPU
            receipt["iterations"] = iterations
            receipt["elapsed_ns"] = wall
            receipt["cpu_ns"] = cpu
            receipt["checksum"] = String(checksum, radix: 16)
            receipt["warmup_checksum"] = String(warmupChecksum, radix: 16)
        }
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
