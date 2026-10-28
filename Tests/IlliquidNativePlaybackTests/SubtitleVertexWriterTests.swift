import CoreGraphics
import Foundation
import Testing
@testable import IlliquidNativePlayback

@Suite("Subtitle vertex writer")
struct SubtitleVertexWriterTests {
    private typealias Vertex = ASSSubtitleVertexWriter.Vertex
    private static let guardBytes = 64
    private static let sentinel: UInt8 = 0xa5

    @Test func layoutMatchesTheMetalVertexDescriptor() {
        #expect(MemoryLayout<Vertex>.offset(of: \.position) == 0)
        #expect(MemoryLayout<Vertex>.offset(of: \.textureCoordinate) == 8)
        #expect(MemoryLayout<Vertex>.offset(of: \.color) == 16)
        #expect(MemoryLayout<Vertex>.size == 20)
        #expect(MemoryLayout<Vertex>.stride == 24)
    }

    @Test func emptyFrameAcceptsAnEmptyDestination() {
        ASSSubtitleVertexWriter.write(
            Self.frame(count: 0),
            textureWidth: 1,
            textureHeight: 1,
            targetSize: .zero,
            configuration: .production,
            into: UnsafeMutableRawBufferPointer(start: nil, count: 0)
        )
    }

    @Test(arguments: [0, 1, 8, 256])
    func writtenFieldsMatchLegacyArrayConstruction(count: Int) {
        let required = count * 6 * MemoryLayout<Vertex>.stride
        let allocationSize = required + 2 * Self.guardBytes
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: max(Self.guardBytes, MemoryLayout<Vertex>.alignment)
        )
        defer { storage.deallocate() }
        let destination = UnsafeMutableRawBufferPointer(
            start: storage.advanced(by: Self.guardBytes), count: required
        )
        let targetSizes: [CGSize] = [
            .init(width: 1920, height: 1080),
            .init(width: 3840, height: 2160),
            .init(width: 853, height: 481),
        ]
        let modes: [MetalASSTextureCoordinateMode] = [.rectangleEdges, .texelCenters]
        for strategy in [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA] {
            let frame = Self.frame(count: count, strategy: strategy)
            for mode in modes {
                for offset in [Float(-0.5), 0, 0.5] {
                    let configuration = MetalASSRenderConfiguration(
                        textureCoordinates: mode, quadOffsetPixels: offset
                    )
                    for targetSize in targetSizes {
                        Self.fillSentinel(storage, count: allocationSize)
                        // A pooled texture can exceed the current frame's
                        // textureSize (96 by 64 in this fixture).
                        ASSSubtitleVertexWriter.write(
                            frame, textureWidth: 513, textureHeight: 257,
                            targetSize: targetSize, configuration: configuration, into: destination
                        )
                        Self.expectVertices(destination, equalTo: Self.legacyVertices(
                            frame, textureWidth: 513, textureHeight: 257,
                            targetSize: targetSize, configuration: configuration
                        ))
                        let bytes = UnsafeRawBufferPointer(start: storage, count: allocationSize)
                        #expect(bytes[..<Self.guardBytes].allSatisfy { $0 == Self.sentinel })
                        #expect(bytes[(Self.guardBytes + required)...].allSatisfy { $0 == Self.sentinel })
                    }
                }
            }
        }
    }

    @Test func repeatedLargerSmallerAndEmptyWritesPreserveUnusedStorage() {
        let capacity = 256 * 6 * MemoryLayout<Vertex>.stride
        let allocationSize = capacity + 2 * Self.guardBytes
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: allocationSize,
            alignment: max(Self.guardBytes, MemoryLayout<Vertex>.alignment)
        )
        defer { storage.deallocate() }
        Self.fillSentinel(storage, count: allocationSize)
        let destination = UnsafeMutableRawBufferPointer(
            start: storage.advanced(by: Self.guardBytes), count: capacity
        )
        for (phase, count) in [0, 1, 8, 256, 8, 1, 0, 256].enumerated() {
            let frame = Self.frame(count: count, phase: phase)
            let required = count * 6 * MemoryLayout<Vertex>.stride
            let tailStart = Self.guardBytes + required
            let tailBefore = Data(bytes: storage.advanced(by: tailStart), count: allocationSize - tailStart)
            let configuration = MetalASSRenderConfiguration(
                textureCoordinates: phase.isMultiple(of: 2) ? .rectangleEdges : .texelCenters,
                quadOffsetPixels: phase.isMultiple(of: 2) ? -0.5 : 0.5
            )
            let targetSize = CGSize(width: 1280, height: 720)
            ASSSubtitleVertexWriter.write(
                frame, textureWidth: 1024, textureHeight: 512,
                targetSize: targetSize, configuration: configuration, into: destination
            )
            Self.expectVertices(destination, equalTo: Self.legacyVertices(
                frame, textureWidth: 1024, textureHeight: 512,
                targetSize: targetSize, configuration: configuration
            ))
            let tailAfter = Data(bytes: storage.advanced(by: tailStart), count: allocationSize - tailStart)
            #expect(tailAfter == tailBefore)
            let prefix = UnsafeRawBufferPointer(start: storage, count: Self.guardBytes)
            #expect(prefix.allSatisfy { $0 == Self.sentinel })
        }
    }

    private static func fillSentinel(_ storage: UnsafeMutableRawPointer, count: Int) {
        // Raw stores leave the allocation unbound for the trivial vertex writes.
        for offset in 0..<count {
            storage.storeBytes(of: sentinel, toByteOffset: offset, as: UInt8.self)
        }
    }

    private static func expectVertices(_ bytes: UnsafeMutableRawBufferPointer, equalTo expected: [Vertex]) {
        for (index, expectedVertex) in expected.enumerated() {
            let actual = bytes.load(fromByteOffset: index * MemoryLayout<Vertex>.stride, as: Vertex.self)
            // SIMD fields are compared exactly; struct padding is not data.
            for lane in 0..<2 {
                #expect(actual.position[lane].bitPattern == expectedVertex.position[lane].bitPattern)
                #expect(actual.textureCoordinate[lane].bitPattern == expectedVertex.textureCoordinate[lane].bitPattern)
            }
            #expect(actual.color == expectedVertex.color)
        }
    }

    private static func frame(
        count: Int, phase: Int = 0,
        strategy: SubtitleCompositionStrategy = .metalR8Atlas
    ) -> ASSPreparedSubtitleFrame {
        let colors: [UInt32] = [
            0xff000000, 0x00ff00ff, 0x12345680, 0x00ffffff, 0xffffffff,
        ]
        let quads = (0..<count).map { index in
            ASSAtlasQuad(
                source: CGRect(
                    x: CGFloat(index % 23) * 2 + 1, y: CGFloat(index % 13) + 2,
                    width: CGFloat(index % 7 + 1), height: CGFloat(index % 5 + 1)
                ),
                destination: CGRect(
                    x: CGFloat(index % 17) * 7.25 - 6.5, y: CGFloat(index % 11) * 5.5 - 2.25,
                    width: CGFloat(index % 7 + 1) * 1.5, height: CGFloat(index % 5 + 1) * 0.75
                ),
                color: colors[(index + phase) % colors.count]
            )
        }
        return ASSPreparedSubtitleFrame(
            strategy: strategy, canvasSize: CGSize(width: 1920, height: 1080),
            textureSize: CGSize(width: 96, height: 64), bytesPerRow: 96,
            pixels: Data(), quads: quads,
            metrics: ASSCompositionMetrics(
                imageCount: count, copiedBytes: 0, uploadBytes: 0, drawCalls: count == 0 ? 0 : 1
            )
        )
    }

    /// Preserve the old array-building algorithm as the storage-independent
    /// reference; keep its per-quad arithmetic and triangle ordering unchanged.
    private static func legacyVertices(
        _ frame: ASSPreparedSubtitleFrame, textureWidth: Int, textureHeight: Int,
        targetSize: CGSize, configuration: MetalASSRenderConfiguration
    ) -> [Vertex] {
        var result: [Vertex] = []
        result.reserveCapacity(frame.quads.count * 6)
        for quad in frame.quads {
            let color = SIMD4<UInt8>(
                UInt8((quad.color >> 24) & 0xff),
                UInt8((quad.color >> 16) & 0xff),
                UInt8((quad.color >> 8) & 0xff),
                255 - UInt8(quad.color & 0xff)
            )
            let xOffset = configuration.quadOffsetPixels
                * Float(frame.canvasSize.width / max(targetSize.width, 1))
            let yOffset = configuration.quadOffsetPixels
                * Float(frame.canvasSize.height / max(targetSize.height, 1))
            let x0 = Float(quad.destination.minX) + xOffset
            let y0 = Float(quad.destination.minY) + yOffset
            let x1 = Float(quad.destination.maxX) + xOffset
            let y1 = Float(quad.destination.maxY) + yOffset
            let inset: Float = configuration.textureCoordinates == .texelCenters ? 0.5 : 0
            let u0 = (Float(quad.source.minX) + inset) / Float(textureWidth)
            let v0 = (Float(quad.source.minY) + inset) / Float(textureHeight)
            let u1 = (Float(quad.source.maxX) - inset) / Float(textureWidth)
            let v1 = (Float(quad.source.maxY) - inset) / Float(textureHeight)
            let topLeft = Vertex(position: SIMD2(x0, y0), textureCoordinate: SIMD2(u0, v0), color: color)
            let bottomLeft = Vertex(position: SIMD2(x0, y1), textureCoordinate: SIMD2(u0, v1), color: color)
            let topRight = Vertex(position: SIMD2(x1, y0), textureCoordinate: SIMD2(u1, v0), color: color)
            let bottomRight = Vertex(position: SIMD2(x1, y1), textureCoordinate: SIMD2(u1, v1), color: color)
            result += [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
        }
        return result
    }
}
