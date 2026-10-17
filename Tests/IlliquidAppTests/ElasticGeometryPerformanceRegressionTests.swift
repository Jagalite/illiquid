import Foundation
import Testing
@testable import IlliquidApp

@Suite("Elastic geometry fast-path regressions")
struct ElasticGeometryPerformanceRegressionTests {
    private let orientations: [ElasticPlaybackControlBarOrientation] = [.right, .down, .left, .up]
    private let sides: [ElasticPlaybackControlBarSide] = [.leading, .trailing]
    private let directions: [ElasticPlaybackControlBarBendDirection] = [.up, .down]
    // A direct displacement and repeated integration need not round identically.
    // This is far below a display pixel without making hit areas wider.
    private let coordinateTolerance: CGFloat = 0.00000001

    @Test func straightDistancesFollowEveryCardinalAxisAtBothLayoutSizes() {
        for size in [CGSize(width: 620, height: 520), CGSize(width: 1400, height: 1200)] {
            for orientation in orientations {
                let geometry = makeGeometry(size: size, orientation: orientation)
                #expect(geometry.bendProgress == 0)
                let origin = geometry.point(at: 0)
                let axis = cardinalAxis(orientation)
                let halfLength = geometry.totalLength / 2
                // Include both signs, zero, fractional positions, and the old
                // integration step boundary so it cannot become a position jump.
                let distances: [CGFloat] = [
                    -halfLength, -12.25, -6.000001, -6, -5.999999, -0.125,
                    0, 0.125, 5.999999, 6, 6.000001, 12.25, halfLength,
                ]
                for distance in distances {
                    expectPoint(geometry.point(at: distance), near: CGPoint(
                        x: origin.x + axis.x * distance,
                        y: origin.y + axis.y * distance
                    ))
                }
                expectPoint(geometry.surfacePoints.first!, near: geometry.pointOnSurface(fraction: 0))
                expectPoint(geometry.surfacePoints.last!, near: geometry.pointOnSurface(fraction: 1))
                expectPoint(geometry.pointOnTrack(fraction: -0.5), near: geometry.point(at: geometry.trackStartS))
                expectPoint(geometry.pointOnTrack(fraction: 1.5), near: geometry.point(at: geometry.trackEndS))
            }
        }
    }

    @Test func straightFastPathPreservesContainmentForOffscreenCrossAxisCenters() {
        let size = CGSize(width: 1400, height: 1200)
        for orientation in orientations {
            for isBeyondFarEdge in [false, true] {
                var requestedCenter = centeredPoint(in: size)
                if orientation.isHorizontal {
                    requestedCenter.y = isBeyondFarEdge ? size.height + 250.25 : -250.25
                } else {
                    requestedCenter.x = isBeyondFarEdge ? size.width + 250.25 : -250.25
                }
                let geometry = makeGeometry(size: size, orientation: orientation, center: requestedCenter)
                #expect(geometry.bendProgress == 0)
                var expectedOrigin = requestedCenter
                if orientation.isHorizontal {
                    expectedOrigin.y = isBeyondFarEdge ? size.height - 44 : 46
                    #expect(geometry.containmentOffset.height != 0)
                } else {
                    expectedOrigin.x = isBeyondFarEdge ? size.width - 46 : 46
                    #expect(geometry.containmentOffset.width != 0)
                }
                expectPoint(geometry.point(at: 0), near: expectedOrigin)
                let bounds = geometry.surfaceBounds
                #expect(bounds.minX >= 18 - coordinateTolerance)
                #expect(bounds.maxX <= size.width - 18 + coordinateTolerance)
                #expect(bounds.minY >= 18 - coordinateTolerance)
                #expect(bounds.maxY <= size.height - 16 + coordinateTolerance)
                let axis = cardinalAxis(orientation)
                for distance in [-geometry.totalLength / 2, geometry.totalLength / 2] {
                    expectPoint(geometry.point(at: distance), near: CGPoint(
                        x: expectedOrigin.x + axis.x * distance,
                        y: expectedOrigin.y + axis.y * distance
                    ))
                }
            }
        }
    }

