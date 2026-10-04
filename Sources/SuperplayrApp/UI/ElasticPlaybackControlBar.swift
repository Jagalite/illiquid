import AVKit
import AppKit
import Foundation
import SuperplayrCore
import SwiftUI

enum ElasticPlaybackControlBarSide: Equatable {
    case leading
    case trailing
}

enum ElasticPlaybackControlBarBendDirection: Equatable {
    case up
    case down
}

enum ElasticPlaybackControlBarOrientation: Int, Equatable {
    case right = 0
    case down = 1
    case left = 2
    case up = 3

    var angle: CGFloat { CGFloat(rawValue) * .pi / 2 }
    var isHorizontal: Bool { self == .right || self == .left }

    func axisCoordinate(of point: CGPoint, in size: CGSize) -> CGFloat {
        switch self {
        case .right: point.x
        case .down: point.y
        case .left: size.width - point.x
        case .up: size.height - point.y
        }
    }

    func normalCoordinate(of point: CGPoint, in size: CGSize) -> CGFloat {
        switch self {
        case .right: point.y
        case .down: size.width - point.x
        case .left: size.height - point.y
        case .up: point.x
        }
    }

    func turned(quarterTurns: Int) -> Self {
        let value = (rawValue + quarterTurns % 4 + 4) % 4
        return Self(rawValue: value) ?? .right
    }
}

struct ElasticPlaybackControlBarPlacement: Codable, Equatable {
    var normalizedX: Double?
    var normalizedY: Double?
    var orientationRawValue: Int
    var bendsUp: Bool

    static let defaultValue = Self(
        normalizedX: nil,
        normalizedY: nil,
        orientationRawValue: ElasticPlaybackControlBarOrientation.right.rawValue,
        bendsUp: true
    )

    var normalizedCenter: CGPoint? {
        get {
            guard let normalizedX, let normalizedY else { return nil }
            return CGPoint(x: normalizedX, y: normalizedY)
        }
        set {
            normalizedX = newValue.map { Double($0.x) }
            normalizedY = newValue.map { Double($0.y) }
        }
    }

    var orientation: ElasticPlaybackControlBarOrientation {
        get {
            ElasticPlaybackControlBarOrientation(rawValue: orientationRawValue)
                ?? .right
        }
        set { orientationRawValue = newValue.rawValue }
    }

    var bendDirection: ElasticPlaybackControlBarBendDirection {
        get { bendsUp ? .up : .down }
        set { bendsUp = newValue == .up }
    }

    var isValid: Bool {
        guard ElasticPlaybackControlBarOrientation(rawValue: orientationRawValue) != nil
        else { return false }
        switch (normalizedX, normalizedY) {
        case (nil, nil):
            return true
        case let (.some(x), .some(y)):
            return x.isFinite && y.isFinite
        default:
            return false
        }
    }
}

enum ElasticPlaybackControlBarPlacementStore {
    static let defaultsKey = "elasticPlaybackControlBarPlacement.v1"

    static func restored(defaults: UserDefaults = .standard) -> ElasticPlaybackControlBarPlacement {
        guard let data = defaults.data(forKey: defaultsKey),
              let placement = try? JSONDecoder().decode(
                  ElasticPlaybackControlBarPlacement.self,
                  from: data
              ),
              placement.isValid
        else { return .defaultValue }
        return placement
    }

    static func persist(
        _ placement: ElasticPlaybackControlBarPlacement,
        defaults: UserDefaults = .standard
    ) {
        guard placement.isValid,
              let data = try? JSONEncoder().encode(placement)
        else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

struct ElasticPlaybackControlBarDeformation: Equatable {
    let side: ElasticPlaybackControlBarSide
    let progress: CGFloat
}

struct ElasticPlaybackControlBarGeometry {
    static let thickness: CGFloat = 56
    static let horizontalInset: CGFloat = 18
    static let topInset: CGFloat = 18
    static let bottomInset: CGFloat = 16
    static let utilitySpacing: CGFloat = 34
    static let edgeAttachmentReleaseProgress: CGFloat = 0.10
    static let edgeAttachmentFullProgress: CGFloat = 0.20
    static let standardTrackingCorrection: CGFloat = 4
    static let detachmentTrackingCorrection: CGFloat = 16

    let containerSize: CGSize
    let center: CGPoint
    let orientation: ElasticPlaybackControlBarOrientation
    let totalLength: CGFloat
    let side: ElasticPlaybackControlBarSide
    let bendDirection: ElasticPlaybackControlBarBendDirection
    let bendProgress: CGFloat
    let timelineStartS: CGFloat
    let timelineEndS: CGFloat
    let trackStartS: CGFloat
    let trackEndS: CGFloat
    let elapsedLabelS: CGFloat
    let durationLabelS: CGFloat
    private(set) var containmentOffset = CGSize.zero
    private(set) var utilityPositions: [CGPoint] = []
    private(set) var surfacePoints: [CGPoint] = []

    init(
        containerSize: CGSize,
        center: CGPoint,
        utilityCount: Int,
        bendDirection: ElasticPlaybackControlBarBendDirection,
        orientation: ElasticPlaybackControlBarOrientation = .right
    ) {
        self.containerSize = containerSize
        self.center = center
        self.bendDirection = bendDirection
        self.orientation = orientation

        let axisMetrics = Self.axisMetrics(for: orientation, in: containerSize)
        let crossMetrics = Self.crossMetrics(for: orientation, in: containerSize)
        let axisLength = min(940, max(axisMetrics.minimumLength, axisMetrics.safeLength))
        let deformation = Self.deformation(
            centerX: orientation.axisCoordinate(of: center, in: containerSize),
            totalLength: axisLength,
            containerWidth: axisMetrics.dimension,
            leadingInset: axisMetrics.leadingInset,
            trailingInset: axisMetrics.trailingInset
        )
        side = deformation.side
        bendProgress = deformation.progress
        let crossLength = min(940, max(crossMetrics.minimumLength, crossMetrics.safeLength))
        let turnedTargetLength = min(axisLength, crossLength)
        let lengthProgress = deformation.progress
            * deformation.progress
            * (3 - 2 * deformation.progress)
        totalLength = axisLength
            + (turnedTargetLength - axisLength) * lengthProgress

        let halfLength = totalLength / 2
        let lastUtilityS = halfLength - 19
        let firstUtilityS = lastUtilityS
            - CGFloat(max(0, utilityCount - 1)) * Self.utilitySpacing
        timelineStartS = -halfLength + 18
        timelineEndS = firstUtilityS - 29
        elapsedLabelS = timelineStartS + 26
        durationLabelS = timelineEndS - 26
        trackStartS = timelineStartS + 64
        trackEndS = max(trackStartS + 40, timelineEndS - 64)

        let rawSurfacePoints = Self.samples(
            from: -halfLength,
            through: halfLength,
            count: 145,
            point: rawPoint(at:)
        )
        containmentOffset = Self.placementOffset(
            for: rawSurfacePoints,
            in: containerSize,
            orientation: orientation,
            side: side,
            edgeAttachmentStrength: Self.edgeAttachmentStrength(
                for: bendProgress
            )
        )
        utilityPositions = (0..<utilityCount).map { index in
            point(at: firstUtilityS + CGFloat(index) * Self.utilitySpacing)
        }
        surfacePoints = rawSurfacePoints.map(applyingContainmentOffset(to:))
    }

    static func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2,
            y: max(Self.thickness / 2, size.height - Self.bottomInset - Self.thickness / 2)
        )
    }

    static func movedCenter(from center: CGPoint, translation: CGSize) -> CGPoint {
        CGPoint(
            x: center.x + translation.width,
            y: center.y + translation.height
        )
    }

