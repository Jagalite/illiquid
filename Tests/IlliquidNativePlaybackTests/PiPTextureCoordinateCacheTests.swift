import CoreGraphics
import Testing
@testable import IlliquidNativePlayback

@Suite("PiP texture-coordinate cache")
struct PiPTextureCoordinateCacheTests {
    @Test func repeatedRequestsPreserveCompleteCoordinateBits() {
        let request = Request()
        let expected = reference(request)
        var cache = PiPVideoMapping.TextureCoordinateCache()
        let retained = coordinates(request, using: &cache)
        for _ in 0..<64 {
            expectSameCoordinates(coordinates(request, using: &cache), expected)
        }
        expectSameCoordinates(retained, expected)
    }

    @Test func changingEachInputInvalidatesThePreviousMapping() {
        let original = Request()
        let originalCoordinates = reference(original)
        let changes: [(String, (inout Request) -> Void)] = [
            ("coded width", { $0.codedSize.width = 1280 }),
            ("coded height", { $0.codedSize.height = 720 }),
            ("aperture presence", { $0.cleanAperture = nil }),
            ("aperture x", { $0.cleanAperture!.origin.x += 11 }),
            ("aperture y", { $0.cleanAperture!.origin.y += 13 }),
            ("aperture width", { $0.cleanAperture!.size.width = 1600 }),
            ("aperture height", { $0.cleanAperture!.size.height = 900 }),
            ("rotation", { $0.rotationDegrees = -13.75 }),
            ("mirroring", { $0.mirrored = true }),
            ("display crop x", { $0.displayCrop.origin.x += 0.1 }),
            ("display crop y", { $0.displayCrop.origin.y += 0.1 }),
            ("display crop width", { $0.displayCrop.size.width = 0.5 }),
            ("display crop height", { $0.displayCrop.size.height = 0.5 }),
        ]
        for (name, change) in changes {
            var cache = PiPVideoMapping.TextureCoordinateCache()
            let retained = coordinates(original, using: &cache)
            var changed = original
            change(&changed)
            let expected = reference(changed)
            #expect(bits(expected) != bits(originalCoordinates),
                    "The \(name) fixture must change the mapping")
            expectSameCoordinates(coordinates(changed, using: &cache), expected)
            expectSameCoordinates(coordinates(changed, using: &cache), expected)
            expectSameCoordinates(coordinates(original, using: &cache), originalCoordinates)
            expectSameCoordinates(retained, originalCoordinates)
        }
    }

    @Test func arbitraryRotationsMirrorsAndDisplayCropsMatchThePureMapping() {
        let sizes = [CGSize(width: 1920, height: 1080), CGSize(width: 720, height: 576)]
        let apertures: [CGRect?] = [
            nil, CGRect(x: 13, y: 7, width: 640, height: 480),
            CGRect(x: -17, y: 11, width: 2000, height: 1200),
        ]
        let rotations: [Double] = [0, 90, 180, 270, -90, 450, 720, 27.125, -13.75]
        let crops = [
            CGRect(x: 0, y: 0, width: 1, height: 1),
            CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6),
            CGRect(x: -0.125, y: -0.05, width: 1.25, height: 1.125),
            CGRect(x: 0.2, y: 0.3, width: 0, height: 1),
        ]
        var cache = PiPVideoMapping.TextureCoordinateCache()
        for size in sizes {
            for aperture in apertures {
                for rotation in rotations {
                    for mirrored in [false, true] {
                        for crop in crops {
                            let request = Request(
                                codedSize: size, cleanAperture: aperture,
                                rotationDegrees: rotation, mirrored: mirrored, displayCrop: crop
                            )
                            let expected = reference(request)
                            expectSameCoordinates(coordinates(request, using: &cache), expected)
                            expectSameCoordinates(coordinates(request, using: &cache), expected)
                        }
                    }
                }
            }
        }
    }

    @Test func apertureFallbackTransitionsDoNotReuseStaleCoordinates() {
        let apertures: [CGRect?] = [
            CGRect(x: 10, y: 20, width: 60, height: 40), nil, .zero, .null,
            CGRect(x: 500, y: 500, width: 20, height: 20),
            CGRect(x: -10, y: -20, width: 60, height: 70),
            CGRect(x: 70, y: 60, width: -40, height: -30), .infinite,
            CGRect(x: 10, y: 20, width: 60, height: 40),
        ]
        var cache = PiPVideoMapping.TextureCoordinateCache()
        for aperture in apertures {
            let request = Request(
                codedSize: CGSize(width: 100, height: 80), cleanAperture: aperture,
                rotationDegrees: 0, mirrored: false,
                displayCrop: CGRect(x: 0, y: 0, width: 1, height: 1)
            )
            let expected = reference(request)
            expectSameCoordinates(coordinates(request, using: &cache), expected)
            expectSameCoordinates(coordinates(request, using: &cache), expected)
        }
    }

    @Test func nonfiniteAndSignedZeroInputsKeepReferenceBehavior() {
        let regular = Request()
        var unusual: [Request] = []
        for angle in [Double.nan, .infinity, -.infinity, 0.0, -0.0] {
            var request = regular
            request.rotationDegrees = angle
            unusual.append(request)
        }
        var zeroWidth = regular
        zeroWidth.codedSize.width = 0
        unusual.append(zeroWidth)
        var nonfiniteCrop = regular
        nonfiniteCrop.displayCrop.origin.x = .nan
        unusual.append(nonfiniteCrop)
        var positiveZero = regular
        positiveZero.cleanAperture = CGRect(x: 0.0, y: 0.0, width: 1800, height: 1000)
        positiveZero.displayCrop = CGRect(x: 0.0, y: 0.0, width: 1, height: 1)
        unusual.append(positiveZero)
        var negativeZero = positiveZero
        negativeZero.cleanAperture!.origin.x = -0.0
        negativeZero.cleanAperture!.origin.y = -0.0
        negativeZero.displayCrop.origin.x = -0.0
        negativeZero.displayCrop.origin.y = -0.0
        unusual.append(negativeZero)

        var cache = PiPVideoMapping.TextureCoordinateCache()
        for request in unusual {
            expectSameCoordinates(coordinates(regular, using: &cache), reference(regular))
            let expected = reference(request)
            expectSameCoordinates(coordinates(request, using: &cache), expected)
            expectSameCoordinates(coordinates(request, using: &cache), expected)
            expectSameCoordinates(coordinates(regular, using: &cache), reference(regular))
        }
    }

    @Test func copiedCachesAndReturnedArraysRemainIndependent() {
        let original = Request()
        let expected = reference(original)
        var cache = PiPVideoMapping.TextureCoordinateCache()
        let retained = coordinates(original, using: &cache)
        var copiedCache = cache
        var editable = coordinates(original, using: &cache)
        editable[0] = SIMD2<Float>(-1000, 1000)
        expectSameCoordinates(retained, expected)
        expectSameCoordinates(coordinates(original, using: &cache), expected)
        expectSameCoordinates(coordinates(original, using: &copiedCache), expected)

        var different = original
        different.rotationDegrees = 90
        different.mirrored = true
        different.displayCrop = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        var copiedResult = coordinates(different, using: &copiedCache)
        expectSameCoordinates(copiedResult, reference(different))
        copiedResult[5] = SIMD2<Float>(1234, -5678)
        expectSameCoordinates(coordinates(original, using: &cache), expected)
        expectSameCoordinates(coordinates(different, using: &copiedCache), reference(different))
        expectSameCoordinates(retained, expected)
        #expect(editable[0] == SIMD2<Float>(-1000, 1000))
        #expect(copiedResult[5] == SIMD2<Float>(1234, -5678))
    }

    @Test func identityCoordinatesMatchValidHDROutputSizesAndRemainImmutable() {
        let sizes = [
            CGSize(width: 2, height: 2), CGSize(width: 16, height: 10),
            CGSize(width: 720, height: 480), CGSize(width: 1920, height: 1080),
            CGSize(width: 3840, height: 2160), CGSize(width: 8192, height: 4096),
            CGSize(width: 1080, height: 1920),
        ]
        let retained = PiPVideoMapping.identityTextureCoordinates
        for size in sizes {
            expectSameCoordinates(
                PiPVideoMapping.identityTextureCoordinates,
                PiPVideoMapping.textureCoordinates(
                    codedSize: size, cleanAperture: nil, rotationDegrees: 0, mirrored: false
                )
            )
        }
        var editable = PiPVideoMapping.identityTextureCoordinates
        editable[0] = SIMD2<Float>(-1, 2)
        expectSameCoordinates(PiPVideoMapping.identityTextureCoordinates, retained)
        #expect(editable[0] == SIMD2<Float>(-1, 2))
    }

    private struct Request {
        var codedSize = CGSize(width: 1920, height: 1080)
        var cleanAperture: CGRect? = CGRect(x: 13, y: 7, width: 1894, height: 1050)
        var rotationDegrees: Double = 27.125
        var mirrored = false
        var displayCrop = CGRect(x: 0.08, y: 0.07, width: 0.82, height: 0.87)
    }

    private func coordinates(
        _ request: Request, using cache: inout PiPVideoMapping.TextureCoordinateCache
    ) -> [SIMD2<Float>] {
        cache.coordinates(
            codedSize: request.codedSize, cleanAperture: request.cleanAperture,
            rotationDegrees: request.rotationDegrees, mirrored: request.mirrored,
            displayCrop: request.displayCrop
        )
    }

    private func reference(_ request: Request) -> [SIMD2<Float>] {
        PiPVideoMapping.textureCoordinates(
            codedSize: request.codedSize, cleanAperture: request.cleanAperture,
            rotationDegrees: request.rotationDegrees, mirrored: request.mirrored,
            displayCrop: request.displayCrop
        )
    }

    private func bits(_ coordinates: [SIMD2<Float>]) -> [UInt32] {
        coordinates.flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
    }

    private func expectSameCoordinates(_ actual: [SIMD2<Float>], _ expected: [SIMD2<Float>]) {
        #expect(actual.count == 6)
        #expect(actual.count == expected.count)
        for (actualVector, expectedVector) in zip(actual, expected) {
            for lane in 0..<2 {
                if expectedVector[lane].isNaN {
                    #expect(actualVector[lane].isNaN)
                } else {
                    #expect(actualVector[lane].bitPattern == expectedVector[lane].bitPattern)
                }
            }
        }
    }
}
