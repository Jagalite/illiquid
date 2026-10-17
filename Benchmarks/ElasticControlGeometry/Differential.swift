import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

@main
@MainActor
enum ElasticGeometryDifferential {
    static var comparisons = 0
    static var geometries = 0
    static var maximumCoordinateError: CGFloat = 0
    static var maximumFractionError: CGFloat = 0
    static var boundaryClassifications = 0
    static var exactBoundaryDifferences = 0
    static var exactSampleTieDifferences = 0
    static var sampleTieComparisons = 0
    static var partialBendMaximumError: CGFloat = 0

    static func close(_ lhs: CGFloat, _ rhs: CGFloat, fraction: Bool = false,
                      partialBend: Bool = false) {
        precondition(lhs.isFinite && rhs.isFinite)
        let error = abs(lhs - rhs)
        comparisons += 1
        if fraction { maximumFractionError = max(maximumFractionError, error) }
        else { maximumCoordinateError = max(maximumCoordinateError, error) }
        if partialBend { partialBendMaximumError = max(partialBendMaximumError, error) }
        precondition(error <= 1e-8, "geometry error \(error): \(lhs) vs \(rhs)")
    }

    static func compare(_ lhs: CGPoint, _ rhs: CGPoint, partialBend: Bool = false) {
        close(lhs.x, rhs.x, partialBend: partialBend)
        close(lhs.y, rhs.y, partialBend: partialBend)
    }

