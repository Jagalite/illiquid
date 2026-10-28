import CoreGraphics

// API-only adapter for the original helper, compiled into the baseline module.
// It deliberately recomputes every request, exactly as the old compositor did.
// All geometry math comes from the byte-for-byte Git baseline source.
extension PiPVideoMapping {
    struct TextureCoordinateCache {
        mutating func coordinates(
            codedSize: CGSize, cleanAperture: CGRect?, rotationDegrees: Double,
            mirrored: Bool, displayCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        ) -> [SIMD2<Float>] {
            PiPVideoMapping.textureCoordinates(
                codedSize: codedSize, cleanAperture: cleanAperture,
                rotationDegrees: rotationDegrees, mirrored: mirrored, displayCrop: displayCrop
            )
        }
    }

    // Positive output dimensions do not affect identity UVs. The old HDR path
    // recomputed them once per composed frame, before its two conversion passes.
    static var identityTextureCoordinates: [SIMD2<Float>] {
        textureCoordinates(
            codedSize: CGSize(width: 1920, height: 1080), cleanAperture: nil,
            rotationDegrees: 0, mirrored: false
        )
    }
}
