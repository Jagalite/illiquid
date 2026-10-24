import CoreVideo
import Darwin
import Foundation
@testable import IlliquidNativePlayback

private struct Geometry: Sendable {
    var aspect = CGSize(width: 1, height: 1)
    var width = 1_920
    var height = 1_080
    var horizontal = 0.0
    var vertical = 0.0
}

private struct Workload: Sendable {
    let name: String
    let codedWidth: Int
    let codedHeight: Int
    let bufferCount: Int
    let geometry: [Geometry]
    var clearsBeforeApply = false
}

private let workloads: [Workload] = {
    let square = Geometry()
    let anamorphic = Geometry(aspect: CGSize(width: 16, height: 15), width: 720, height: 576)
    let cropped = Geometry(width: 1_920, height: 800)
    let uhd = Geometry(width: 3_840, height: 2_160)
    return [
        Workload(name: "stable-square", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 1, geometry: [square]),
        Workload(name: "stable-anamorphic", codedWidth: 720, codedHeight: 576, bufferCount: 1, geometry: [anamorphic]),
        Workload(name: "stable-cropped", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 1, geometry: [cropped]),
        Workload(name: "stable-4k", codedWidth: 3_840, codedHeight: 2_160, bufferCount: 1, geometry: [uhd]),
        Workload(name: "rotating-square", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 8, geometry: [square]),
        Workload(name: "rotating-anamorphic", codedWidth: 720, codedHeight: 576, bufferCount: 8, geometry: [anamorphic]),
        Workload(name: "rotating-cleared", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 8,
                 geometry: [square], clearsBeforeApply: true),
        Workload(name: "alternating-aspect", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 3,
                 geometry: [square, Geometry(aspect: CGSize(width: 4, height: 3))]),
        Workload(name: "alternating-aperture", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 3,
                 geometry: [square, Geometry(width: 1_918, height: 1_078, horizontal: 1, vertical: -1)]),
        Workload(name: "alternating-both", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 3,
                 geometry: [square, Geometry(aspect: CGSize(width: 4, height: 3), width: 1_918,
                                             height: 1_078, horizontal: -1, vertical: 1)]),
        Workload(name: "invalid-aspect", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 3,
                 geometry: [Geometry(aspect: CGSize(width: 0, height: 1)),
                            Geometry(aspect: CGSize(width: CGFloat.nan, height: 1)),
                            Geometry(aspect: CGSize(width: 1, height: CGFloat.infinity)),
                            Geometry(aspect: CGSize(width: -1, height: 1))]),
        Workload(name: "rounding-and-signed-zero", codedWidth: 1_920, codedHeight: 1_080, bufferCount: 3,
                 geometry: [Geometry(aspect: CGSize(width: 1.49, height: 1.49), horizontal: -0.0),
                            Geometry(aspect: CGSize(width: 1.5, height: 2.5), vertical: -0.0),
                            square]),
    ]
}()

