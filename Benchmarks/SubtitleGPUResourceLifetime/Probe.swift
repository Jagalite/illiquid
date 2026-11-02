import CoreGraphics
import CryptoKit
import Foundation
import QuartzCore
@testable import IlliquidNativePlayback

@main
struct SubtitleGPUMemoryProbe {
    @MainActor
    static func main() throws {
        var rows: [[String: Any]] = []
        for strategy in [SubtitleCompositionStrategy.metalR8Atlas, .metalBGRA] {
            let renderer = try MetalASSSubtitleRenderer(layer: CAMetalLayer())
            let large = frame(strategy: strategy, side: 2_048, quadCount: 256)
            let small = frame(strategy: strategy, side: 32, quadCount: 1)
            let empty = ASSPreparedSubtitleFrame(
                strategy: strategy, canvasSize: CGSize(width: 64, height: 64),
                textureSize: .zero, bytesPerRow: 0, pixels: Data(), quads: [],
                metrics: ASSCompositionMetrics(imageCount: 0, copiedBytes: 0, uploadBytes: 0, drawCalls: 1)
            )
            guard let initial = renderer.renderOffscreen(large),
                  initial.contains(where: { $0 != 0 }) else {
                throw ProbeError.invalidOutput
            }
            let before = renderer.resourcePoolSnapshotForTesting
            guard let cleared = renderer.renderOffscreen(empty),
                  cleared.allSatisfy({ $0 == 0 }) else {
                throw ProbeError.invalidOutput
            }
            let gap = renderer.resourcePoolSnapshotForTesting
            renderer.retireSourceResources()
            let retired = renderer.resourcePoolSnapshotForTesting
            guard let rebuilt = renderer.renderOffscreen(large), rebuilt == initial else {
                throw ProbeError.pixelMismatch
            }
            renderer.retireSourceResources()
            guard let following = renderer.renderOffscreen(small),
                  following.contains(where: { $0 != 0 }) else {
                throw ProbeError.invalidOutput
            }
            let next = renderer.resourcePoolSnapshotForTesting
            rows.append([
                "format": strategy.rawValue,
                "atlas_width": 2_048,
                "atlas_height": 2_048,
                "quad_count": 256,
                "before": snapshot(before),
                "ordinary_gap": snapshot(gap),
                "retired": snapshot(retired),
                "following_small_source": snapshot(next),
                "initial_pixels_sha256": digest(initial),
                "rebuilt_pixels_sha256": digest(rebuilt),
                "following_pixels_sha256": digest(following),
                "pixel_bytes": initial.count,
                "command_buffers_submitted": renderer.commandBuffersSubmitted,
            ])
        }
        let result = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: result, as: UTF8.self))
    }

    private enum ProbeError: Error {
        case invalidOutput
        case pixelMismatch
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private static func snapshot(_ value: MetalASSSubtitleRenderer.ResourcePool.Snapshot) -> [String: Any] {
        [
            "generation": value.sourceGeneration,
            "idle_resources": value.idleResourceCount,
            "texture_allocated_bytes": value.idleTextureBytes,
            "vertex_buffer_allocated_bytes": value.idleVertexBufferBytes,
        ]
    }

    private static func frame(
        strategy: SubtitleCompositionStrategy, side: Int, quadCount: Int
    ) -> ASSPreparedSubtitleFrame {
        let channels = strategy == .metalR8Atlas ? 1 : 4
        let pixels = Data(repeating: 255, count: side * side * channels)
        let columns = quadCount == 1 ? 1 : 16
        let cell = 64 / columns
        let quads = (0..<quadCount).map { index in
            ASSAtlasQuad(
                source: CGRect(x: 1, y: 1, width: side - 2, height: side - 2),
                destination: CGRect(
                    x: (index % columns) * cell, y: (index / columns) * cell,
                    width: cell, height: cell
                ),
                color: 0xFFFFFF00
            )
        }
        return ASSPreparedSubtitleFrame(
            strategy: strategy, canvasSize: CGSize(width: 64, height: 64),
            textureSize: CGSize(width: side, height: side),
            bytesPerRow: side * channels, pixels: pixels, quads: quads,
            metrics: ASSCompositionMetrics(
                imageCount: quadCount, copiedBytes: pixels.count,
                uploadBytes: pixels.count, drawCalls: 1
            ),
            usesBitmapAtlas: strategy == .metalBGRA
        )
    }
}