    @Test func leadingAndTrailingDeformationsStayContinuousAtTheStraightBoundary() {
        let size = CGSize(width: 1400, height: 1200)
        let epsilon: CGFloat = 0.0001
        for orientation in orientations {
            let straight = makeGeometry(size: size, orientation: orientation)
            for side in sides {
                let boundary = boundaryAxisCoordinate(for: side, orientation: orientation,
                                                      size: size, length: straight.totalLength)
                let outward: CGFloat = side == .leading ? -1 : 1
                for direction in directions {
                    let before = makeGeometry(size: size, orientation: orientation, direction: direction,
                        center: center(atAxisCoordinate: boundary - outward * epsilon, orientation: orientation, size: size))
                    let at = makeGeometry(size: size, orientation: orientation, direction: direction,
                        center: center(atAxisCoordinate: boundary, orientation: orientation, size: size))
                    let after = makeGeometry(size: size, orientation: orientation, direction: direction,
                        center: center(atAxisCoordinate: boundary + outward * epsilon, orientation: orientation, size: size))
                    #expect(before.bendProgress == 0)
                    #expect(at.bendProgress == 0)
                    #expect(after.bendProgress > 0 && after.bendProgress < 1)
                    #expect(after.side == side)
                    for fraction: CGFloat in [0, 0.5, 1] {
                        expectPoint(before.pointOnSurface(fraction: fraction),
                                    near: at.pointOnSurface(fraction: fraction), tolerance: 0.001)
                        expectPoint(after.pointOnSurface(fraction: fraction),
                                    near: at.pointOnSurface(fraction: fraction), tolerance: 0.001)
                    }
                }
            }
        }
    }

    @Test func partialBendsKeepTheirElbowWhileCompletedTurnsAreStraight() {
        let size = CGSize(width: 1400, height: 1200)
        for orientation in orientations {
            let sourceAxis = cardinalAxis(orientation)
            let normal = CGPoint(x: -sourceAxis.y, y: sourceAxis.x)
            let initialLength = makeGeometry(size: size, orientation: orientation).totalLength
            for side in sides {
                let outward: CGFloat = side == .leading ? -1 : 1
                let boundary = boundaryAxisCoordinate(for: side, orientation: orientation,
                                                      size: size, length: initialLength)
                for direction in directions {
                    let partial = makeGeometry(size: size, orientation: orientation, direction: direction,
                        center: center(atAxisCoordinate: boundary + outward * initialLength * 0.35,
                                       orientation: orientation, size: size))
                    #expect(partial.bendProgress > 0 && partial.bendProgress < 1)
                    #expect(partial.side == side)
                    let start = partial.pointOnSurface(fraction: 0)
                    let end = partial.pointOnSurface(fraction: 1)
                    #expect(hypot(end.x - start.x, end.y - start.y) < partial.totalLength - 10)
                    let tip = side == .leading ? start : end
                    let origin = partial.point(at: 0)
                    let normalTravel = (tip.x - origin.x) * normal.x + (tip.y - origin.y) * normal.y
                    #expect(direction == .down ? normalTravel > 10 : normalTravel < -10)

                    let completed = makeGeometry(size: size, orientation: orientation, direction: direction,
                        center: center(atAxisCoordinate: boundary + outward * initialLength,
                                       orientation: orientation, size: size))
                    #expect(completed.bendProgress == 1)
                    #expect(completed.side == side)
                    // A complete bend is a quarter turn. Its direction follows
                    // the contacted side and the user's chosen bend direction.
                    let turnSign = outward * (direction == .down ? 1 : -1)
                    let terminalAxis = CGPoint(x: normal.x * turnSign, y: normal.y * turnSign)
                    let completedOrigin = completed.point(at: 0)
                    for distance in [-completed.totalLength / 2, -6.25, 0, 6.25, completed.totalLength / 2] {
                        expectPoint(completed.point(at: distance), near: CGPoint(
                            x: completedOrigin.x + terminalAxis.x * distance,
                            y: completedOrigin.y + terminalAxis.y * distance
                        ))
                    }
                }
            }
        }
    }

