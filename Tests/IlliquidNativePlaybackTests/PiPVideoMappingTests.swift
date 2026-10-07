import CoreGraphics
import Testing
@testable import IlliquidNativePlayback

@Suite("PiP video source interpretation")
struct PiPVideoMappingTests {
    @Test func rotationAndMirroringMapAsymmetricCorners() {
        let expected: [(Double, SIMD2<Float>)] = [
            (0, SIMD2(0, 0)), (90, SIMD2(1, 0)),
            (180, SIMD2(1, 1)), (270, SIMD2(0, 1)),
        ]
        for (angle, corner) in expected {
            for mirrored in [false, true] {
                let uv = PiPVideoMapping.textureCoordinates(
                    codedSize: CGSize(width: 1920, height: 1080), cleanAperture: nil,
                    rotationDegrees: angle, mirrored: mirrored
                )[0]
                #expect(abs(uv.x - (mirrored ? 1 - corner.x : corner.x)) < 0.00001)
                #expect(abs(uv.y - corner.y) < 0.00001)
            }
        }
    }

    @Test func cleanApertureSelectsPixelsInsteadOfResizingTheCodedBorder() {
        let uv = PiPVideoMapping.textureCoordinates(
            codedSize: CGSize(width: 100, height: 80),
            cleanAperture: CGRect(x: 10, y: 20, width: 60, height: 40),
            rotationDegrees: 0, mirrored: false
        )
        #expect(uv[0] == SIMD2<Float>(0.1, 0.25))
        #expect(uv[5] == SIMD2<Float>(0.7, 0.75))
    }
}
