import Foundation

/// A forward drag model: pointer travel has a fixed origin and never feeds the
/// previous rendered geometry back into the next pointer event.
struct ElasticPlaybackBarDrag {
    static let releaseDistance: CGFloat = 24
    private let gripOrigin: CGPoint
    private(set) var renderOffset: CGSize
    private let origin: CGPoint
    private let orientation: ElasticPlaybackControlBarOrientation
    let bendDirection: ElasticPlaybackControlBarBendDirection = .up
    private var attachedSide: ElasticPlaybackControlBarSide?
    private var peakOutwardTravel: CGFloat = 0
    private var lastTranslation = CGSize.zero
    private var canAttach: Bool
    private(set) var attachmentStrength: CGFloat

    init(geometry: ElasticPlaybackControlBarGeometry, attachmentStrength: CGFloat? = nil) {
        // In a straight pose, use the visible center. Saved grip/containment
        // offsets must not consume edge clearance before the pointer moves.
        let dragOrigin = geometry.bendProgress == 0 ? geometry.point(at: 0) : geometry.center
        origin = dragOrigin
        gripOrigin = geometry.point(at: geometry.dragHandleS)
        renderOffset = CGSize(
            width: geometry.containmentOffset.width + geometry.center.x - dragOrigin.x,
            height: geometry.containmentOffset.height + geometry.center.y - dragOrigin.y)
        orientation = geometry.orientation
        self.attachmentStrength = attachmentStrength
            ?? ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(for: geometry.bendProgress)
        attachedSide = self.attachmentStrength > 0 ? geometry.side : nil
        canAttach = self.attachmentStrength > 0 || geometry.bendProgress < 0.10
    }

    mutating func update(translation: CGSize, size: CGSize, utilityCount: Int) -> CGPoint {
        let center = CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
        guard translation != lastTranslation else { return center }
        lastTranslation = translation
        let geometry = ElasticPlaybackControlBarGeometry(containerSize: size, center: center,
            utilityCount: utilityCount, bendDirection: bendDirection, orientation: orientation,
            attachmentStrength: 0)
        let axisTravel: CGFloat = switch orientation {
        case .right: translation.width
        case .down: translation.height
        case .left: -translation.width
        case .up: -translation.height
        }
        if let side = attachedSide {
            let outward = axisTravel * (side == .trailing ? 1 : -1)
            let previousPeak = peakOutwardTravel
            peakOutwardTravel = max(peakOutwardTravel, outward)
            let pull = max(0, peakOutwardTravel - outward)
            let remaining = max(0, 1 - pull / Self.releaseDistance)
            let releaseStrength = remaining * remaining * (3 - 2 * remaining)
            let shapeStrength = ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(for: geometry.bendProgress)
            // Attraction may fade as the shape straightens, but cannot increase
            // while pulling away. A new outward push can strengthen the dock.
            if pull == 0 {
                let gain = (peakOutwardTravel - previousPeak) / Self.releaseDistance
                attachmentStrength = min(shapeStrength, attachmentStrength + gain)
            } else {
                attachmentStrength = min(attachmentStrength, releaseStrength, shapeStrength)
            }
            if pull >= Self.releaseDistance || geometry.side != side || geometry.bendProgress == 0 {
                attachedSide = nil
                attachmentStrength = 0
                canAttach = false
            }
        } else {
            // Leave the capture field before rearming. Small pointer reversals
            // immediately after release cannot magnetize the bar again.
            if geometry.bendProgress < 0.10 { canAttach = true }
            if canAttach {
                attachmentStrength = ElasticPlaybackControlBarGeometry.edgeAttachmentStrength(for: geometry.bendProgress)
                if attachmentStrength > 0 {
                    attachedSide = geometry.side
                    peakOutwardTravel = axisTravel * (geometry.side == .trailing ? 1 : -1)
                }
            }
        }
        let rendered = ElasticPlaybackControlBarGeometry(containerSize: size, center: center,
            utilityCount: utilityCount, bendDirection: bendDirection, orientation: orientation,
            attachmentStrength: attachmentStrength)
        let actualGrip = rendered.point(at: rendered.dragHandleS)
        let desiredGrip = CGPoint(x: gripOrigin.x + translation.width, y: gripOrigin.y + translation.height)
        var desiredOffset = CGSize(
            width: rendered.containmentOffset.width + desiredGrip.x - actualGrip.x,
            height: rendered.containmentOffset.height + desiredGrip.y - actualGrip.y)
        // Along the edge the grip follows directly. Across the edge the
        // attachment supplies bounded resistance, fading to exact tracking.
        if orientation.isHorizontal {
            desiredOffset.width += (rendered.containmentOffset.width - desiredOffset.width) * attachmentStrength
        } else {
            desiredOffset.height += (rendered.containmentOffset.height - desiredOffset.height) * attachmentStrength
        }
        let rawPoints = rendered.surfacePoints.map {
            CGPoint(x: $0.x - rendered.containmentOffset.width, y: $0.y - rendered.containmentOffset.height)
        }
        renderOffset = ElasticPlaybackControlBarGeometry.constrainedRenderOffset(desiredOffset, points: rawPoints, in: size)
        return center
    }
}