    static func normalizedCenter(_ center: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width > 0 ? center.x / size.width : 0.5,
            y: size.height > 0 ? center.y / size.height : 0.5
        )
    }

    static func center(from normalizedCenter: CGPoint?, in size: CGSize) -> CGPoint {
        guard let normalizedCenter else { return defaultCenter(in: size) }
        return CGPoint(
            x: normalizedCenter.x * size.width,
            y: normalizedCenter.y * size.height
        )
    }

    static func avoidingSidebar(
        containerSize: CGSize,
        center: CGPoint,
        utilityCount: Int,
        bendDirection: ElasticPlaybackControlBarBendDirection,
        orientation: ElasticPlaybackControlBarOrientation = .right,
        sidebarOccupiedWidth: CGFloat
    ) -> Self {
        var adjustedCenter = center
        var geometry = Self(
            containerSize: containerSize,
            center: adjustedCenter,
            utilityCount: utilityCount,
            bendDirection: bendDirection,
            orientation: orientation
        )
        let sidebarBoundary = min(
            max(0, sidebarOccupiedWidth),
            max(0, containerSize.width - Self.horizontalInset)
        )

        // Preserve the saved placement exactly until the rendered surface
        // actually intersects the sidebar. Once it does, move the requested
        // center just far enough for the elastic geometry to clear it. A few
        // passes account for the bar bending as it approaches the far edge.
        guard geometry.surfaceBounds.minX < sidebarBoundary else {
            return geometry
        }
        let initialOverlap = sidebarBoundary - geometry.surfaceBounds.minX
        adjustedCenter.x = max(
            adjustedCenter.x + initialOverlap,
            sidebarBoundary + geometry.surfaceBounds.width / 2
        )
        geometry = Self(
            containerSize: containerSize,
            center: adjustedCenter,
            utilityCount: utilityCount,
            bendDirection: bendDirection,
            orientation: orientation
        )
        for _ in 0..<7 {
            let overlap = sidebarBoundary - geometry.surfaceBounds.minX
            guard overlap > 0.25 else { break }
            adjustedCenter.x += overlap
            geometry = Self(
                containerSize: containerSize,
                center: adjustedCenter,
                utilityCount: utilityCount,
                bendDirection: bendDirection,
                orientation: orientation
            )
        }
        if geometry.surfaceBounds.minX < sidebarBoundary - 0.25 {
            adjustedCenter.x = containerSize.width
                + max(containerSize.width, containerSize.height)
            geometry = Self(
                containerSize: containerSize,
                center: adjustedCenter,
                utilityCount: utilityCount,
                bendDirection: bendDirection,
                orientation: orientation
            )
        }
        return geometry
    }

    private static func axisMetrics(
        for orientation: ElasticPlaybackControlBarOrientation,
        in size: CGSize
    ) -> (dimension: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat, safeLength: CGFloat, minimumLength: CGFloat) {
        switch orientation {
        case .right:
            return (size.width, horizontalInset, horizontalInset,
                    size.width - 2 * horizontalInset - thickness, 420)
        case .left:
            return (size.width, horizontalInset, horizontalInset,
                    size.width - 2 * horizontalInset - thickness, 420)
        case .down:
            return (size.height, topInset, bottomInset,
                    size.height - topInset - bottomInset - thickness, 320)
        case .up:
            return (size.height, bottomInset, topInset,
                    size.height - topInset - bottomInset - thickness, 320)
        }
    }

    private static func crossMetrics(
        for orientation: ElasticPlaybackControlBarOrientation,
        in size: CGSize
    ) -> (dimension: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat, safeLength: CGFloat, minimumLength: CGFloat) {
        axisMetrics(for: orientation.isHorizontal ? .down : .right, in: size)
    }

    static func deformation(
        centerX: CGFloat,
        totalLength: CGFloat,
        containerWidth: CGFloat,
        leadingInset: CGFloat = horizontalInset,
        trailingInset: CGFloat = horizontalInset
    ) -> ElasticPlaybackControlBarDeformation {
        let halfLength = totalLength / 2
        let safeLeading = leadingInset + Self.thickness / 2
        let safeTrailing = containerWidth - trailingInset - Self.thickness / 2
        let leadingIntrusion = safeLeading - (centerX - halfLength)
        let trailingIntrusion = centerX + halfLength
            - safeTrailing
        let leadingProgress = bendProgress(
            intrusion: leadingIntrusion,
            totalLength: totalLength
        )
        let trailingProgress = bendProgress(
            intrusion: trailingIntrusion,
            totalLength: totalLength
        )

        if leadingProgress > trailingProgress {
            return ElasticPlaybackControlBarDeformation(
                side: .leading,
                progress: leadingProgress
            )
        }
        return ElasticPlaybackControlBarDeformation(
            side: .trailing,
            progress: trailingProgress
        )
    }

    func point(at s: CGFloat) -> CGPoint {
        applyingContainmentOffset(to: rawPoint(at: s))
    }

    private func rawPoint(at s: CGFloat) -> CGPoint {
        guard s != 0 else { return center }
        let steps = max(1, Int(ceil(abs(s) / 6)))
        let step = s / CGFloat(steps)
        var point = center
        for index in 0..<steps {
            let midpointS = (CGFloat(index) + 0.5) * step
            let angle = tangentAngle(at: midpointS)
            point.x += cos(angle) * step
            point.y += sin(angle) * step
        }
        return point
    }

    func pointOnSurface(fraction: CGFloat) -> CGPoint {
        let halfLength = totalLength / 2
        return point(at: -halfLength + totalLength * Self.clampedUnit(fraction))
    }

    func localOffset(from location: CGPoint, atSurfaceFraction fraction: CGFloat) -> CGPoint {
        let halfLength = totalLength / 2
        let s = -halfLength + totalLength * Self.clampedUnit(fraction)
        let centerlinePoint = point(at: s)
        let angle = tangentAngle(at: s)
        let deltaX = location.x - centerlinePoint.x
        let deltaY = location.y - centerlinePoint.y
        return CGPoint(
            x: deltaX * cos(angle) + deltaY * sin(angle),
            y: -deltaX * sin(angle) + deltaY * cos(angle)
        )
    }

    func grabPoint(surfaceFraction: CGFloat, localOffset: CGPoint) -> CGPoint {
        let halfLength = totalLength / 2
        let s = -halfLength + totalLength * Self.clampedUnit(surfaceFraction)
        let centerlinePoint = point(at: s)
        let angle = tangentAngle(at: s)
        return CGPoint(
            x: centerlinePoint.x
                + localOffset.x * cos(angle)
                - localOffset.y * sin(angle),
            y: centerlinePoint.y
                + localOffset.x * sin(angle)
                + localOffset.y * cos(angle)
        )
    }

    func surfaceFraction(at location: CGPoint, maximumDistance: CGFloat) -> CGFloat? {
        let count = 160
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var nearestFraction: CGFloat = 0.5
        for index in 0...count {
            let fraction = CGFloat(index) / CGFloat(count)
            let candidate = pointOnSurface(fraction: fraction)
            let distance = hypot(candidate.x - location.x, candidate.y - location.y)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestFraction = fraction
            }
        }
        return nearestDistance <= maximumDistance ? nearestFraction : nil
    }

    func containsSurface(_ location: CGPoint) -> Bool {
        surfaceFraction(
            at: location,
            maximumDistance: Self.thickness / 2
        ) != nil
    }

    func trackingCorrectionLimit(for translation: CGSize) -> CGFloat {
        guard bendProgress > 0 else { return Self.standardTrackingCorrection }
        let axisTravel: CGFloat = switch orientation {
        case .right: translation.width
        case .down: translation.height
        case .left: -translation.width
        case .up: -translation.height
        }
        let isPullingInward = side == .trailing ? axisTravel < 0 : axisTravel > 0
        return isPullingInward
            ? Self.detachmentTrackingCorrection
            : Self.standardTrackingCorrection
    }

    static func centerTracking(
        desiredPoint: CGPoint,
        surfaceFraction: CGFloat,
        localOffset: CGPoint = .zero,
        initialCenter: CGPoint,
        containerSize: CGSize,
        utilityCount: Int,
        bendDirection: ElasticPlaybackControlBarBendDirection,
        orientation: ElasticPlaybackControlBarOrientation = .right,
        maximumCorrection: CGFloat? = nil
    ) -> CGPoint {
        let correctionOrigin = initialCenter
        var candidate = initialCenter
        // The containment boundary makes the point-to-center relationship
        // increasingly stiff near an edge. Relaxing each correction avoids
        // overshooting between the free and constrained solutions.
        let relaxation: CGFloat = 0.28
        for _ in 0..<18 {
            let geometry = ElasticPlaybackControlBarGeometry(
                containerSize: containerSize,
                center: candidate,
                utilityCount: utilityCount,
                bendDirection: bendDirection,
                orientation: orientation
            )
            let actualPoint = geometry.grabPoint(
                surfaceFraction: surfaceFraction,
                localOffset: localOffset
            )
            candidate.x += (desiredPoint.x - actualPoint.x) * relaxation
            candidate.y += (desiredPoint.y - actualPoint.y) * relaxation
            if let maximumCorrection {
                let correctionX = candidate.x - correctionOrigin.x
                let correctionY = candidate.y - correctionOrigin.y
                let correctionDistance = hypot(correctionX, correctionY)
                if correctionDistance > maximumCorrection {
                    let scale = maximumCorrection / correctionDistance
                    candidate = CGPoint(
                        x: correctionOrigin.x + correctionX * scale,
                        y: correctionOrigin.y + correctionY * scale
                    )
                }
            }
        }
        return candidate
    }

    var surfaceBounds: CGRect {
        guard let first = surfacePoints.first else { return .zero }
        var bounds = CGRect(origin: first, size: .zero)
        for point in surfacePoints.dropFirst() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
        return bounds.insetBy(dx: -Self.thickness / 2, dy: -Self.thickness / 2)
    }

    func centerAdvancingBendAtTerminalBoundary(
        translation: CGSize
    ) -> CGPoint? {
        guard bendProgress > 0, bendProgress < 0.995 else { return nil }
        let terminal = terminalOrientation
        let terminalTip = pointOnSurface(fraction: side == .trailing ? 1 : 0)
        let radius = Self.thickness / 2
        let boundaryTolerance: CGFloat = 1
        let isAtTerminalBoundary: Bool
        switch terminal {
        case .right:
            isAtTerminalBoundary = terminalTip.x
                >= containerSize.width - Self.horizontalInset - radius - boundaryTolerance
        case .down:
            isAtTerminalBoundary = terminalTip.y
                >= containerSize.height - Self.bottomInset - radius - boundaryTolerance
        case .left:
            isAtTerminalBoundary = terminalTip.x
                <= Self.horizontalInset + radius + boundaryTolerance
        case .up:
            isAtTerminalBoundary = terminalTip.y
                <= Self.topInset + radius + boundaryTolerance
        }
        guard isAtTerminalBoundary else { return nil }

        let terminalAxis = CGPoint(x: cos(terminal.angle), y: sin(terminal.angle))
        let forwardTravel = translation.width * terminalAxis.x
            + translation.height * terminalAxis.y
        guard forwardTravel > 0 else { return nil }

        // The tip cannot travel beyond the player. Feed that forward pointer
        // travel into the current deformation axis instead, while preserving
        // any perpendicular component. This keeps the bar visibly turning
        // until it can rebase into the next cardinal orientation.
        let remainder = CGSize(
            width: translation.width - terminalAxis.x * forwardTravel,
            height: translation.height - terminalAxis.y * forwardTravel
        )
        let orientationAxis = CGPoint(x: cos(orientation.angle), y: sin(orientation.angle))
        let outwardSign: CGFloat = side == .trailing ? 1 : -1
        return CGPoint(
            x: center.x + remainder.width
                + orientationAxis.x * forwardTravel * outwardSign,
            y: center.y + remainder.height
                + orientationAxis.y * forwardTravel * outwardSign
        )
    }

    func tangentAngle(at s: CGFloat) -> CGFloat {
        guard bendProgress > 0 else { return orientation.angle }
        let halfLength = totalLength / 2
        let outwardness: CGFloat
        switch side {
        case .leading:
            outwardness = (halfLength - s) / totalLength
        case .trailing:
            outwardness = (s + halfLength) / totalLength
        }

        // Keep the turn localized enough that the visible elbow can occupy a
        // corner. The previous 28% turn span spread one bend across hundreds
        // of points, leaving the elbow far inside even when the tips touched.
        let propagationSpan: CGFloat = 0.92
        let turnSpan: CGFloat = 1 - propagationSpan
        let propagationThreshold = (1 - Self.clampedUnit(outwardness))
            * propagationSpan
        let localProgress = Self.clampedUnit(
            (bendProgress - propagationThreshold) / turnSpan
        )
        let easedProgress = localProgress * localProgress * (3 - 2 * localProgress)
        let sideSign: CGFloat = side == .trailing ? 1 : -1
        let directionSign: CGFloat = bendDirection == .down ? 1 : -1
        return orientation.angle
            + sideSign * directionSign * (.pi / 2) * easedProgress
    }

    var terminalOrientation: ElasticPlaybackControlBarOrientation {
        let sideTurn = side == .trailing ? 1 : -1
        let directionTurn = bendDirection == .down ? 1 : -1
        return orientation.turned(quarterTurns: sideTurn * directionTurn)
    }

    static func preferredBendDirection(
        at center: CGPoint,
        in size: CGSize,
        orientation: ElasticPlaybackControlBarOrientation
    ) -> ElasticPlaybackControlBarBendDirection {
        let coordinate = orientation.normalCoordinate(of: center, in: size)
        let dimension = orientation.isHorizontal ? size.height : size.width
        return coordinate < dimension / 2 ? .down : .up
    }

    func path(from startS: CGFloat, through endS: CGFloat, samples: Int = 64) -> Path {
        let points = Self.samples(
            from: startS,
            through: endS,
            count: samples,
            point: point(at:)
        )
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    func pointOnTrack(fraction: CGFloat) -> CGPoint {
        point(at: trackStartS + (trackEndS - trackStartS) * Self.clampedUnit(fraction))
    }

    func timelineFraction(at location: CGPoint, maximumDistance: CGFloat) -> CGFloat? {
        let count = 120
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var nearestFraction: CGFloat = 0
        for index in 0...count {
            let fraction = CGFloat(index) / CGFloat(count)
            let candidate = pointOnTrack(fraction: fraction)
            let distance = hypot(candidate.x - location.x, candidate.y - location.y)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestFraction = fraction
            }
        }
        return nearestDistance <= maximumDistance ? nearestFraction : nil
    }

    /// Resolves an ambiguous drag that begins on the timeline. Movement along
    /// the local bar tangent scrubs; movement away from the bar moves the whole
    /// control. A few points of travel are collected before choosing a mode so
    /// pointer noise cannot lock the gesture prematurely.
    func timelineDragPrefersMoving(
        translation: CGSize,
        fraction: CGFloat
    ) -> Bool? {
        guard hypot(translation.width, translation.height) >= 6 else { return nil }
        let s = trackStartS + (trackEndS - trackStartS) * Self.clampedUnit(fraction)
        let angle = tangentAngle(at: s)
        let tangentTravel = abs(
            translation.width * cos(angle) + translation.height * sin(angle)
        )
        let normalTravel = abs(
            -translation.width * sin(angle) + translation.height * cos(angle)
        )
        return normalTravel > tangentTravel * 0.75
    }

    private static func samples(
        from start: CGFloat,
        through end: CGFloat,
        count: Int,
        point: (CGFloat) -> CGPoint
    ) -> [CGPoint] {
        guard count > 1 else { return [point(start)] }
        return (0..<count).map { index in
            let fraction = CGFloat(index) / CGFloat(count - 1)
            return point(start + (end - start) * fraction)
        }
    }

    private static func clampedUnit(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private static func bendProgress(
        intrusion: CGFloat,
        totalLength: CGFloat
    ) -> CGFloat {
        let travel = max(1, totalLength)
        let progress = max(0, intrusion / travel)

        // Build and preserve an L through the first 45% of edge travel. Only
        // after its elbow can reach the corner does additional outward travel
        // accelerate the remaining turn into a fully vertical bar.
        let elbowTravel: CGFloat = 0.45
        guard progress > elbowTravel else { return progress }
        let completion = clampedUnit((progress - elbowTravel) / 0.30)
        let easedCompletion = completion * completion * (3 - 2 * completion)
        return elbowTravel + (1 - elbowTravel) * easedCompletion
    }

    static func edgeAttachmentStrength(for bendProgress: CGFloat) -> CGFloat {
        let range = edgeAttachmentFullProgress - edgeAttachmentReleaseProgress
        guard range > 0 else { return bendProgress > 0 ? 1 : 0 }
        let progress = clampedUnit(
            (bendProgress - edgeAttachmentReleaseProgress) / range
        )
        return progress * progress * (3 - 2 * progress)
    }

    private static func placementOffset(
        for points: [CGPoint],
        in size: CGSize,
        orientation: ElasticPlaybackControlBarOrientation,
        side: ElasticPlaybackControlBarSide,
        edgeAttachmentStrength: CGFloat
    ) -> CGSize {
        guard let first = points.first else { return .zero }
        var bounds = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }

        let radius = thickness / 2
        let minimumX = horizontalInset + radius
        let maximumX = size.width - horizontalInset - radius
        let minimumY = topInset + radius
        let maximumY = size.height - bottomInset - radius
        var containment = CGSize.zero

        if bounds.minX < minimumX {
            containment.width = minimumX - bounds.minX
        } else if bounds.maxX > maximumX {
            containment.width = maximumX - bounds.maxX
        }

        if bounds.minY < minimumY {
            containment.height = minimumY - bounds.minY
        } else if bounds.maxY > maximumY {
            containment.height = maximumY - bounds.maxY
        }

        guard edgeAttachmentStrength > 0 else { return containment }

        // A bend belongs to the side that produced it. Ease that side away
        // from its contacted edge as the bend straightens, but never alter the
        // coordinate along the edge. This keeps strong partial Ls attached
        // without recreating the old hard detachment or corner snap.
        let containedBounds = bounds.offsetBy(
            dx: containment.width,
            dy: containment.height
        )
        switch (orientation, side) {
        case (.right, .trailing), (.left, .leading):
            containment.width += (maximumX - containedBounds.maxX)
                * edgeAttachmentStrength
        case (.right, .leading), (.left, .trailing):
            containment.width += (minimumX - containedBounds.minX)
                * edgeAttachmentStrength
        case (.down, .trailing), (.up, .leading):
            containment.height += (maximumY - containedBounds.maxY)
                * edgeAttachmentStrength
        case (.down, .leading), (.up, .trailing):
            containment.height += (minimumY - containedBounds.minY)
                * edgeAttachmentStrength
        }

        return containment
    }

    private func applyingContainmentOffset(to point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x + containmentOffset.width,
            y: point.y + containmentOffset.height
        )
    }
}

struct ElasticPlaybackControlBarShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        _ = rect
        var centerline = Path()
        guard let first = points.first else { return centerline }
        centerline.move(to: first)
        for point in points.dropFirst() {
            centerline.addLine(to: point)
        }
        return centerline.strokedPath(
            StrokeStyle(
                lineWidth: ElasticPlaybackControlBarGeometry.thickness,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}

struct TimelineThumbnailPlacement {
    static let cardSize = CGSize(width: 184, height: 112)
    static let edgeInset: CGFloat = 12
    static let gap: CGFloat = 10

    static func frame(
        anchor: CGPoint,
        tangentAngle: CGFloat,
        surfacePoints: [CGPoint],
        containerSize: CGSize,
        cardSize: CGSize = cardSize
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: anchor, size: cardSize)
        }

        let normal = CGPoint(x: -sin(tangentAngle), y: cos(tangentAngle))
        let projectedHalfExtent = abs(normal.x) * cardSize.width / 2
            + abs(normal.y) * cardSize.height / 2
        let offset = ElasticPlaybackControlBarGeometry.thickness / 2
            + gap
            + projectedHalfExtent
        let containerCenter = CGPoint(
            x: containerSize.width / 2,
            y: containerSize.height / 2
        )

        func candidate(sign: CGFloat) -> (frame: CGRect, score: CGFloat) {
            let rawCenter = CGPoint(
                x: anchor.x + normal.x * offset * sign,
                y: anchor.y + normal.y * offset * sign
            )
            let rawFrame = CGRect(
                x: rawCenter.x - cardSize.width / 2,
                y: rawCenter.y - cardSize.height / 2,
                width: cardSize.width,
                height: cardSize.height
            )
            let maximumX = max(edgeInset, containerSize.width - edgeInset - cardSize.width)
            let maximumY = max(edgeInset, containerSize.height - edgeInset - cardSize.height)
            let clampedFrame = CGRect(
                x: min(max(rawFrame.minX, edgeInset), maximumX),
                y: min(max(rawFrame.minY, edgeInset), maximumY),
                width: cardSize.width,
                height: cardSize.height
            )
            let clampDistance = hypot(
                clampedFrame.midX - rawCenter.x,
                clampedFrame.midY - rawCenter.y
            )
            let protectedFrame = clampedFrame.insetBy(dx: -gap, dy: -gap)
            let surfaceOverlap = CGFloat(surfacePoints.lazy.filter {
                protectedFrame.contains($0)
            }.count)
            let inwardDistance = hypot(
                clampedFrame.midX - containerCenter.x,
                clampedFrame.midY - containerCenter.y
            )
            return (
                clampedFrame,
                clampDistance * 1_000 + surfaceOverlap * 100 + inwardDistance * 0.01
            )
        }

        let positive = candidate(sign: 1)
        let negative = candidate(sign: -1)
        return positive.score < negative.score ? positive.frame : negative.frame
    }
}