    @Test func rotatedStraightHitAreasDoNotGrowOrShrinkWithPositionRounding() throws {
        let epsilon: CGFloat = 0.000001
        for orientation in orientations {
            let geometry = makeGeometry(size: CGSize(width: 1400, height: 1200), orientation: orientation)
            let axis = cardinalAxis(orientation)
            let normal = CGPoint(x: -axis.y, y: axis.x)
            let fraction: CGFloat = 0.371234
            let trackPoint = geometry.pointOnTrack(fraction: fraction)
            let surfacePoint = geometry.pointOnSurface(fraction: 0.5)
            let handle = geometry.point(at: geometry.dragHandleS)
            for sign: CGFloat in [-1, 1] {
                let insideTrack = offset(trackPoint, axis: normal, distance: sign * (22 - epsilon))
                let actual = try #require(geometry.timelineFraction(at: insideTrack, maximumDistance: 22))
                #expect(abs(actual - fraction) < coordinateTolerance)
                #expect(geometry.timelineFraction(
                    at: offset(trackPoint, axis: normal, distance: sign * (22 + epsilon)),
                    maximumDistance: 22) == nil)
                #expect(geometry.containsSurface(offset(surfacePoint, axis: normal, distance: sign * (28 - epsilon))))
                #expect(!geometry.containsSurface(offset(surfacePoint, axis: normal, distance: sign * (28 + epsilon))))
                #expect(geometry.containsDragHandle(offset(handle, axis: axis, distance: sign * (12 - epsilon))))
                #expect(!geometry.containsDragHandle(offset(handle, axis: axis, distance: sign * (12 + epsilon))))
                #expect(geometry.containsDragHandle(offset(handle, axis: normal, distance: sign * (20 - epsilon))))
                #expect(!geometry.containsDragHandle(offset(handle, axis: normal, distance: sign * (20 + epsilon))))
            }
        }
    }

    @Test func exactlyRepresentableHitBoundariesRemainInclusive() {
        // The horizontal fixture avoids ambiguous last-bit rotation at an
        // exact boundary. Other orientations are checked on both sides above.
        let geometry = makeGeometry(size: CGSize(width: 1400, height: 1200), orientation: .right,
                                    center: CGPoint(x: 700, y: 600))
        let track = geometry.pointOnTrack(fraction: 0.5)
        let surface = geometry.pointOnSurface(fraction: 0.5)
        let handle = geometry.point(at: geometry.dragHandleS)
        #expect(geometry.timelineFraction(at: track, maximumDistance: 0) == 0.5)
        #expect(geometry.surfaceFraction(at: surface, maximumDistance: 0) == 0.5)
        for sign: CGFloat in [-1, 1] {
            #expect(geometry.timelineFraction(at: CGPoint(x: track.x, y: track.y + sign * 22), maximumDistance: 22) != nil)
            #expect(geometry.containsSurface(CGPoint(x: surface.x, y: surface.y + sign * 28)))
            for otherSign: CGFloat in [-1, 1] {
                #expect(geometry.containsDragHandle(CGPoint(x: handle.x + sign * 12, y: handle.y + otherSign * 20)))
            }
        }
        let start = geometry.pointOnTrack(fraction: 0)
        let end = geometry.pointOnTrack(fraction: 1)
        #expect(geometry.timelineFraction(at: CGPoint(x: start.x - 22, y: start.y), maximumDistance: 22) == 0)
        #expect(geometry.timelineFraction(at: CGPoint(x: end.x + 22, y: end.y), maximumDistance: 22) == 1)
    }

    private func makeGeometry(
        size: CGSize,
        orientation: ElasticPlaybackControlBarOrientation,
        direction: ElasticPlaybackControlBarBendDirection = .up,
        center: CGPoint? = nil
    ) -> ElasticPlaybackControlBarGeometry {
        ElasticPlaybackControlBarGeometry(containerSize: size, center: center ?? centeredPoint(in: size),
            utilityCount: 3, bendDirection: direction, orientation: orientation)
    }

    private func centeredPoint(in size: CGSize) -> CGPoint {
        // The top inset is two points larger than the bottom inset.
        CGPoint(x: size.width / 2, y: size.height / 2 + 1)
    }

    private func cardinalAxis(_ orientation: ElasticPlaybackControlBarOrientation) -> CGPoint {
        switch orientation {
        case .right: CGPoint(x: 1, y: 0)
        case .down: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: -1, y: 0)
        case .up: CGPoint(x: 0, y: -1)
        }
    }

    private func boundaryAxisCoordinate(for side: ElasticPlaybackControlBarSide,
        orientation: ElasticPlaybackControlBarOrientation, size: CGSize, length: CGFloat) -> CGFloat {
        let dimension = orientation.isHorizontal ? size.width : size.height
        let leadingInset: CGFloat = orientation == .up ? 16 : 18
        let trailingInset: CGFloat = orientation == .down ? 16 : 18
        return side == .leading ? leadingInset + 28 + length / 2
            : dimension - trailingInset - 28 - length / 2
    }

    private func center(atAxisCoordinate coordinate: CGFloat,
        orientation: ElasticPlaybackControlBarOrientation, size: CGSize) -> CGPoint {
        let middle = centeredPoint(in: size)
        switch orientation {
        case .right: return CGPoint(x: coordinate, y: middle.y)
        case .down: return CGPoint(x: middle.x, y: coordinate)
        case .left: return CGPoint(x: size.width - coordinate, y: middle.y)
        case .up: return CGPoint(x: middle.x, y: size.height - coordinate)
        }
    }

    private func offset(_ point: CGPoint, axis: CGPoint, distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + axis.x * distance, y: point.y + axis.y * distance)
    }

    private func expectPoint(_ actual: CGPoint, near expected: CGPoint, tolerance: CGFloat? = nil) {
        let tolerance = tolerance ?? coordinateTolerance
        #expect(abs(actual.x - expected.x) <= tolerance)
        #expect(abs(actual.y - expected.y) <= tolerance)
    }
}
