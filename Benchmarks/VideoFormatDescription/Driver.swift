import CoreMedia
import CoreVideo
import Darwin
import Dispatch
import Foundation

private enum DriverError: Error { case invalid(String) }

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw DriverError.invalid(message) }
}

private func makeBuffers(_ workload: String) throws -> [CVPixelBuffer] {
    let known = ["stable-bgra", "stable-nv12", "stable-p010-hdr", "alternating-size", "alternating-color"]
    try require(known.contains(workload), "Unknown workload: \(workload)")
    return try (0..<8).map { index in
        let hdr = workload == "stable-p010-hdr"
        let yuv = hdr || workload == "stable-nv12" || workload == "alternating-color"
        let alternate = index % 2 == 1
        let small = workload == "alternating-size" && alternate
        let wideColor = hdr || (workload == "alternating-color" && alternate)
        let format = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : yuv ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, small ? 1280 : 1920, small ? 720 : 1080,
            format, nil, &created
        )
        try require(status == kCVReturnSuccess, "Pixel-buffer creation failed: \(status)")
        guard let buffer = created else { throw DriverError.invalid("Missing pixel buffer") }
        CVBufferSetAttachment(
            buffer, kCVImageBufferColorPrimariesKey,
            wideColor ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer, kCVImageBufferTransferFunctionKey,
            wideColor ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        if yuv {
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey,
                wideColor ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
        }
        if hdr {
            let mastering = Data([
                0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8,
                0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42,
                0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
            ])
            CVBufferSetAttachment(
                buffer, kCVImageBufferMasteringDisplayColorVolumeKey, mastering as CFData, .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer, kCVImageBufferContentLightLevelInfoKey, Data([0x03, 0xe8, 0x01, 0x90]) as CFData,
                .shouldPropagate
            )
        }
        return buffer
    }
}

@inline(never)
private func consume(_ description: CMVideoFormatDescription) -> UInt64 {
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    return UInt64(dimensions.width) &+ UInt64(dimensions.height)
        &+ UInt64(CMFormatDescriptionGetMediaSubType(description))
}

@inline(never)
private func baselineLoop(_ buffers: [CVPixelBuffer], iterations: Int) throws -> UInt64 {
    var checksum: UInt64 = 0
    var start = 0
    while start < iterations {
        let end = min(start + 256, iterations)
        try autoreleasepool {
            for index in start..<end {
                checksum &+= consume(try createFormatDescription(buffers[index % buffers.count]))
            }
        }
        start = end
    }
    return checksum
}

@inline(never)
private func cachedLoop(
    _ buffers: [CVPixelBuffer], cache: VideoFormatDescriptionCache, iterations: Int
) throws -> UInt64 {
    var checksum: UInt64 = 0
    var start = 0
    while start < iterations {
        let end = min(start + 256, iterations)
        try autoreleasepool {
            for index in start..<end {
                let buffer = buffers[index % buffers.count]
                let description = try cache.description(for: buffer) {
                    try createFormatDescription(buffer)
                }
                checksum &+= consume(description)
            }
        }
        start = end
    }
    return checksum
}

private func verify(_ buffers: [CVPixelBuffer], workload: String, iterations: Int) throws -> [String: Any] {
    let cache = VideoFormatDescriptionCache()
    var factoryCalls = 0
    var checksum: UInt64 = 0
    for index in 0..<iterations {
        let buffer = buffers[index % buffers.count]
        let expected = try createFormatDescription(buffer)
        let actual = try cache.description(for: buffer) {
            factoryCalls += 1
            return try createFormatDescription(buffer)
        }
        try require(CMFormatDescriptionEqual(actual, otherFormatDescription: expected), "Format parity failed")
        try require(
            CMVideoFormatDescriptionMatchesImageBuffer(actual, imageBuffer: buffer),
            "Image-buffer compatibility failed"
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: actual,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        try require(status == noErr && sample != nil, "Sample creation failed: \(status)")
        checksum &+= consume(actual)
    }
    let expectedCalls = workload.hasPrefix("stable-") ? 1 : iterations
    try require(factoryCalls == expectedCalls, "Unexpected cache misses: \(factoryCalls) vs \(expectedCalls)")
    return [
        "workload": workload, "iterations": iterations, "parity": true,
        "baseline_factory_calls": iterations, "cached_factory_calls": factoryCalls,
        "checksum": checksum,
        "common_extension_keys": String(describing: CMVideoFormatDescriptionGetExtensionKeysCommonWithImageBuffers()),
    ]
}

private func cpuNanoseconds() -> UInt64 {
    var value = timespec()
    precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
    return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
}

@main
struct VideoFormatDescriptionBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        try require(arguments.count == 4, "Usage: benchmark verify|baseline|cached WORKLOAD ITERATIONS")
        let mode = arguments[1]
        let workload = arguments[2]
        guard let iterations = Int(arguments[3]), iterations > 0 else {
            throw DriverError.invalid("Iterations must be positive")
        }
        let buffers = try makeBuffers(workload)
        let result: [String: Any]
        if mode == "verify" {
            result = try verify(buffers, workload: workload, iterations: iterations)
        } else {
            try require(mode == "baseline" || mode == "cached", "Unknown mode")
            let cache = VideoFormatDescriptionCache()
            // 2,048 is a multiple of the ring size. All-miss sequences finish
            // warm-up on B and start measurement on A; stable caches stay warm.
            let warmup: UInt64
            if mode == "baseline" {
                warmup = try baselineLoop(buffers, iterations: 2_048)
            } else {
                warmup = try cachedLoop(buffers, cache: cache, iterations: 2_048)
            }
            let cpuStart = cpuNanoseconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let checksum: UInt64
            if mode == "baseline" {
                checksum = try baselineLoop(buffers, iterations: iterations)
            } else {
                checksum = try cachedLoop(buffers, cache: cache, iterations: iterations)
            }
            let wallElapsed = DispatchTime.now().uptimeNanoseconds - wallStart
            let cpuElapsed = cpuNanoseconds() - cpuStart
            result = [
                "mode": mode, "workload": workload, "iterations": iterations,
                "wall_ns": wallElapsed, "cpu_ns": cpuElapsed,
                "wall_ns_per_operation": Double(wallElapsed) / Double(iterations),
                "cpu_ns_per_operation": Double(cpuElapsed) / Double(iterations),
                "checksum": checksum, "warmup_checksum": warmup,
                "warmup_iterations": 2_048, "autorelease_pool_batch": 256,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