private struct ElasticPlaybackControlBarSurface: View {
    let shape: ElasticPlaybackControlBarShape
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.playerTheme) private var theme

    @ViewBuilder
    var body: some View {
        switch theme.surfaceStyle {
        case .liquidGlass:
            Color.clear
                .glassEffect(.clear.interactive(), in: shape)
                .overlay {
                    shape.stroke(
                        theme.primaryColor.opacity(reduceTransparency ? 0.12 : 0.2),
                        lineWidth: 0.75
                    )
                }
                .shadow(
                    color: .black.opacity(reduceTransparency ? 0.1 : 0.2),
                    radius: theme.surfaceShadowRadius,
                    y: 4
                )
        case .classicMaterial:
            shape
                .fill(.regularMaterial)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
        case .solid:
            shape
                .fill(theme.surfaceColor(for: .sidebar))
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
        }
    }
}

private struct ElasticPlaybackTimelineArtwork: View {
    @Bindable var model: AppModel
    let geometry: ElasticPlaybackControlBarGeometry
    @Environment(\.playerTheme) private var theme

    var body: some View {
        Canvas { context, _ in
            let duration = model.state.duration
            let positionFraction = duration > 0
                ? CGFloat(min(max(model.state.position / duration, 0), 1))
                : 0
            let bufferFraction = CGFloat(
                PlaybackTimelineInteraction.bufferFraction(model.state.bufferStatus)
            )
            let accent = theme == .liquidGlass
                ? Color(red: 0.78, green: 0.80, blue: 0.82)
                : theme.accentColor

            context.stroke(
                geometry.path(from: geometry.trackStartS, through: geometry.trackEndS),
                with: .color(theme.secondaryColor.opacity(0.34)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )

            if bufferFraction > 0 {
                let bufferEnd = geometry.trackStartS
                    + (geometry.trackEndS - geometry.trackStartS) * bufferFraction
                context.stroke(
                    geometry.path(from: geometry.trackStartS, through: bufferEnd),
                    with: .color(accent.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }

            let progressEnd = geometry.trackStartS
                + (geometry.trackEndS - geometry.trackStartS) * positionFraction
            context.stroke(
                geometry.path(from: geometry.trackStartS, through: progressEnd),
                with: .color(accent),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )

            if duration > 0 {
                for chapter in model.state.chapters
                where chapter.startTime > 0 && chapter.startTime < duration {
                    let fraction = CGFloat(chapter.startTime / duration)
                    let marker = geometry.pointOnTrack(fraction: fraction)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: marker.x - 1.5,
                            y: marker.y - 1.5,
                            width: 3,
                            height: 3
                        )),
                        with: .color(theme.primaryColor.opacity(0.72))
                    )
                }
            }

            if duration > 0 {
                for (label, time) in [("A", model.loopStart), ("B", model.loopEnd)] {
                    if let time {
                        let point = geometry.pointOnTrack(fraction: CGFloat(min(max(time / duration, 0), 1)))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(accent))
                        context.draw(Text(label).font(.caption2.bold()).foregroundStyle(theme.primaryColor),
                            at: CGPoint(x: point.x, y: point.y - 12))
                    }
                }
            }

            let knob = geometry.pointOnTrack(fraction: positionFraction)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: knob.x - 5,
                    y: knob.y - 5,
                    width: 10,
                    height: 10
                )),
                with: .color(theme.primaryColor)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ElasticPlaybackTimelineAccessibility: View {
    @Bindable var model: AppModel
    let geometry: ElasticPlaybackControlBarGeometry

    var body: some View {
        let bounds = geometry.path(from: geometry.trackStartS, through: geometry.trackEndS)
            .boundingRect.insetBy(dx: -10, dy: -16)
        Color.clear
        .frame(width: max(44, bounds.width), height: max(44, bounds.height))
        .allowsHitTesting(false)
        .focusable()
        .playbackFocusVisibility(model)
        .onKeyPress(.leftArrow) { model.player.seek(to: max(0, model.state.position - 1)); return .handled }
        .onKeyPress(.rightArrow) { model.player.seek(to: min(model.state.duration, model.state.position + 1)); return .handled }
        .accessibilityRepresentation {
            Slider(value: Binding(
                get: { min(max(model.state.position, 0), max(model.state.duration, 1)) },
                set: { position in
                    guard model.state.duration > 0 else { return }
                    model.player.seek(to: position)
                    model.registerUserActivity()
                }
            ), in: 0...max(model.state.duration, 1), step: 1) {
                Text("Playback position")
            }
            .accessibilityValue("\(TimecodeFormatter.string(from: model.state.position)) of \(TimecodeFormatter.string(from: model.state.duration))")
            .disabled(model.state.duration <= 0)
        }
        .position(x: bounds.midX, y: bounds.midY)
    }
}

