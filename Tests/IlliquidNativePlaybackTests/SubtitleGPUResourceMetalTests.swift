import CoreGraphics
import CryptoKit
import Foundation
import Metal
import QuartzCore
import Testing
@testable import IlliquidNativePlayback

/// Exercises real Metal allocations while keeping the rendered target small.
/// The receipt measures idle pool-owned MTLResource.allocatedSize values; it is
/// not an RSS, physical-footprint, or driver-reclamation measurement.
@Suite("Subtitle GPU source resource retirement", .serialized)
struct SubtitleGPUResourceMetalTests {
    @Test(arguments: [
        SubtitleCompositionStrategy.metalR8Atlas,
        SubtitleCompositionStrategy.metalBGRA,
    ])
    @MainActor
    func sourceRetirementReleasesIdleResourcesAndPreservesPixels(
        strategy: SubtitleCompositionStrategy
    ) throws {
        let layer = CAMetalLayer()
        // A missing device or pipeline is a test failure, never a passing skip.
        let renderer = try MetalASSSubtitleRenderer(layer: layer)
        let device = try #require(layer.device)

        @MainActor func memoryReading() -> MemoryReading {
            let value = renderer.resourcePoolSnapshotForTesting
            return MemoryReading(
                sourceGeneration: value.sourceGeneration,
                idleResourceCount: value.idleResourceCount,
                idleTextureBytes: value.idleTextureBytes,
                idleVertexBufferBytes: value.idleVertexBufferBytes
            )
        }

        let initial = memoryReading()
        #expect(initial.idleResourceCount == 0)
        #expect(initial.idleTextureBytes == 0)
        #expect(initial.idleVertexBufferBytes == 0)

        let large = Self.makeFrame(strategy: strategy, dimension: 2_048, tiles: 16)
        let largePixels = try #require(renderer.renderOffscreen(large))
        #expect(largePixels.count == 64 * 64 * 4)
        #expect(largePixels.contains { $0 != 0 })
        let populated = memoryReading()
        #expect(populated.sourceGeneration == initial.sourceGeneration)
        #expect(populated.idleResourceCount == 1)
        #expect(populated.idleTextureBytes > 0)
        #expect(populated.idleVertexBufferBytes > 4_096)

        // A normal subtitle gap clears the output without discarding capacity.
        let blankPixels = try #require(renderer.renderOffscreen(Self.emptyFrame(
            strategy: strategy
        )))
        #expect(blankPixels.count == largePixels.count)
        #expect(blankPixels.allSatisfy { $0 == 0 })
        let afterOrdinaryBlank = memoryReading()
        #expect(afterOrdinaryBlank == populated)

        // A small frame from the same source also preserves grow-only reuse.
        // Its rendered bytes are retained as an independent reuse-path control.
        let small = Self.makeFrame(strategy: strategy, dimension: 32, tiles: 1)
        let warmSmallPixels = try #require(renderer.renderOffscreen(small))
        #expect(warmSmallPixels.contains { $0 != 0 })
        let smallInSameSource = memoryReading()
        #expect(smallInSameSource == populated)

        renderer.retireSourceResources()
        let retired = memoryReading()
        #expect(retired.sourceGeneration == (populated.sourceGeneration &+ 1))
        #expect(retired.idleResourceCount == 0)
        #expect(retired.idleTextureBytes == 0)
        #expect(retired.idleVertexBufferBytes == 0)

        // Rebuilding after retirement must preserve every output byte.
        let rebuiltPixels = try #require(renderer.renderOffscreen(large))
        #expect(rebuiltPixels == largePixels)
        let rebuilt = memoryReading()
        #expect(rebuilt.sourceGeneration == retired.sourceGeneration)
        #expect(rebuilt.idleResourceCount == 1)
        #expect(rebuilt.idleTextureBytes > 0)
        #expect(rebuilt.idleVertexBufferBytes > 4_096)

        renderer.retireSourceResources()
        let retiredAgain = memoryReading()
        #expect(retiredAgain.sourceGeneration == (retired.sourceGeneration &+ 1))
        #expect(retiredAgain.idleResourceCount == 0)
        #expect(retiredAgain.idleTextureBytes == 0)
        #expect(retiredAgain.idleVertexBufferBytes == 0)

        // The next source can start small instead of inheriting the old peak.
        let freshSmallPixels = try #require(renderer.renderOffscreen(small))
        #expect(freshSmallPixels == warmSmallPixels)
        let nextSmallSource = memoryReading()
        #expect(nextSmallSource.sourceGeneration == retiredAgain.sourceGeneration)
        #expect(nextSmallSource.idleResourceCount == 1)
        #expect(nextSmallSource.idleTextureBytes > 0)
        #expect(nextSmallSource.idleTextureBytes < populated.idleTextureBytes)
        #expect(nextSmallSource.idleVertexBufferBytes > 0)
        #expect(nextSmallSource.idleVertexBufferBytes < populated.idleVertexBufferBytes)

        let nextBlank = try #require(renderer.renderOffscreen(Self.emptyFrame(
            strategy: strategy
        )))
        #expect(nextBlank.allSatisfy { $0 == 0 })
        #expect(memoryReading() == nextSmallSource)
        renderer.retireSourceResources()
        let finalRetired = memoryReading()
        #expect(finalRetired.idleResourceCount == 0)
        #expect(finalRetired.idleTextureBytes == 0)
        #expect(finalRetired.idleVertexBufferBytes == 0)
        #expect(renderer.failureEvents == 0)
        #expect(renderer.commandBufferFailures == 0)
        #expect(renderer.textureAllocationFailures == 0)
        #expect(renderer.bufferAllocationFailures == 0)

        let receipt = Receipt(
            schemaVersion: 1,
            scenario: "completed-source-retirement",
            format: strategy == .metalR8Atlas ? "r8-unorm" : "premultiplied-bgra-atlas",
            metalDevice: device.name,
            textureDimension: 2_048,
            uploadedPixelBytes: large.pixels.count,
            quadCount: large.quads.count,
            outputByteCount: largePixels.count,
            outputSHA256: Self.digest(largePixels),
            rebuiltOutputSHA256: Self.digest(rebuiltPixels),
            smallOutputSHA256: Self.digest(warmSmallPixels),
            freshSmallOutputSHA256: Self.digest(freshSmallPixels),
            populated: populated,
            ordinaryBlank: afterOrdinaryBlank,
            smallInSameSource: smallInSameSource,
            retired: retired,
            rebuilt: rebuilt,
            retiredAgain: retiredAgain,
            nextSmallSource: nextSmallSource,
            finalRetired: finalRetired
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(receipt)
        print("SUBTITLE_GPU_MEMORY:" + String(decoding: encoded, as: UTF8.self))
    }

    private static func makeFrame(
        strategy: SubtitleCompositionStrategy,
        dimension: Int,
        tiles: Int
    ) -> ASSPreparedSubtitleFrame {
        precondition(dimension > 0 && tiles > 0 && dimension.isMultiple(of: tiles))
        let bytesPerPixel = strategy == .metalR8Atlas ? 1 : 4
        let bytesPerRow = dimension * bytesPerPixel
        let tileDimension = dimension / tiles
        precondition(tileDimension > 2)
        var pixels = Data(count: dimension * bytesPerRow)

        // Alternate opaque BGRA colors and R8 coverages in full atlas bands.
        // Rows are copied without assuming Data's pointer alignment.
        func row(band: Int) -> Data {
            if strategy == .metalR8Atlas {
                return Data(repeating: band == 0 ? 96 : 255, count: dimension)
            }
            let color: [UInt8] = band == 0 ? [24, 64, 192, 255] : [192, 128, 16, 255]
            var bytes: [UInt8] = []
            bytes.reserveCapacity(bytesPerRow)
            for _ in 0..<dimension { bytes.append(contentsOf: color) }
            return Data(bytes)
        }
        let evenRow = row(band: 0)
        let oddRow = row(band: 1)
        pixels.withUnsafeMutableBytes { destination in
            evenRow.withUnsafeBytes { even in
                oddRow.withUnsafeBytes { odd in
                    for y in 0..<dimension {
                        let source = (y / tileDimension).isMultiple(of: 2) ? even : odd
                        destination.baseAddress!.advanced(by: y * bytesPerRow)
                            .copyMemory(from: source.baseAddress!, byteCount: bytesPerRow)
                    }
                }
            }
        }

        let cell = 64.0 / Double(tiles)
        var quads: [ASSAtlasQuad] = []
        quads.reserveCapacity(tiles * tiles)
        for y in 0..<tiles {
            for x in 0..<tiles {
                let red = UInt32(64 + (x * 11) % 192)
                let green = UInt32(64 + (y * 13) % 192)
                let blue = UInt32(64 + ((x + y) * 7) % 192)
                quads.append(ASSAtlasQuad(
                    // The constant band supplies a one-texel padding border.
                    // Small uploads must not sample stale pixels outside their
                    // active rectangle when reusing a larger texture.
                    source: CGRect(
                        x: x * tileDimension + 1, y: y * tileDimension + 1,
                        width: tileDimension - 2, height: tileDimension - 2
                    ),
                    destination: CGRect(
                        x: Double(x) * cell, y: Double(y) * cell,
                        width: cell, height: cell
                    ),
                    color: (red << 24) | (green << 16) | (blue << 8)
                ))
            }
        }

        return ASSPreparedSubtitleFrame(
            strategy: strategy,
            canvasSize: CGSize(width: 64, height: 64),
            textureSize: CGSize(width: dimension, height: dimension),
            bytesPerRow: bytesPerRow,
            pixels: pixels,
            quads: quads,
            metrics: ASSCompositionMetrics(
                imageCount: quads.count, copiedBytes: pixels.count,
                uploadBytes: pixels.count, drawCalls: 1,
                atlasWidth: dimension, atlasHeight: dimension
            ),
            usesBitmapAtlas: strategy == .metalBGRA
        )
    }

    private static func emptyFrame(
        strategy: SubtitleCompositionStrategy
    ) -> ASSPreparedSubtitleFrame {
        ASSPreparedSubtitleFrame(
            strategy: strategy,
            canvasSize: CGSize(width: 64, height: 64),
            textureSize: .zero,
            bytesPerRow: 0,
            pixels: Data(),
            quads: [],
            metrics: ASSCompositionMetrics(
                imageCount: 0, copiedBytes: 0, uploadBytes: 0, drawCalls: 1
            )
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct MemoryReading: Codable, Equatable {
        let sourceGeneration: UInt64
        let idleResourceCount: Int
        let idleTextureBytes: Int
        let idleVertexBufferBytes: Int
    }

    private struct Receipt: Codable {
        let schemaVersion: Int
        let scenario: String
        let format: String
        let metalDevice: String
        let textureDimension: Int
        let uploadedPixelBytes: Int
        let quadCount: Int
        let outputByteCount: Int
        let outputSHA256: String
        let rebuiltOutputSHA256: String
        let smallOutputSHA256: String
        let freshSmallOutputSHA256: String
        let populated: MemoryReading
        let ordinaryBlank: MemoryReading
        let smallInSameSource: MemoryReading
        let retired: MemoryReading
        let rebuilt: MemoryReading
        let retiredAgain: MemoryReading
        let nextSmallSource: MemoryReading
        let finalRetired: MemoryReading
    }
}