private func attachment(_ buffer: CVPixelBuffer, key: CFString) throws -> [String: Any] {
    var mode = CVAttachmentMode.shouldNotPropagate
    guard let value = CVBufferCopyAttachment(buffer, key, &mode) else { return ["present": false] }
    guard let dictionary = value as? [String: NSNumber] else {
        throw NSError(domain: "GeometryBenchmark", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected attachment type for \(key)"])
    }
    let fields = dictionary.keys.sorted().map { name -> [String: Any] in
        let number = dictionary[name]!
        return ["name": name, "objc_type": String(cString: number.objCType),
                "double_bits": String(number.doubleValue.bitPattern, radix: 16),
                "integer": String(number.int64Value)]
    }
    return ["present": true, "mode": Int(mode.rawValue), "fields": fields]
}

private func snapshot(_ buffer: CVPixelBuffer) throws -> [String: Any] {
    ["pixel_aspect": try attachment(buffer, key: kCVImageBufferPixelAspectRatioKey),
     "clean_aperture": try attachment(buffer, key: kCVImageBufferCleanApertureKey)]
}

private func encoded(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private final class Session {
    let workload: Workload
    let cache = VideoGeometryMetadataCache()
    let buffers: [CVPixelBuffer]

    init(_ workload: Workload) throws {
        self.workload = workload
        buffers = try (0..<workload.bufferCount).map { _ in
            var result: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, workload.codedWidth, workload.codedHeight,
                                            kCVPixelFormatType_32BGRA, nil, &result)
            guard status == kCVReturnSuccess, let result else {
                throw NSError(domain: "CoreVideo", code: Int(status))
            }
            // Invalid aspect input must preserve an existing attachment and its mode.
            let seeded: [CFString: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 9,
                                         kCVImageBufferPixelAspectRatioVerticalSpacingKey: 7]
            CVBufferSetAttachment(result, kCVImageBufferPixelAspectRatioKey, seeded as CFDictionary,
                                  .shouldNotPropagate)
            return result
        }
    }

    @inline(never)
    func apply(_ index: Int) {
        let geometry = workload.geometry[index % workload.geometry.count]
        let buffer = buffers[index % buffers.count]
        if workload.clearsBeforeApply {
            // Planar pool checkout clears these before each frame's metadata is applied.
            CVBufferRemoveAttachment(buffer, kCVImageBufferPixelAspectRatioKey)
            CVBufferRemoveAttachment(buffer, kCVImageBufferCleanApertureKey)
        }
        cache.applyPixelAspectMetadata(pixelBuffer: buffer, pixelAspect: geometry.aspect)
        cache.applyCleanApertureMetadata(pixelBuffer: buffer, width: geometry.width, height: geometry.height,
                                        horizontalOffset: geometry.horizontal, verticalOffset: geometry.vertical)
    }

    @inline(never)
    func run(_ iterations: Int) {
        for index in 0..<iterations { apply(index) }
    }

    func checksum() throws -> String {
        let data = try encoded(buffers.map { try snapshot($0) })
        var value: UInt64 = 0xcbf29ce484222325
        for byte in data { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return String(value, radix: 16)
    }

    func receipts() throws -> [String: Any] {
        var steps: [[String: Any]] = []
        for index in 0..<32 {
            apply(index)
            steps.append(["step": index, "buffer": index % buffers.count,
                          "attachments": try snapshot(buffers[index % buffers.count])])
        }
        return ["workload": workload.name, "buffer_count": buffers.count,
                "coded_width": workload.codedWidth, "coded_height": workload.codedHeight,
                "clears_before_apply": workload.clearsBeforeApply,
                "steps": steps, "final_buffers": try buffers.map { try snapshot($0) }]
    }
}

private func cpuNanoseconds() -> UInt64 {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000
        + UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1_000
}

@main
private enum Main {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let output: Any
        if arguments == ["list"] {
            output = workloads.map(\.name)
        } else if arguments == ["outputs"] {
            output = try workloads.map { try Session($0).receipts() }
        } else if arguments.count == 3, arguments[0] == "bench",
                  let workload = workloads.first(where: { $0.name == arguments[1] }),
                  let iterations = Int(arguments[2]), iterations > 0 {
            let session = try Session(workload)
            session.run(256)
            let cpuStart = cpuNanoseconds()
            let start = DispatchTime.now().uptimeNanoseconds
            session.run(iterations)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let cpu = cpuNanoseconds() - cpuStart
            // Observe the real CoreVideo attachment output outside the timed loop.
            output = ["workload": workload.name, "iterations": iterations,
                      "elapsed_ns": elapsed, "cpu_ns": cpu,
                      "checksum": try session.checksum(), "warmup_operations": 256,
                      "clears_before_apply": workload.clearsBeforeApply,
                      "buffer_count": workload.bufferCount] as [String: Any]
        } else {
            throw NSError(domain: "GeometryBenchmark", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: Harness list|outputs|bench WORKLOAD ITERATIONS"])
        }
        FileHandle.standardOutput.write(try encoded(output))
        FileHandle.standardOutput.write(Data([10]))
    }
}