/// Keeps passive playback ticks from rebuilding the deforming surface and its
/// utility controls while the bar is being manipulated.
private struct ElasticPlaybackTimelineLabels: View {
    @Bindable var model: AppModel
    let geometry: ElasticPlaybackControlBarGeometry
    @Binding var showsRemainingDuration: Bool
    @Environment(\.playerTheme) private var theme

    var body: some View {
        ZStack {
            Text(TimecodeFormatter.string(from: model.state.position))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 52)
                .dynamicPlayerTextStyle(role: .secondary)
                .position(geometry.point(at: geometry.elapsedLabelS))

            Button {
                showsRemainingDuration.toggle()
            } label: {
                Text(PlaybackTimelineInteraction.durationLabel(
                    position: model.state.position,
                    duration: model.state.duration,
                    showsRemaining: showsRemainingDuration
                ))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 52, height: 30)
                .dynamicPlayerTextStyle(role: .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Toggle total and remaining time")
            .accessibilityLabel("Playback duration")
            .position(geometry.point(at: geometry.durationLabelS))
        }
    }
}

private struct ElasticTimelineThumbnailPreview: View {
    let image: CGImage?
    let position: TimeInterval
    let isLoading: Bool
    @Environment(\.playerTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.82)

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.86))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Preview unavailable")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Text(TimecodeFormatter.string(from: position))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.68), in: Capsule())
                .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.primaryColor.opacity(0.24), lineWidth: 0.75)
        }
        .padding(4)
        .playerOverlaySurface(cornerRadius: 13, role: .status)
        .shadow(color: .black.opacity(0.34), radius: 10, y: 5)
        .accessibilityHidden(true)
    }
}

private struct ElasticTimelineHoverPreviewState {
    let requestID: Int
    let bucket: Int
    var fraction: CGFloat
    var position: TimeInterval
    var image: CGImage?
    var isLoading = true
}

enum TimelineThumbnailHoverPolicy {
    static let cacheMissDelay: Duration = .milliseconds(40)

    /// A timed-out native call can release its worker just after the caller
    /// expires. Retry once while this hover still owns the request; never loop
    /// indefinitely on unsupported media or seek the active playback session.
    @MainActor
    static func image(
        retryDelay: Duration = .milliseconds(150),
        decode: () async -> CGImage?
    ) async -> CGImage? {
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            let image = await decode()
            guard !Task.isCancelled else { return nil }
            if let image { return image }
            if attempt == 0 {
                do { try await Task.sleep(for: retryDelay) }
                catch { return nil }
            }
        }
        return nil
    }
}

enum ElasticPlaybackUtility: Hashable {
    case volume
    case audio
    case subtitles
    case sidebar
    case pictureInPicture
    case settings
    case more

    static func fitting(_ utilities: [Self], length: CGFloat) -> [Self] {
        // Reserve two time labels, a useful seek track, and their padding.
        let requiredLength = 234 + CGFloat(max(0, utilities.count - 1))
            * ElasticPlaybackControlBarGeometry.utilitySpacing
        return length >= requiredLength
            ? utilities
            : utilities.filter { $0 == .volume || $0 == .sidebar || $0 == .more }
    }
}

private enum ElasticPlaybackGestureMode: Equatable {
    case pendingTimeline
    case move
    case scrub
}

/// A custom playback surface whose centerline deforms continuously as its
/// pointer-tracked center approaches either side of the player.
struct ElasticPlaybackControlBar: View {
    @Bindable var model: AppModel

