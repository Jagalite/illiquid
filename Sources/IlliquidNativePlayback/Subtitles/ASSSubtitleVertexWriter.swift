import CoreGraphics

/// Writes the renderer's trivial vertex layout into an already-owned buffer.
/// The caller must keep this storage exclusive until GPU use has completed.
enum ASSSubtitleVertexWriter {
    struct Vertex: BitwiseCopyable, Sendable {
        var position: SIMD2<Float>
        var textureCoordinate: SIMD2<Float>
        var color: SIMD4<UInt8>
    }

    static func write(
        _ frame: ASSPreparedSubtitleFrame,
        textureWidth: Int,
        textureHeight: Int,
        targetSize: CGSize,
        configuration: MetalASSRenderConfiguration,
        into destination: UnsafeMutableRawBufferPointer
    ) {
        let stride = MemoryLayout<Vertex>.stride
        let (required, overflow) = frame.quads.count.multipliedReportingOverflow(by: 6 * stride)
        precondition(!overflow && required <= destination.count)
        guard !frame.quads.isEmpty else { return }
        precondition(textureWidth > 0 && textureHeight > 0)

        let width = Float(textureWidth)
        let height = Float(textureHeight)
        let xOffset = configuration.quadOffsetPixels
            * Float(frame.canvasSize.width / max(targetSize.width, 1))
        let yOffset = configuration.quadOffsetPixels
            * Float(frame.canvasSize.height / max(targetSize.height, 1))
        let texelInset: Float = configuration.textureCoordinates == .texelCenters ? 0.5 : 0
        var offset = 0
        for quad in frame.quads {
            let color = SIMD4<UInt8>(
                UInt8((quad.color >> 24) & 0xff),
                UInt8((quad.color >> 16) & 0xff),
                UInt8((quad.color >> 8) & 0xff),
                255 - UInt8(quad.color & 0xff)
            )
            let x0 = Float(quad.destination.minX) + xOffset
            let y0 = Float(quad.destination.minY) + yOffset
            let x1 = Float(quad.destination.maxX) + xOffset
            let y1 = Float(quad.destination.maxY) + yOffset
            let u0 = (Float(quad.source.minX) + texelInset) / width
            let v0 = (Float(quad.source.minY) + texelInset) / height
            let u1 = (Float(quad.source.maxX) - texelInset) / width
            let v1 = (Float(quad.source.maxY) - texelInset) / height
            let topLeft = Vertex(
                position: SIMD2(x0, y0), textureCoordinate: SIMD2(u0, v0), color: color
            )
            let bottomLeft = Vertex(
                position: SIMD2(x0, y1), textureCoordinate: SIMD2(u0, v1), color: color
            )
            let topRight = Vertex(
                position: SIMD2(x1, y0), textureCoordinate: SIMD2(u1, v0), color: color
            )
            let bottomRight = Vertex(
                position: SIMD2(x1, y1), textureCoordinate: SIMD2(u1, v1), color: color
            )
            destination.storeBytes(of: topLeft, toByteOffset: offset, as: Vertex.self)
            destination.storeBytes(of: bottomLeft, toByteOffset: offset + stride, as: Vertex.self)
            destination.storeBytes(of: topRight, toByteOffset: offset + 2 * stride, as: Vertex.self)
            destination.storeBytes(of: topRight, toByteOffset: offset + 3 * stride, as: Vertex.self)
            destination.storeBytes(of: bottomLeft, toByteOffset: offset + 4 * stride, as: Vertex.self)
            destination.storeBytes(of: bottomRight, toByteOffset: offset + 5 * stride, as: Vertex.self)
            offset += 6 * stride
        }
    }
}
