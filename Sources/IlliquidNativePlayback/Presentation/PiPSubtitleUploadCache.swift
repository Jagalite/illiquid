import Foundation
import Metal

/// Work-queue-confined resources for the current prepared PiP caption.
/// Invalidate whenever the prepared frame is replaced, including empty frames.
/// The compositor waits for GPU completion before preparing the next frame, so
/// changed captions can reuse this storage without overwriting an in-flight draw.
final class PiPSubtitleUploadCache {
    struct Upload {
        let texture: any MTLTexture
        let vertexBuffer: any MTLBuffer
        let vertexCount: Int
        let didUpload: Bool
        let textureUploadBytes: Int
        let vertexUploadBytes: Int
    }

    private struct SubtitleVertex {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
        var color: SIMD4<Float>
    }

    private let device: any MTLDevice
    private var subtitleTexture: (any MTLTexture)?
    private var subtitleVertexBuffer: (any MTLBuffer)?
    private var subtitleVertexCapacity = 0
    private var subtitleVertexCount = 0
    private var needsUpload = true

    init(device: any MTLDevice) {
        self.device = device
    }

    func invalidate() {
        needsUpload = true
    }

    func retireSource() {
        subtitleTexture = nil
        subtitleVertexBuffer = nil
        subtitleVertexCapacity = 0
        subtitleVertexCount = 0
        invalidate()
    }

    var retainedResourceBytesForTesting: (texture: Int, vertices: Int) {
        (subtitleTexture?.allocatedSize ?? 0, subtitleVertexBuffer?.allocatedSize ?? 0)
    }

    /// Only nonempty, validated packer output reaches this method. A cache hit
    /// reuses GPU resources, while the caller still encodes the caption draw
    /// into each new video frame with its current viewport and color pipeline.
    func resources(for frame: ASSPreparedSubtitleFrame) throws -> Upload {
        if !needsUpload, let subtitleTexture, let subtitleVertexBuffer {
            return Upload(
                texture: subtitleTexture,
                vertexBuffer: subtitleVertexBuffer,
                vertexCount: subtitleVertexCount,
                didUpload: false,
                textureUploadBytes: 0,
                vertexUploadBytes: 0
            )
        }

        let textureWidth = Int(frame.textureSize.width)
        let textureHeight = Int(frame.textureSize.height)
        guard textureWidth > 0, textureHeight > 0 else {
            throw PiPSubtitleCompositorError.textureCreation
        }
        let pixelFormat: MTLPixelFormat = frame.strategy == .metalBGRA ? .bgra8Unorm : .r8Unorm
        if subtitleTexture == nil
            || subtitleTexture!.width < textureWidth
            || subtitleTexture!.height < textureHeight
            || subtitleTexture!.pixelFormat != pixelFormat
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: textureWidth,
                height: textureHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            subtitleTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let subtitleTexture else {
            throw PiPSubtitleCompositorError.textureCreation
        }
        frame.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            subtitleTexture.replace(
                region: MTLRegionMake2D(0, 0, textureWidth, textureHeight),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: frame.bytesPerRow
            )
        }

        let vertices = subtitleVertices(frame, texture: subtitleTexture)
        let requiredBytes = vertices.count * MemoryLayout<SubtitleVertex>.stride
        if subtitleVertexBuffer == nil || subtitleVertexCapacity < requiredBytes {
            subtitleVertexCapacity = max(requiredBytes, max(subtitleVertexCapacity * 2, 4_096))
            subtitleVertexBuffer = device.makeBuffer(
                length: subtitleVertexCapacity,
                options: .storageModeShared
            )
        }
        guard let subtitleVertexBuffer else {
            throw PiPSubtitleCompositorError.commandEncoding
        }
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            subtitleVertexBuffer.contents().copyMemory(
                from: baseAddress,
                byteCount: requiredBytes
            )
        }

        // Allocation or upload failure must leave the next attempt dirty.
        subtitleVertexCount = vertices.count
        needsUpload = false
        return Upload(
            texture: subtitleTexture,
            vertexBuffer: subtitleVertexBuffer,
            vertexCount: vertices.count,
            didUpload: true,
            textureUploadBytes: textureWidth * textureHeight * (pixelFormat == .bgra8Unorm ? 4 : 1),
            vertexUploadBytes: requiredBytes
        )
    }

    private func subtitleVertices(
        _ frame: ASSPreparedSubtitleFrame,
        texture: any MTLTexture
    ) -> [SubtitleVertex] {
        var vertices: [SubtitleVertex] = []
        vertices.reserveCapacity(frame.quads.count * 6)
        for quad in frame.quads {
            let alpha = Float(255 - UInt8(quad.color & 0xff)) / 255
            let color = SIMD4<Float>(
                Float((quad.color >> 24) & 0xff) / 255,
                Float((quad.color >> 16) & 0xff) / 255,
                Float((quad.color >> 8) & 0xff) / 255,
                alpha
            )
            let x0 = Float(quad.destination.minX)
            let y0 = Float(quad.destination.minY)
            let x1 = Float(quad.destination.maxX)
            let y1 = Float(quad.destination.maxY)
            let u0 = Float(quad.source.minX) / Float(texture.width)
            let v0 = Float(quad.source.minY) / Float(texture.height)
            let u1 = Float(quad.source.maxX) / Float(texture.width)
            let v1 = Float(quad.source.maxY) / Float(texture.height)
            let topLeft = SubtitleVertex(
                position: SIMD2(x0, y0),
                textureCoordinate: SIMD2(u0, v0),
                color: color
            )
            let bottomLeft = SubtitleVertex(
                position: SIMD2(x0, y1),
                textureCoordinate: SIMD2(u0, v1),
                color: color
            )
            let topRight = SubtitleVertex(
                position: SIMD2(x1, y0),
                textureCoordinate: SIMD2(u1, v0),
                color: color
            )
            let bottomRight = SubtitleVertex(
                position: SIMD2(x1, y1),
                textureCoordinate: SIMD2(u1, v1),
                color: color
            )
            vertices += [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
        }
        return vertices
    }
}
