import CoreGraphics
import Dispatch
import Foundation
import Metal
@testable import IlliquidNativePlayback

private enum HarnessError: Error { case usage, unavailable, mismatch(String) }

private struct Workload {
    let name: String
    let frames: [ASSPreparedSubtitleFrame]
    let configuration: MetalASSRenderConfiguration
    let targetSize = CGSize(width: 1_280, height: 720)

    init(name: String, seed: UInt64) throws {
        self.name = name
        let centered = name.hasSuffix("-centers")
        let prefix = centered ? String(name.dropLast("-centers".count)) : String(name.dropLast("-edges".count))
        guard centered || name.hasSuffix("-edges") else { throw HarnessError.usage }
        var config = MetalASSRenderConfiguration()
        config.textureCoordinates = centered ? .texelCenters : .rectangleEdges
        config.quadOffsetPixels = centered ? -0.5 : 0
        configuration = config
        let counts: [Int]
        if prefix == "varying" { counts = [1, 8, 64, 256, 8, 1] }
        else {
            guard prefix.hasPrefix("quads-"), let count = Int(prefix.dropFirst(6)),
                  [1, 8, 64, 256].contains(count) else { throw HarnessError.usage }
            counts = [count, count]
        }
        frames = counts.enumerated().map { frameIndex, count in
            let quads = (0..<count).map { index in
                let marker = UInt32(truncatingIfNeeded: seed &+ UInt64(index * 97 + frameIndex * 31))
                return ASSAtlasQuad(
                    source: CGRect(x: index % 16 * 16 + 1, y: index / 16 * 16 + 1,
                                   width: 10 + index % 3, height: 8 + index % 5),
                    destination: CGRect(x: Double(index % 16) * 83 + Double(frameIndex) / 4 - 3,
                                        y: Double(index / 16) * 45 + Double(index % 3) / 8,
                                        width: 20.25 + Double(index % 7), height: 16.5 + Double(index % 5)),
                    color: (marker &* 0x01010100) | UInt32((index + frameIndex) % 256))
            }
            return ASSPreparedSubtitleFrame(
                strategy: .metalR8Atlas, canvasSize: CGSize(width: 1_920, height: 1_080),
                textureSize: CGSize(width: 512, height: 512), bytesPerRow: 512,
                pixels: Data(), quads: quads,
                metrics: ASSCompositionMetrics(imageCount: count, copiedBytes: 0, uploadBytes: 0, drawCalls: 1))
        }
    }
}

private func oracle(_ frame: ASSPreparedSubtitleFrame, configuration: MetalASSRenderConfiguration,
                    targetSize: CGSize, textureWidth: Int, textureHeight: Int) -> [VertexUploadRecord] {
    var output: [VertexUploadRecord] = []
    let inset: Float = configuration.textureCoordinates == .texelCenters ? 0.5 : 0
    let xOffset = configuration.quadOffsetPixels * Float(frame.canvasSize.width / max(targetSize.width, 1))
    let yOffset = configuration.quadOffsetPixels * Float(frame.canvasSize.height / max(targetSize.height, 1))
    // Describe the two triangles by corner coordinates independently of the
    // writer's six explicit stores and the baseline's array concatenation.
    let corners = [(false, false), (false, true), (true, false),
                   (true, false), (false, true), (true, true)]
    for quad in frame.quads {
        for (right, bottom) in corners {
            let x = Float(right ? quad.destination.maxX : quad.destination.minX) + xOffset
            let y = Float(bottom ? quad.destination.maxY : quad.destination.minY) + yOffset
            let u = (Float(right ? quad.source.maxX : quad.source.minX) + (right ? -inset : inset))
                / Float(textureWidth)
            let v = (Float(bottom ? quad.source.maxY : quad.source.minY) + (bottom ? -inset : inset))
                / Float(textureHeight)
            let rgba = (quad.color & 0xffffff00) | (255 - (quad.color & 0xff))
            output.append(VertexUploadRecord(x: x.bitPattern, y: y.bitPattern,
                                            u: u.bitPattern, v: v.bitPattern, rgba: rgba))
        }
    }
    return output
}

