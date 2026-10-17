import CoreMedia
import CoreVideo
import Darwin
import Foundation

// A native component experiment, not a replacement playback clock or renderer.
// Every frame receives a NEW CMSampleBuffer; only validated format descriptions
// may be reused. No application, media file, display, or user state is opened.
private struct ProbeError: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw ProbeError(message: message) }
}
private func nanos(_ clock: clockid_t) throws -> UInt64 {
    var t = timespec()
    try require(clock_gettime(clock, &t) == 0, "clock_gettime failed")
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}
private final class FormatCache {
    var value: CMVideoFormatDescription?
    var creations = 0
    var hits = 0
    func reset() { value = nil }
    func resolve(_ image: CVPixelBuffer, reuse: Bool) throws -> CMVideoFormatDescription {
        if reuse, let value,
           CMVideoFormatDescriptionMatchesImageBuffer(value, imageBuffer: image) {
            hits += 1
            return value
        }
        var next: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &next)
        try require(status == noErr && next != nil, "format creation failed: \(status)")
        value = next
        creations += 1
        return next!
    }
}
private func makeImage(_ width: Int, _ height: Int, _ format: OSType,
                       hdr: Bool = false, alignment: Int = 64) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let attrs = [kCVPixelBufferBytesPerRowAlignmentKey: alignment] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs, &image)
    try require(status == kCVReturnSuccess && image != nil, "pixel allocation failed: \(status)")
    let result = image!
    try require(CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess, "lock failed")
    if CVPixelBufferIsPlanar(result) {
        for plane in 0..<CVPixelBufferGetPlaneCount(result) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(result, plane) {
                memset(base, 0, CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
            }
        }
    } else if let base = CVPixelBufferGetBaseAddress(result) {
        memset(base, 0, CVPixelBufferGetBytesPerRow(result) * CVPixelBufferGetHeight(result))
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey,
        hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey,
        hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey,
        hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return result
}
private func sample(_ image: CVPixelBuffer, _ format: CMVideoFormatDescription,
                    _ index: Int) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: Int64(index), timescale: 60), decodeTimeStamp: .invalid)
    var output: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
        imageBuffer: image, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &output)
    try require(status == noErr && output != nil, "sample creation failed: \(status)")
    return output!
}
private func verify() throws -> [String: Any] {
    let cache = FormatCache()
    let stable = try makeImage(638, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let inputs = [stable, stable,
        try makeImage(638, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, alignment: 256),
        try makeImage(1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        try makeImage(640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        try makeImage(640, 360, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, hdr: true),
        try makeImage(640, 360, kCVPixelFormatType_32BGRA), stable]
    var checks = 0
    var retained: [CMSampleBuffer] = []
    func compare(_ image: CVPixelBuffer, _ index: Int) throws {
        let cached = try cache.resolve(image, reuse: true)
        let fresh = try FormatCache().resolve(image, reuse: false)
        try require(CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: image), "match false")
        try require(CMFormatDescriptionGetMediaSubType(cached) == CMFormatDescriptionGetMediaSubType(fresh), "subtype differs")
        let a = CMVideoFormatDescriptionGetDimensions(cached), b = CMVideoFormatDescriptionGetDimensions(fresh)
        try require(a.width == b.width && a.height == b.height, "dimensions differ")
        let aExt = CMFormatDescriptionGetExtensions(cached), bExt = CMFormatDescriptionGetExtensions(fresh)
        if let aExt, let bExt { try require(CFEqual(aExt, bExt), "extensions differ") }
        else { try require(aExt == nil && bExt == nil, "missing extensions") }
        let next = try sample(image, cached, index)
        try require(CMSampleBufferGetPresentationTimeStamp(next) == CMTime(value: Int64(index), timescale: 60), "PTS differs")
        try require(CMSampleBufferGetImageBuffer(next) === image, "image owner differs")
        retained.append(next)
        checks += 6
    }
    for (index, image) in inputs.enumerated() { try compare(image, index) }
    let changed = try makeImage(638, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    try compare(changed, 8)
    CVBufferSetAttachment(changed, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    try compare(changed, 9)
    CVBufferRemoveAttachment(changed, kCVImageBufferColorPrimariesKey)
    try compare(changed, 10)
    cache.reset()
    let before = cache.creations
    try compare(changed, 11)
    try require(cache.creations == before + 1, "reset did not recreate")
    for (index, value) in retained.enumerated() {
        try require(CMSampleBufferGetPresentationTimeStamp(value).value == Int64(index), "retained sample changed")
        checks += 1
    }
    return ["mode": "verify", "checks": checks + 1, "format_creations": cache.creations, "format_hits": cache.hits]
}
private func measure(_ scenario: String, _ reuse: Bool, _ count: Int) throws -> [String: Any] {
    let format: OSType = scenario == "bgra" ? kCVPixelFormatType_32BGRA :
        scenario == "hdr10" ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let inputs = [try makeImage(1920, 1080, format, hdr: scenario == "hdr10"),
        try makeImage(1920, 1080, format, hdr: scenario == "hdr10" || scenario == "alternating-color")]
    let cache = FormatCache()
    // Equal warmup excludes first allocation/framework initialization in both variants.
    for index in 0..<100 {
        try autoreleasepool { withExtendedLifetime(try sample(inputs[index % 2], cache.resolve(inputs[index % 2], reuse: reuse), index)) {} }
    }
    cache.reset(); cache.hits = 0; cache.creations = 0
    let cpu = try nanos(CLOCK_PROCESS_CPUTIME_ID), start = try nanos(CLOCK_MONOTONIC_RAW)
    for index in 0..<count {
        try autoreleasepool {
            if scenario == "reset90", index % 90 == 0 { cache.reset() }
            let image = inputs[index % 2]
            let description = try cache.resolve(image, reuse: reuse)
            withExtendedLifetime(try sample(image, description, index)) {}
        }
    }
    let elapsed = try nanos(CLOCK_MONOTONIC_RAW) - start, work = try nanos(CLOCK_PROCESS_CPUTIME_ID) - cpu
    return ["mode": "measure", "scenario": scenario, "reuse": reuse, "frames": count,
        "wall_ns": elapsed, "cpu_ns": work, "format_creations": cache.creations, "format_hits": cache.hits,
        "row_bytes": CVPixelBufferGetBytesPerRow(inputs[0]), "pixel_format": format]
}
@main enum Main {
    static func main() throws {
        let args = CommandLine.arguments
        let result: [String: Any]
        if args.count == 2, args[1] == "verify" { result = try verify() }
        else if args.count == 5, ["420v", "bgra", "hdr10", "alternating-color", "reset90"].contains(args[1]),
                ["fresh", "reuse"].contains(args[2]), let count = Int(args[3]), (1...1_000_000).contains(count), args[4] == "measure" {
            result = try measure(args[1], args[2] == "reuse", count)
        } else { throw ProbeError(message: "usage: FormatProbe verify | scenario fresh|reuse count measure") }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
