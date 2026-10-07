import CoreGraphics
import Foundation

/// Source interpretation shared by the PiP encoder and its reference tests.
enum PiPVideoMapping {
    static func colorCoefficients(matrix: Int32?) -> SIMD4<Float> {
        let weights: (Float, Float)
        switch matrix {
        case 5, 6: weights = (0.299, 0.114) // BT.601
        case 9: weights = (0.2627, 0.0593) // BT.2020 non-constant luminance
        case 4: weights = (0.30, 0.11) // FCC
        case 7: weights = (0.212, 0.087) // SMPTE 240M
        default: weights = (0.2126, 0.0722) // BT.709 / unspecified
        }
        let (kr, kb) = weights
        let kg = 1 - kr - kb
        return SIMD4(2 * (1 - kr), -2 * kb * (1 - kb) / kg,
                     -2 * kr * (1 - kr) / kg, 2 * (1 - kb))
    }

    static func textureCoordinates(
        codedSize: CGSize, cleanAperture: CGRect?, rotationDegrees: Double,
        mirrored: Bool, displayCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> [SIMD2<Float>] {
        let bounds = CGRect(origin: .zero, size: codedSize)
        let requested = cleanAperture?.intersection(bounds) ?? bounds
        let crop = requested.isEmpty || requested.isNull ? bounds : requested
        var transform = CGAffineTransform(rotationAngle: rotationDegrees * .pi / 180)
        if mirrored { transform = transform.scaledBy(x: -1, y: 1) }
        let inverse = transform.inverted()
        let corners: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 0),
            .init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: 1, y: 1),
        ]
        return corners.map { corner in
            // Match the main layer's y-up rotation, then return to texture
            // coordinates with a top-left origin. Crop before transforming.
            let source = CGPoint(x: displayCrop.minX + corner.x * displayCrop.width - 0.5,
                y: 0.5 - displayCrop.minY - corner.y * displayCrop.height).applying(inverse)
            return SIMD2(
                Float((crop.minX + (source.x + 0.5) * crop.width) / codedSize.width),
                Float((crop.minY + (0.5 - source.y) * crop.height) / codedSize.height)
            )
        }
    }
}