private func digest(_ record: VertexUploadRecord, count: Int) -> UInt64 {
    UInt64(record.x) &+ UInt64(record.y) &+ UInt64(record.u)
        &+ UInt64(record.v) &+ UInt64(record.rgba) &+ UInt64(count)
}

private struct Receipt: Encodable, Equatable {
    let records: [[VertexUploadRecord]]
    let capacities: [Int]
    let vertexStride: Int
}

@MainActor
private func verify(_ encoder: VertexUploadHarness, workload: Workload, texture: any MTLTexture) throws -> Receipt {
    var records: [[VertexUploadRecord]] = []
    var capacities: [Int] = []
    for frame in workload.frames {
        let checksum = encoder.encode(frame, texture: texture, targetSize: workload.targetSize)
        let actual = encoder.records(count: frame.quads.count * 6)
        let expected = oracle(frame, configuration: workload.configuration,
                              targetSize: workload.targetSize,
                              textureWidth: texture.width, textureHeight: texture.height)
        guard actual == expected, let last = expected.last,
              checksum == digest(last, count: expected.count) else {
            throw HarnessError.mismatch("vertex fields or upload checksum")
        }
        records.append(actual)
        capacities.append(encoder.capacity)
    }
    return Receipt(records: records, capacities: capacities, vertexStride: encoder.vertexStride)
}

@MainActor @inline(never)
private func exercise(_ encoder: VertexUploadHarness, workload: Workload,
                      texture: any MTLTexture, iterations: Int) -> UInt64 {
    var checksum: UInt64 = 0
    for _ in 0..<iterations {
        for frame in workload.frames {
            checksum &+= encoder.encode(frame, texture: texture, targetSize: workload.targetSize)
        }
    }
    return checksum
}

private struct Output: Encodable {
    let name: String
    let iterations: Int
    let seed: UInt64
    let elapsedNanoseconds: UInt64
    let operationsPerIteration: Int
    let checksum: String
    let receipt: Receipt
    let stagedPayloadBytesPerIteration: Int

    enum CodingKeys: String, CodingKey {
        case name = "case"
        case iterations, seed, checksum, receipt
        case elapsedNanoseconds = "elapsed_ns"
        case operationsPerIteration = "operations_per_iteration"
        case stagedPayloadBytesPerIteration = "vertex_payload_bytes_per_iteration"
    }
}

@main
private enum Driver {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, let iterations = Int(args[2]), iterations > 0,
              let seed = UInt64(args[3]) else { throw HarnessError.usage }
        let workload = try Workload(name: args[1], seed: seed)
        guard let device = MTLCreateSystemDefaultDevice() else { throw HarnessError.unavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 512, height: 512, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw HarnessError.unavailable }
        let encoder = VertexUploadHarness(device: device, configuration: workload.configuration)
        _ = try verify(encoder, workload: workload, texture: texture)
        _ = exercise(encoder, workload: workload, texture: texture, iterations: 100)
        let initial = try verify(encoder, workload: workload, texture: texture)
        let perIteration = initial.records.reduce(UInt64(0)) {
            $0 &+ digest($1.last!, count: $1.count)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = exercise(encoder, workload: workload, texture: texture, iterations: iterations)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        guard checksum == perIteration &* UInt64(iterations) else { throw HarnessError.mismatch("timed checksum") }
        let final = try verify(encoder, workload: workload, texture: texture)
        guard final == initial else { throw HarnessError.mismatch("buffer reuse") }
        let output = Output(name: workload.name, iterations: iterations, seed: seed,
                            elapsedNanoseconds: elapsed, operationsPerIteration: workload.frames.count,
                            checksum: String(checksum), receipt: final,
                            stagedPayloadBytesPerIteration: workload.frames.reduce(0) {
                                $0 + $1.quads.count * 6 * encoder.vertexStride
                            })
        let json = JSONEncoder()
        json.outputFormatting = [.sortedKeys]
        print(String(decoding: try json.encode(output), as: UTF8.self))
    }
}