    static func main() throws {
        let sizes = [CGSize(width: 720, height: 408), CGSize(width: 900, height: 600),
                     CGSize(width: 1_280, height: 720), CGSize(width: 1_920, height: 1_080),
                     CGSize(width: 3_840, height: 2_160)]
        for size in sizes {
            let centers = [CGPoint(x: size.width / 2, y: size.height / 2),
                           CGPoint(x: size.width / 2, y: size.height - 44),
                           CGPoint(x: 46, y: 46),
                           CGPoint(x: size.width - 46, y: size.height - 44),
                           CGPoint(x: size.width * 0.65, y: size.height * 0.45),
                           CGPoint(x: -1_000, y: -1_000),
                           CGPoint(x: size.width + 1_000, y: size.height + 1_000),
                           CGPoint(x: -10_000, y: size.height / 2),
                           CGPoint(x: size.width / 2, y: 10_000)]
            for center in centers {
                for rawOrientation in 0..<4 {
                    for down in [false, true] {
                        for utilityCount in [1, 3, 7] {
                            let old = BaselineElasticPlaybackControlBarGeometry(
                                containerSize: size, center: center, utilityCount: utilityCount,
                                bendDirection: down ? .down : .up,
                                orientation: BaselineElasticPlaybackControlBarOrientation(rawValue: rawOrientation)!)
                            let new = ElasticPlaybackControlBarGeometry(
                                containerSize: size, center: center, utilityCount: utilityCount,
                                bendDirection: down ? .down : .up,
                                orientation: ElasticPlaybackControlBarOrientation(rawValue: rawOrientation)!)
                            verify(old, new)
                        }
                    }
                }
            }
        }
        // Cover either side of bend completion, not just the exact endpoints.
        let transitionSize = CGSize(width: 1_400, height: 1_200)
        for rawOrientation in 0..<4 {
            let orientation = ElasticPlaybackControlBarOrientation(rawValue: rawOrientation)!
            let dimension = orientation.isHorizontal ? transitionSize.width : transitionSize.height
            let leadingInset: CGFloat = orientation == .up ? 16 : 18
            let trailingInset: CGFloat = orientation == .down ? 16 : 18
            for leading in [false, true] {
                let boundary = leading ? leadingInset + 28 + 470 : dimension - trailingInset - 28 - 470
                let outward: CGFloat = leading ? -1 : 1
                for delta: CGFloat in [-0.1, -0.001, 0, 0.001, 0.1] {
                    let axis = boundary + outward * (940 * 0.75 + delta)
                    let center: CGPoint
                    switch orientation {
                    case .right: center = CGPoint(x: axis, y: 600)
                    case .down: center = CGPoint(x: 700, y: axis)
                    case .left: center = CGPoint(x: transitionSize.width - axis, y: 600)
                    case .up: center = CGPoint(x: 700, y: transitionSize.height - axis)
                    }
                    for down in [false, true] {
                        verify(BaselineElasticPlaybackControlBarGeometry(
                            containerSize: transitionSize, center: center, utilityCount: 7,
                            bendDirection: down ? .down : .up,
                            orientation: BaselineElasticPlaybackControlBarOrientation(rawValue: rawOrientation)!),
                               ElasticPlaybackControlBarGeometry(
                            containerSize: transitionSize, center: center, utilityCount: 7,
                            bendDirection: down ? .down : .up, orientation: orientation))
                    }
                }
            }
        }
        // Sidebar avoidance repeatedly reconstructs geometry and tests bounds.
        for size in [CGSize(width: 720, height: 408), CGSize(width: 1_280, height: 720)] {
            for width: CGFloat in [0, 320, 468] {
                for rawOrientation in 0..<4 {
                    let center = CGPoint(x: size.width / 2, y: size.height - 44)
                    verify(BaselineElasticPlaybackControlBarGeometry.avoidingSidebar(
                        containerSize: size, center: center, utilityCount: 3, bendDirection: .up,
                        orientation: BaselineElasticPlaybackControlBarOrientation(rawValue: rawOrientation)!,
                        sidebarOccupiedWidth: width),
                           ElasticPlaybackControlBarGeometry.avoidingSidebar(
                        containerSize: size, center: center, utilityCount: 3, bendDirection: .up,
                        orientation: ElasticPlaybackControlBarOrientation(rawValue: rawOrientation)!,
                        sidebarOccupiedWidth: width), derivesCenter: true)
                }
            }
        }
        // Feed the same desired point to the iterative drag solver, including
        // transitions from straight to bent.
        for x: CGFloat in [640, 760, 800, 1_100, 1_500] {
            let size = CGSize(width: 1_280, height: 720)
            let center = CGPoint(x: x, y: 400)
            for fraction: CGFloat in [0.1, 0.5, 0.9] {
                let old = BaselineElasticPlaybackControlBarGeometry(
                    containerSize: size, center: center, utilityCount: 7, bendDirection: .up)
                let desired = old.grabPoint(surfaceFraction: fraction, localOffset: CGPoint(x: 4, y: -8))
                let target = CGPoint(x: desired.x + 3, y: desired.y - 2)
                compare(BaselineElasticPlaybackControlBarGeometry.centerTracking(
                    desiredPoint: target, surfaceFraction: fraction, localOffset: CGPoint(x: 4, y: -8),
                    initialCenter: center, containerSize: size, utilityCount: 7,
                    bendDirection: .up, maximumCorrection: 4),
                        ElasticPlaybackControlBarGeometry.centerTracking(
                    desiredPoint: target, surfaceFraction: fraction, localOffset: CGPoint(x: 4, y: -8),
                    initialCenter: center, containerSize: size, utilityCount: 7,
                    bendDirection: .up, maximumCorrection: 4))
            }
        }
        let result: [String: Any] = [
            "geometries": geometries, "numeric_comparisons": comparisons,
            "maximum_coordinate_error_points": Double(maximumCoordinateError),
            "maximum_fraction_error": Double(maximumFractionError),
            "partial_bend_maximum_error": Double(partialBendMaximumError),
            "boundary_classifications": boundaryClassifications,
            "exact_boundary_differences": exactBoundaryDifferences,
            "sample_tie_comparisons": sampleTieComparisons,
            "exact_sample_tie_differences": exactSampleTieDifferences,
            "coordinate_tolerance_points": 1e-8,
            "boundary_margin_points": 1e-6,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,
                                                        options: [.sortedKeys]), as: UTF8.self))
    }

    static func verify(_ old: BaselineElasticPlaybackControlBarGeometry,
                       _ new: ElasticPlaybackControlBarGeometry, derivesCenter: Bool = false) {
        geometries += 1
        let partial = old.bendProgress > 0 && old.bendProgress < 1 && !derivesCenter
        // Sidebar placement derives its next center from preceding bounds;
        // compare that numerical result, rather than requiring identical bits.
        if derivesCenter {
            close(old.bendProgress, new.bendProgress, fraction: true)
            compare(old.center, new.center)
        } else {
            precondition(old.bendProgress == new.bendProgress)
        }
        close(old.totalLength, new.totalLength)
        close(old.containmentOffset.width, new.containmentOffset.width, partialBend: partial)
        close(old.containmentOffset.height, new.containmentOffset.height, partialBend: partial)
        close(old.surfaceBounds.minX, new.surfaceBounds.minX, partialBend: partial)
        close(old.surfaceBounds.maxY, new.surfaceBounds.maxY, partialBend: partial)
        precondition(old.surfacePoints.count == new.surfacePoints.count)
        for (lhs, rhs) in zip(old.surfacePoints, new.surfacePoints) {
            compare(lhs, rhs, partialBend: partial)
        }
        for (lhs, rhs) in zip(old.utilityPositions, new.utilityPositions) {
            compare(lhs, rhs, partialBend: partial)
        }
        for index in 0...32 {
            let fraction = CGFloat(index) / 32
            compare(old.pointOnTrack(fraction: fraction), new.pointOnTrack(fraction: fraction),
                    partialBend: partial)
        }
        let fractions: [CGFloat] = [0, 0.0001, 0.123456, 0.5, 0.5033, 0.9999, 1]
        for fraction in fractions {
            let location = old.pointOnTrack(fraction: fraction)
            let oldFraction = old.timelineFraction(at: location, maximumDistance: 1)
            let newFraction = new.timelineFraction(at: location, maximumDistance: 1)
            precondition(oldFraction != nil && newFraction != nil)
            close(oldFraction!, newFraction!, fraction: true)
            let surface = old.pointOnSurface(fraction: fraction)
            compare(surface, new.pointOnSurface(fraction: fraction), partialBend: partial)
            precondition(old.containsSurface(surface) == new.containsSurface(surface))
            let offset = CGPoint(x: 4, y: -8)
            compare(old.grabPoint(surfaceFraction: fraction, localOffset: offset),
                    new.grabPoint(surfaceFraction: fraction, localOffset: offset), partialBend: partial)
        }
        // The nearest sample is unambiguous here. At exactly 28 points, old
        // repeated addition can round either side of the inclusive boundary;
        // report those ties, but require agreement 1e-6 points to either side.
        let surface = old.pointOnSurface(fraction: 0.5)
        let normal = old.tangentAngle(at: 0) + .pi / 2
        for delta: CGFloat in [-1e-6, 0, 1e-6] {
            let radius: CGFloat = 28 + delta
            let location = CGPoint(x: surface.x + cos(normal) * radius,
                                   y: surface.y + sin(normal) * radius)
            let before = old.containsSurface(location)
            let after = new.containsSurface(location)
            boundaryClassifications += 1
            if delta == 0 {
                if before != after { exactBoundaryDifferences += 1 }
            } else {
                precondition(before == after, "hit classification changed outside rounding boundary")
            }
        }
        // A surface drag picks the closest of 161 samples. At an exact midpoint
        // either adjacent sample can win after roundoff; the stored local offset
        // still preserves the grabbed point. Away from ties the sample must agree.
        for index in [0, 47, 79, 80, 128, 159] {
            let a = old.pointOnSurface(fraction: CGFloat(index) / 160)
            let b = old.pointOnSurface(fraction: CGFloat(index + 1) / 160)
            let length = hypot(b.x - a.x, b.y - a.y)
            for delta: CGFloat in [-1e-6, 0, 1e-6] {
                let location = CGPoint(x: (a.x + b.x) / 2 + (b.x - a.x) / length * delta,
                                       y: (a.y + b.y) / 2 + (b.y - a.y) / length * delta)
                let before = old.surfaceFraction(at: location, maximumDistance: 8)!
                let after = new.surfaceFraction(at: location, maximumDistance: 8)!
                sampleTieComparisons += 1
                if delta == 0 {
                    precondition(abs(before - after) <= 1.0 / 160 + 1e-12)
                    if before != after { exactSampleTieDifferences += 1 }
                } else {
                    precondition(before == after, "nearest sample changed outside rounding tie")
                }
                let oldOffset = old.localOffset(from: location, atSurfaceFraction: before)
                let newOffset = new.localOffset(from: location, atSurfaceFraction: after)
                compare(old.grabPoint(surfaceFraction: before, localOffset: oldOffset),
                        new.grabPoint(surfaceFraction: after, localOffset: newOffset))
            }
        }
    }
}