    private let sidebarOccupiedWidth: CGFloat
    private let placementDefaults: UserDefaults
    @State private var placement: ElasticPlaybackControlBarPlacement
    @State private var dragStartCenter: CGPoint?
    @State private var dragLastLocation: CGPoint?
    @State private var dragGrabFraction: CGFloat?
    @State private var dragGrabLocalOffset = CGPoint.zero
    @State private var dragTimelineFraction: CGFloat?
    @State private var draggedCenter: CGPoint?
    @State private var gestureMode: ElasticPlaybackGestureMode?
    @State private var transaction: TimelineGestureTransaction?
    @State private var gestureStartPlacement: ElasticPlaybackControlBarPlacement?
    @State private var rejectsCurrentDrag = false
    @GestureState private var isDragRecognized = false
    @State private var isVolumePopoverPresented = false
    @State private var isPointerOverBar = false
    @State private var showsRemainingDuration = false
    @State private var timelineHoverPreview: ElasticTimelineHoverPreviewState?
    @State private var timelineThumbnailTask: Task<Void, Never>?
    @State private var timelineThumbnailRequestID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerTheme) private var theme

    init(
        model: AppModel,
        sidebarOccupiedWidth: CGFloat = 0,
        placementDefaults: UserDefaults = .standard
    ) {
        self.model = model
        self.sidebarOccupiedWidth = sidebarOccupiedWidth
        self.placementDefaults = placementDefaults
        _placement = State(initialValue: ElasticPlaybackControlBarPlacementStore.restored(
            defaults: placementDefaults
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = draggedCenter
                ?? ElasticPlaybackControlBarGeometry.center(
                    from: normalizedCenter,
                    in: size
                )
            let fullGeometry = ElasticPlaybackControlBarGeometry.avoidingSidebar(
                containerSize: size,
                center: center,
                utilityCount: activeUtilities.count,
                bendDirection: bendDirection,
                orientation: orientation,
                sidebarOccupiedWidth: sidebarOccupiedWidth
            )
            let utilities = ElasticPlaybackUtility.fitting(activeUtilities, length: fullGeometry.totalLength)
            let geometry = utilities.count == activeUtilities.count ? fullGeometry
                : ElasticPlaybackControlBarGeometry.avoidingSidebar(
                    containerSize: size, center: center, utilityCount: utilities.count,
                    bendDirection: bendDirection, orientation: orientation,
                    sidebarOccupiedWidth: sidebarOccupiedWidth
                )
            let shape = ElasticPlaybackControlBarShape(points: geometry.surfacePoints)

            ZStack {
                ElasticPlaybackControlBarSurface(shape: shape)
                    .allowsHitTesting(false)

                // Only the background owns movement and scrubbing. Buttons
                // above it retain their native press/release tracking.
                shape.fill(Color.clear)
                    .contentShape(shape)
                    .gesture(barDragGesture(
                        geometry: geometry,
                        size: size,
                        utilityCount: utilities.count
                    ))
                    .accessibilityHidden(true)

                ElasticPlaybackTimelineArtwork(model: model, geometry: geometry)

                ElasticPlaybackTimelineAccessibility(model: model, geometry: geometry)

                ElasticPlaybackTimelineLabels(
                    model: model,
                    geometry: geometry,
                    showsRemainingDuration: $showsRemainingDuration
                )

                ForEach(Array(utilities.enumerated()), id: \.offset) { index, utility in
                    utilityControl(utility, popoverEdge: popoverEdge(for: geometry))
                        .playbackFocusVisibility(model)
                        .position(geometry.utilityPositions[index])
                        .dynamicPlayerTextStyle(
                            contrastRegion: .local,
                            appliesControlTint: true
                        )
                }

                if let preview = timelineHoverPreview {
                    let anchor = geometry.pointOnTrack(fraction: preview.fraction)
                    let trackS = geometry.trackStartS
                        + (geometry.trackEndS - geometry.trackStartS) * preview.fraction
                    let previewFrame = TimelineThumbnailPlacement.frame(
                        anchor: anchor,
                        tangentAngle: geometry.tangentAngle(at: trackS),
                        surfacePoints: geometry.surfacePoints,
                        containerSize: size
                    )
                    ElasticTimelineThumbnailPreview(
                        image: preview.image,
                        position: preview.position,
                        isLoading: preview.isLoading
                    )
                    .frame(
                        width: TimelineThumbnailPlacement.cardSize.width,
                        height: TimelineThumbnailPlacement.cardSize.height
                    )
                    .position(x: previewFrame.midX, y: previewFrame.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    updateTimelineHover(at: location, geometry: geometry)
                    updatePointerHover(geometry.containsSurface(location))
                case .ended:
                    clearTimelineHover()
                    updatePointerHover(false)
                }
            }
            .accessibilityIdentifier("elastic-playback-control-bar")
        }
        .environment(\.colorScheme, theme.preferredColorScheme)
        .onChange(of: isVolumePopoverPresented) { _, isPresented in
            model.setChromePin(.volumePopover, active: isPresented)
            model.setTransientPresentation(isPresented, owner: "elastic-volume")
        }
        .onChange(of: model.player.interactionSourceRevision) {
            cancelGesture(restorePosition: false)
            clearTimelineHover()
        }
        .onChange(of: model.interactionCancellationRevision) { cancelGesture() }
        .onChange(of: model.controlsPositionRevision) {
            cancelGesture()
            placement = .defaultValue
            persistPlacement()
        }
        .onChange(of: isDragRecognized) { _, active in
            if !active, gestureMode != nil { cancelGesture() }
            if !active { rejectsCurrentDrag = false }
        }
        .onDisappear {
            cancelGesture()
            clearTimelineHover()
            persistPlacement()
            model.setChromePin(.chromeDrag, active: false)
            model.setChromePin(.scrubbing, active: false)
            model.setChromePin(.pointerOverChrome, active: false)
            if isVolumePopoverPresented {
                model.setChromePin(.volumePopover, active: false)
                model.setTransientPresentation(false, owner: "elastic-volume")
            }
        }
    }

    private var normalizedCenter: CGPoint? {
        get { placement.normalizedCenter }
        nonmutating set {
            var updated = placement
            updated.normalizedCenter = newValue
            placement = updated
        }
    }

    private func updatePointerHover(_ isHovering: Bool) {
        guard isPointerOverBar != isHovering else { return }
        isPointerOverBar = isHovering
        model.setPointerRegion(isHovering ? .chrome : .video)
        model.setChromePin(.pointerOverChrome, active: isHovering)
    }

    private func updateTimelineHover(
        at location: CGPoint,
        geometry: ElasticPlaybackControlBarGeometry
    ) {
        guard gestureMode == nil,
              model.state.duration > 0,
              model.state.videoAspectRatio != nil,
              let fraction = geometry.timelineFraction(
                  at: location,
                  maximumDistance: 16
              )
        else {
            clearTimelineHover()
            return
        }

        let position = model.state.duration * Double(fraction)
        let bucket = Int((position * 2).rounded())
        if var preview = timelineHoverPreview, preview.bucket == bucket {
            preview.fraction = fraction
            preview.position = position
            timelineHoverPreview = preview
            return
        }

        timelineThumbnailTask?.cancel()
        timelineThumbnailRequestID += 1
        let requestID = timelineThumbnailRequestID
        let retainedImage = timelineHoverPreview?.image
        timelineHoverPreview = ElasticTimelineHoverPreviewState(
            requestID: requestID,
            bucket: bucket,
            fraction: fraction,
            position: position,
            image: retainedImage
        )
        timelineThumbnailTask = Task { @MainActor in
            let maximumPixelSize = CGSize(width: 368, height: 208)
            let image = await TimelineThumbnailHoverPolicy.image {
                await model.player.timelineThumbnail(
                    at: position,
                    maximumPixelSize: maximumPixelSize,
                    delayBeforeDecoding: TimelineThumbnailHoverPolicy.cacheMissDelay
                )
            }
            guard !Task.isCancelled,
                  var preview = timelineHoverPreview,
                  preview.requestID == requestID
            else { return }
            preview.image = image
            preview.isLoading = false
            timelineHoverPreview = preview
        }
    }

    private func clearTimelineHover() {
        timelineThumbnailTask?.cancel()
        timelineThumbnailTask = nil
        timelineHoverPreview = nil
    }

    private var bendDirection: ElasticPlaybackControlBarBendDirection {
        get { placement.bendDirection }
        nonmutating set {
            var updated = placement
            updated.bendDirection = newValue
            placement = updated
        }
    }

    private var orientation: ElasticPlaybackControlBarOrientation {
        get { placement.orientation }
        nonmutating set {
            var updated = placement
            updated.orientation = newValue
            placement = updated
        }
    }

    private func persistPlacement() {
        ElasticPlaybackControlBarPlacementStore.persist(
            placement,
            defaults: placementDefaults
        )
    }

    private var activeUtilities: [ElasticPlaybackUtility] {
        var utilities: [ElasticPlaybackUtility] = [
            .volume,
            .audio,
            .subtitles,
            .sidebar,
        ]
        if model.canTogglePictureInPicture {
            utilities.append(.pictureInPicture)
        }
        utilities.append(contentsOf: [.settings, .more])
        return utilities
    }

    @ViewBuilder
    private func utilityControl(
        _ utility: ElasticPlaybackUtility,
        popoverEdge: Edge,
        inMenu: Bool = false
    ) -> some View {
        switch utility {
        case .volume:
            Button {
                isVolumePopoverPresented.toggle()
            } label: {
                compactMenuLabel(
                    model.state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: "Volume",
                    animatesSymbolReplacement: true
                )
            }
            .buttonStyle(.borderless)
            .help("Volume")
            .accessibilityLabel("Volume")
            .popover(isPresented: $isVolumePopoverPresented, arrowEdge: popoverEdge) {
                VolumePopover(model: model)
                    .background(PopoverDismissalBoundary { isVolumePopoverPresented = false })
            }

        case .audio:
            Menu {
                if model.state.audioTracks.isEmpty {
                    Text("No audio tracks")
                } else {
                    ForEach(model.state.audioTracks) { track in
                        Button {
                            model.selectAudioTrackFromUser(track)
                        } label: {
                            menuSelectionLabel(
                                track.displayName,
                                selected: track.id == model.state.selectedAudioTrack?.id
                            )
                        }
                    }
                }
            } label: {
                if inMenu {
                    Text("Audio Track")
                } else {
                    compactMenuLabel("waveform", title: "Audio Track")
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Audio Track")
            .accessibilityLabel("Audio Track")

        case .subtitles:
            Menu {
                Button {
                    model.selectSubtitleTrackFromUser(nil)
                } label: {
                    menuSelectionLabel(
                        "Off",
                        selected: model.state.selectedSubtitleTrack == nil
                    )
                }
                Divider()
                ForEach(model.state.subtitleTracks) { track in
                    Button {
                        model.selectSubtitleTrackFromUser(track)
                    } label: {
                        menuSelectionLabel(
                            track.displayName,
                            selected: track.id == model.state.selectedSubtitleTrack?.id
                        )
                    }
                }
                Divider()
                Section("Timing for This Video") {
                    Text("Current: \(SubtitleDelayInput.displayText(for: model.state.subtitleDelay))")
                    Button("Set Subtitle Delay…", action: model.openSubtitleDelayPanel)
                    Button("Reset Subtitle Delay") {
                        model.setSubtitleDelayFromUser(0)
                    }
                    .disabled(abs(model.state.subtitleDelay) < 0.001)
                }
                Divider()
                Button("Load External Subtitle…", action: model.openSubtitlePanel)
            } label: {
                if inMenu {
                    Text("Subtitles")
                } else {
                    compactMenuLabel("captions.bubble", title: "Subtitles")
                    .playbackControlSelectionTint(
                        SubtitleControlVisualState(
                            selectedTrack: model.state.selectedSubtitleTrack
                        ).usesAccentTint,
                        accent: theme.accentColor
                    )
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Subtitles")
            .accessibilityLabel("Subtitles")
            .accessibilityValue(SubtitleControlVisualState(
                selectedTrack: model.state.selectedSubtitleTrack
            ).accessibilityValue)

        case .sidebar:
            iconButton(
                SidebarToggleControlPolicy.title(
                    isSidebarVisible: model.isSidebarPresented
                ),
                systemImage: "sidebar.left",
                action: model.toggleSidebar
            )
            .disabled(!model.isSidebarAvailable)
            .help(model.isSidebarAvailable ? "Sources" : "Widen the window to show Sources")

        case .pictureInPicture:
            iconButton(
                model.state.pictureInPicture.isActive
                    ? "Stop Picture in Picture"
                    : "Start Picture in Picture",
                image: Image(nsImage: model.state.pictureInPicture.isActive
                    ? AVPictureInPictureController.pictureInPictureButtonStopImage
                    : AVPictureInPictureController.pictureInPictureButtonStartImage),
                action: model.togglePictureInPicture
            )

        case .settings:
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .frame(width: 30, height: 38)
                    .contentShape(Circle())
                    .playerIconHoverEffect(
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                        highlightInsets: PlayerControlHoverPolicy.bottomIslandHighlightInsets
                    )
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")

        case .more:
            Menu {
                // Keep compacted controls reachable without shrinking hit targets.
                AnyView(utilityControl(.audio, popoverEdge: popoverEdge, inMenu: true))
                AnyView(utilityControl(.subtitles, popoverEdge: popoverEdge, inMenu: true))
                if model.canTogglePictureInPicture {
                    Button(model.state.pictureInPicture.isActive
                        ? "Stop Picture in Picture" : "Start Picture in Picture",
                        action: model.togglePictureInPicture)
                }
                SettingsLink { Text("Settings…") }
                Divider()
                if !model.state.chapters.isEmpty {
                    Section("Chapters") {
                        ForEach(model.state.chapters) { chapter in
                            Button {
                                model.player.selectChapter(chapter)
                            } label: {
                                menuSelectionLabel(
                                    chapter.title ?? "Chapter \(chapter.id + 1)",
                                    selected: chapter.id == model.state.currentChapterID
                                )
                            }
                        }
                    }
                    Divider()
                }

                Toggle("Lock Controls Position", isOn: $model.isControlsPositionLocked)
                Button("Reset Controls Position", action: model.resetControlsPosition)
                Button("Controls Help…") { model.isShortcutHelpPresented = true }
                Divider()
                Button("Fit Window to Video", action: model.fitWindowToVideo)
                    .disabled(!model.canFitWindowToVideo)

                if model.player.supports(.saveScreenshot) {
                    Button("Save Screenshot…", action: model.saveScreenshot)
                        .disabled(model.state.currentSource == nil)
                }

                Button("Playback Inspector…") {
                    model.isInspectorPresented = true
                }

                Divider()

                if model.player.supports(.changePlaybackSpeed) {
                    Section("Playback Speed") {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                            Button {
                                model.player.setPlaybackSpeed(speed)
                            } label: {
                                menuSelectionLabel(
                                    String(format: "%g×", speed),
                                    selected: abs(model.state.playbackSpeed - speed) < 0.001
                                )
                            }
                        }
                    }
                }

                Section("Track Sync") {
                    if model.player.supports(.changeAudioDelay) {
                        Button("Audio −0.1 s") {
                            model.player.setAudioDelay(model.state.audioDelay - 0.1)
                        }
                        Button("Reset Audio Delay") {
                            model.player.setAudioDelay(0)
                        }
                        .disabled(abs(model.state.audioDelay) < 0.001)
                        Button("Audio +0.1 s") {
                            model.player.setAudioDelay(model.state.audioDelay + 0.1)
                        }
                        Divider()
                    }

                    if model.player.supports(.changeSubtitleDelay) {
                        Text(
                            "Subtitle Delay: \(SubtitleDelayInput.displayText(for: model.state.subtitleDelay))"
                        )
                        Button("Set Subtitle Delay…", action: model.openSubtitleDelayPanel)
                        Button("Reset Subtitle Delay") {
                            model.setSubtitleDelayFromUser(0)
                        }
                        .disabled(abs(model.state.subtitleDelay) < 0.001)
                    }
                }
            } label: {
                compactMenuLabel("ellipsis", title: "More Playback Controls")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More Playback Controls")
            .accessibilityLabel("More Playback Controls")
        }
    }

    private func iconButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        iconButton(title, image: Image(systemName: systemImage), action: action)
    }

    private func iconButton(
        _ title: String,
        image: Image,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            image
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 17, height: 17)
                .frame(width: 30, height: 38)
                .contentShape(Circle())
                .playerIconHoverEffect(
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                    highlightInsets: PlayerControlHoverPolicy.bottomIslandHighlightInsets
                )
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }

    private func compactMenuLabel(
        _ systemImage: String,
        title: String,
        animatesSymbolReplacement: Bool = false
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .contentTransition(
                animatesSymbolReplacement ? .symbolEffect(.replace) : .identity
            )
            .animation(
                animatesSymbolReplacement
                    ? PlatinumMotion.stateMorph(reduceMotion: reduceMotion)
                    : nil,
                value: systemImage
            )
            .frame(width: 30, height: 38)
            .contentShape(Rectangle())
            .playerIconHoverEffect(
                in: RoundedRectangle(cornerRadius: 7, style: .continuous),
                highlightInsets: PlayerControlHoverPolicy.bottomIslandHighlightInsets
            )
            .accessibilityLabel(title)
    }

    private func menuSelectionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Image(systemName: "checkmark")
                .opacity(selected ? 1 : 0)
            Text(title)
        }
    }

    private func popoverEdge(for geometry: ElasticPlaybackControlBarGeometry) -> Edge {
        guard geometry.bendProgress > 0.15 else {
            return geometry.center.y < geometry.containerSize.height / 2 ? .bottom : .top
        }
        return geometry.side == .leading ? .trailing : .leading
    }

    private func barDragGesture(
        geometry: ElasticPlaybackControlBarGeometry,
        size: CGSize,
        utilityCount: Int
    ) -> some Gesture {
        // Capture authority at press-down so even a stationary click cannot
        // seek a replacement source that arrives before release.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isDragRecognized) { _, active, _ in active = true }
            .onChanged { value in
                guard !rejectsCurrentDrag else { return }
                if gestureMode == nil {
                    // Child controls own their entire press, including drag-off.
                    guard !geometry.utilityPositions.contains(where: {
                        abs($0.x - value.startLocation.x) < 24 && abs($0.y - value.startLocation.y) < 24
                    }) else { rejectsCurrentDrag = true; return }
                    gestureStartPlacement = placement
                    transaction = TimelineGestureTransaction(sourceRevision: model.player.interactionSourceRevision,
                        origin: model.state.position, duration: model.state.duration)
                    clearTimelineHover()
                    if model.state.duration > 0,
                       let timelineFraction = geometry.timelineFraction(
                           at: value.startLocation,
                           maximumDistance: 22
                       ) {
                        gestureMode = .pendingTimeline
                        dragTimelineFraction = timelineFraction
                        model.setChromePin(.scrubbing, active: true)
                    } else {
                        guard !model.isControlsPositionLocked else { rejectsCurrentDrag = true; return }
                        beginMovingBar(
                            geometry: geometry,
                            startLocation: value.startLocation,
                            size: size
                        )
                    }
                    model.registerUserActivity()
                }

                if gestureMode == .pendingTimeline,
                   hypot(value.translation.width, value.translation.height) >= 6 {
                    gestureMode = .scrub
                    model.setChromePin(.scrubbing, active: true)
                }

                switch gestureMode {
                case .pendingTimeline:
                    break
                case .move:
                    guard let dragStartCenter, let dragGrabFraction else { return }
                    let previousLocation = dragLastLocation ?? value.startLocation
                    let incrementalTranslation = CGSize(
                        width: value.location.x - previousLocation.x,
                        height: value.location.y - previousLocation.y
                    )
                    let currentCenter = draggedCenter ?? dragStartCenter
                    dragLastLocation = value.location
                    if let advancingCenter = geometry.centerAdvancingBendAtTerminalBoundary(
                        translation: incrementalTranslation
                    ) {
                        _ = applyTrackedCenter(
                            advancingCenter,
                            size: size,
                            utilityCount: utilityCount,
                            bendDirection: bendDirection
                        )
                        break
                    }
                    let incrementalCenter = ElasticPlaybackControlBarGeometry.movedCenter(
                        from: currentCenter,
                        translation: incrementalTranslation
                    )
                    let direction = stableBendDirection(
                        at: incrementalCenter,
                        size: size,
                        utilityCount: utilityCount
                    )
                    bendDirection = direction
                    let trackedCenter = ElasticPlaybackControlBarGeometry.centerTracking(
                        desiredPoint: value.location,
                        surfaceFraction: dragGrabFraction,
                        localOffset: dragGrabLocalOffset,
                        initialCenter: incrementalCenter,
                        containerSize: size,
                        utilityCount: utilityCount,
                        bendDirection: direction,
                        orientation: orientation,
                        maximumCorrection: geometry.trackingCorrectionLimit(
                            for: incrementalTranslation
                        )
                    )
                    _ = applyTrackedCenter(
                        trackedCenter,
                        size: size,
                        utilityCount: utilityCount,
                        bendDirection: direction
                    )
                case .scrub:
                    previewTimeline(at: value.location, geometry: geometry)
                case nil:
                    break
                }
            }
            .onEnded { value in
                guard !rejectsCurrentDrag, transaction?.sourceRevision == model.player.interactionSourceRevision else {
                    cancelGesture(restorePosition: false)
                    rejectsCurrentDrag = false
                    return
                }
                defer {
                    transaction = nil
                    gestureStartPlacement = nil
                    model.setChromePin(.scrubbing, active: false)
                    gestureMode = nil
                    dragStartCenter = nil
                    dragLastLocation = nil
                    dragGrabFraction = nil
                    dragGrabLocalOffset = .zero
                    dragTimelineFraction = nil
                }
                switch gestureMode {
                case .pendingTimeline:
                    commitTimeline(at: value.location, geometry: geometry)
                case .move:
                    let origin = dragStartCenter ?? geometry.center
                    let direction = bendDirection
                    bendDirection = direction
                    let previousLocation = dragLastLocation ?? value.startLocation
                    let residualTranslation = CGSize(
                        width: value.location.x - previousLocation.x,
                        height: value.location.y - previousLocation.y
                    )
                    let currentCenter = draggedCenter ?? origin
                    let finalCenter: CGPoint
                    if let advancingCenter = geometry.centerAdvancingBendAtTerminalBoundary(
                        translation: residualTranslation
                    ) {
                        finalCenter = advancingCenter
                    } else {
                        let incrementalCenter = ElasticPlaybackControlBarGeometry.movedCenter(
                            from: currentCenter,
                            translation: residualTranslation
                        )
                        finalCenter = ElasticPlaybackControlBarGeometry.centerTracking(
                            desiredPoint: value.location,
                            surfaceFraction: dragGrabFraction ?? 0.5,
                            localOffset: dragGrabLocalOffset,
                            initialCenter: incrementalCenter,
                            containerSize: size,
                            utilityCount: utilityCount,
                            bendDirection: direction,
                            orientation: orientation,
                            maximumCorrection: geometry.trackingCorrectionLimit(
                                for: residualTranslation
                            )
                        )
                    }
                    let placedCenter = applyTrackedCenter(
                        finalCenter,
                        size: size,
                        utilityCount: utilityCount,
                        bendDirection: direction
                    )
                    normalizedCenter = ElasticPlaybackControlBarGeometry.normalizedCenter(
                        placedCenter,
                        in: size
                    )
                    persistPlacement()
                    draggedCenter = nil
                    model.setChromePin(.chromeDrag, active: false)
                case .scrub:
                    commitTimeline(at: value.location, geometry: geometry)
                    model.setChromePin(.scrubbing, active: false)
                case nil:
                    break
                }
                model.registerUserActivity()
            }
    }

    private func cancelGesture(restorePosition: Bool = true) {
        if restorePosition, let target = transaction?.finish(currentRevision: model.player.interactionSourceRevision, cancelled: true) {
            model.player.seek(to: target)
        }
        if let gestureStartPlacement { placement = gestureStartPlacement }
        rejectsCurrentDrag = isDragRecognized
        transaction = nil
        gestureStartPlacement = nil
        gestureMode = nil
        dragStartCenter = nil
        dragLastLocation = nil
        dragGrabFraction = nil
        dragTimelineFraction = nil
        draggedCenter = nil
        model.setChromePin(.chromeDrag, active: false)
        model.setChromePin(.scrubbing, active: false)
    }

    private func beginMovingBar(
        geometry: ElasticPlaybackControlBarGeometry,
        startLocation: CGPoint,
        size: CGSize
    ) {
        gestureMode = .move
        dragStartCenter = geometry.center
        dragLastLocation = startLocation
        if geometry.bendProgress < 0.08 {
            bendDirection = ElasticPlaybackControlBarGeometry.preferredBendDirection(
                at: geometry.center,
                in: size,
                orientation: orientation
            )
        }
        let grabFraction = geometry.surfaceFraction(
            at: startLocation,
            maximumDistance: ElasticPlaybackControlBarGeometry.thickness / 2 + 8
        ) ?? 0.5
        dragGrabFraction = grabFraction
        dragGrabLocalOffset = geometry.localOffset(
            from: startLocation,
            atSurfaceFraction: grabFraction
        )
        model.setChromePin(.chromeDrag, active: true)
    }

    private func stableBendDirection(
        at center: CGPoint,
        size: CGSize,
        utilityCount: Int
    ) -> ElasticPlaybackControlBarBendDirection {
        let candidate = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: center,
            utilityCount: utilityCount,
            bendDirection: bendDirection,
            orientation: orientation
        )
        guard candidate.bendProgress < 0.08 else { return bendDirection }
        return ElasticPlaybackControlBarGeometry.preferredBendDirection(
            at: center,
            in: size,
            orientation: orientation
        )
    }

    @discardableResult
    private func applyTrackedCenter(
        _ center: CGPoint,
        size: CGSize,
        utilityCount: Int,
        bendDirection: ElasticPlaybackControlBarBendDirection
    ) -> CGPoint {
        let geometry = ElasticPlaybackControlBarGeometry(
            containerSize: size,
            center: center,
            utilityCount: utilityCount,
            bendDirection: bendDirection,
            orientation: orientation
        )
        guard geometry.bendProgress >= 0.995 else {
            normalizedCenter = ElasticPlaybackControlBarGeometry.normalizedCenter(
                center,
                in: size
            )
            draggedCenter = center
            return center
        }

        // A completely turned bar is geometrically identical to a straight
        // bar in the next cardinal orientation. Rebase at its displayed
        // midpoint so dragging can continue around the following corner.
        let rebasedCenter = geometry.point(at: 0)
        orientation = geometry.terminalOrientation
        self.bendDirection = ElasticPlaybackControlBarGeometry.preferredBendDirection(
            at: rebasedCenter,
            in: size,
            orientation: orientation
        )
        normalizedCenter = ElasticPlaybackControlBarGeometry.normalizedCenter(
            rebasedCenter,
            in: size
        )
        draggedCenter = rebasedCenter
        return rebasedCenter
    }

    private func previewTimeline(
        at location: CGPoint,
        geometry: ElasticPlaybackControlBarGeometry
    ) {
        guard let fraction = geometry.timelineFraction(
            at: location,
            maximumDistance: 48
        ) else { return }
        guard let target = transaction?.preview(fraction: fraction, currentRevision: model.player.interactionSourceRevision) else { return }
        model.player.previewSeek(to: target)
    }

    private func commitTimeline(
        at location: CGPoint,
        geometry: ElasticPlaybackControlBarGeometry
    ) {
        if let fraction = geometry.timelineFraction(at: location, maximumDistance: 48) {
            _ = transaction?.preview(fraction: fraction, currentRevision: model.player.interactionSourceRevision)
        }
        if let target = transaction?.finish(currentRevision: model.player.interactionSourceRevision, cancelled: false) {
            model.player.seek(to: target)
        }
    }
}
