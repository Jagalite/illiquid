import Foundation
import Testing
@testable import IlliquidApp

@Suite("Playback bar drag interaction")
struct ElasticPlaybackBarDragTests {
    private let size = CGSize(width: 1400, height: 1200)

    private func geometry(center: CGPoint = CGPoint(x: 700, y: 600),
                          orientation: ElasticPlaybackControlBarOrientation = .right) -> ElasticPlaybackControlBarGeometry {
        .init(containerSize: size, center: center, utilityCount: 3,
              bendDirection: .up, orientation: orientation)
    }

    @Test func freeDragIsIndependentOfEventSubdivisionAndReleaseIsIdempotent() {
        let initial = geometry()
        var coarse = ElasticPlaybackBarDrag(geometry: initial)
        var fine = coarse
        let end = CGSize(width: 40, height: -90)
        let expected = coarse.update(translation: end, size: size, utilityCount: 3)
        for step in 1...100 {
            let fraction = CGFloat(step) / 100
            let actual = fine.update(translation: CGSize(width: end.width * fraction, height: end.height * fraction),
                                     size: size, utilityCount: 3)
            if step == 100 { #expect(actual == expected) }
        }
        #expect(expected == CGPoint(x: 740, y: 510))
        let strength = fine.attachmentStrength
        #expect(fine.update(translation: end, size: size, utilityCount: 3) == expected)
        #expect(fine.attachmentStrength == strength)
    }

    @Test func pullingAwayReleasesInPhysicalPointsAcrossEveryOrientation() {
        for orientation in [ElasticPlaybackControlBarOrientation.right, .down, .left, .up] {
            let center: CGPoint = switch orientation {
            case .right: CGPoint(x: 1300, y: 600)
            case .down: CGPoint(x: 700, y: 1100)
            case .left: CGPoint(x: 100, y: 600)
            case .up: CGPoint(x: 700, y: 100)
            }
            let initial = geometry(center: center, orientation: orientation)
            #expect(initial.bendProgress > 0.2)
            var coarse = ElasticPlaybackBarDrag(geometry: initial)
            var fine = coarse
            let axis = CGPoint(x: cos(orientation.angle), y: sin(orientation.angle))
            for step in 1...24 {
                let distance = CGFloat(step)
                _ = fine.update(translation: CGSize(width: -axis.x * distance, height: -axis.y * distance),
                                size: size, utilityCount: 3)
            }
            let end = CGSize(width: -axis.x * 24, height: -axis.y * 24)
            _ = coarse.update(translation: end, size: size, utilityCount: 3)
            #expect(coarse.attachmentStrength == 0)
            #expect(fine.attachmentStrength == 0)
            // A small reversal stays detached, even though the bar remains bent.
            _ = fine.update(translation: CGSize(width: -axis.x * 23, height: -axis.y * 23),
                            size: size, utilityCount: 3)
            #expect(fine.attachmentStrength == 0)
        }
    }

    @Test func stationaryPressAndReleasePreservePartiallyReleasedPlacement() {
        let initial = geometry(center: CGPoint(x: 1300, y: 600))
        var drag = ElasticPlaybackBarDrag(geometry: initial, attachmentStrength: 0.35)
        #expect(drag.update(translation: .zero, size: size, utilityCount: 3) == initial.center)
        #expect(drag.attachmentStrength == 0.35)
    }

    @Test func slidingAlongEdgeDoesNotRestorePartiallyReleasedAttraction() {
        let initial = geometry(center: CGPoint(x: 1300, y: 600))
        var drag = ElasticPlaybackBarDrag(geometry: initial, attachmentStrength: 0.35)
        _ = drag.update(translation: CGSize(width: 0, height: 20), size: size, utilityCount: 3)
        #expect(drag.attachmentStrength <= 0.35)
    }

    @Test func detachedBarRearmsAfterLeavingTheCaptureField() {
        let initial = geometry(center: CGPoint(x: 1300, y: 600))
        var drag = ElasticPlaybackBarDrag(geometry: initial)
        _ = drag.update(translation: CGSize(width: -24, height: 0), size: size, utilityCount: 3)
        #expect(drag.attachmentStrength == 0)
        _ = drag.update(translation: CGSize(width: -600, height: 0), size: size, utilityCount: 3)
        _ = drag.update(translation: .zero, size: size, utilityCount: 3)
        #expect(drag.attachmentStrength > 0)
    }

    @Test func freeGripRemainsAnchoredAndReleasedGeometryRoundTrips() throws {
        let initial = geometry()
        var drag = ElasticPlaybackBarDrag(geometry: initial)
        let translation = CGSize(width: 40, height: -90)
        let center = drag.update(translation: translation, size: size, utilityCount: 3)
        var placement = ElasticPlaybackControlBarPlacement.defaultValue
        placement.normalizedCenter = ElasticPlaybackControlBarGeometry.normalizedCenter(center, in: size)
        placement.attachmentStrength = Double(drag.attachmentStrength)
        placement.normalizedRenderOffset = CGSize(width: drag.renderOffset.width / size.width,
                                                  height: drag.renderOffset.height / size.height)
        let stored = try JSONDecoder().decode(ElasticPlaybackControlBarPlacement.self,
                                              from: JSONEncoder().encode(placement))
        let rendered = ElasticPlaybackControlBarGeometry(containerSize: size,
            center: ElasticPlaybackControlBarGeometry.center(from: stored.normalizedCenter, in: size),
            utilityCount: 3, bendDirection: .up,
            attachmentStrength: stored.attachmentStrength.map { CGFloat($0) },
            renderOffset: stored.normalizedRenderOffset.map {
                CGSize(width: $0.width * size.width, height: $0.height * size.height)
            })
        let grip = rendered.point(at: rendered.dragHandleS)
        let originalGrip = initial.point(at: initial.dragHandleS)
        #expect(abs(grip.x - originalGrip.x - translation.width) < 0.000001)
        #expect(abs(grip.y - originalGrip.y - translation.height) < 0.000001)
    }

    @Test func draggingBeyondWindowKeepsTheWholeSurfaceContained() {
        let initial = geometry()
        var drag = ElasticPlaybackBarDrag(geometry: initial)
        for translation in [CGSize(width: 1200, height: -900), CGSize(width: -1200, height: 900)] {
            let center = drag.update(translation: translation, size: size, utilityCount: 3)
            let rendered = ElasticPlaybackControlBarGeometry(containerSize: size, center: center,
                utilityCount: 3, bendDirection: .up, attachmentStrength: drag.attachmentStrength,
                renderOffset: drag.renderOffset)
            #expect(rendered.surfaceBounds.minX >= 18 - 0.000001)
            #expect(rendered.surfaceBounds.maxX <= size.width - 18 + 0.000001)
            #expect(rendered.surfaceBounds.minY >= 18 - 0.000001)
            #expect(rendered.surfaceBounds.maxY <= size.height - 16 + 0.000001)
        }
    }

    @Test func everyBentPoseTouchesItsContactedSideEvenWithTrackingOffsets() {
        for orientation in [ElasticPlaybackControlBarOrientation.right, .down, .left, .up] {
            for side in [ElasticPlaybackControlBarSide.leading, .trailing] {
                for pressure: CGFloat in [1, 10, 40, 100, 250, 500] {
                    let straight = geometry(orientation: orientation)
                    let dimension = orientation.isHorizontal ? size.width : size.height
                    let leading: CGFloat = orientation == .up ? 16 : 18
                    let trailing: CGFloat = orientation == .down ? 16 : 18
                    let coordinate = side == .leading
                        ? leading + 28 + straight.totalLength / 2 - pressure
                        : dimension - trailing - 28 - straight.totalLength / 2 + pressure
                    let center: CGPoint = switch orientation {
                    case .right: CGPoint(x: coordinate, y: size.height / 2)
                    case .down: CGPoint(x: size.width / 2, y: coordinate)
                    case .left: CGPoint(x: size.width - coordinate, y: size.height / 2)
                    case .up: CGPoint(x: size.width / 2, y: size.height - coordinate)
                    }
                    let pose = ElasticPlaybackControlBarGeometry(containerSize: size, center: center,
                        utilityCount: 3, bendDirection: .up, orientation: orientation,
                        attachmentStrength: 0, renderOffset: CGSize(width: -120, height: 90))
                    #expect(pose.bendProgress > 0)
                    let bounds = pose.surfaceBounds
                    let contact: CGFloat = switch (orientation, side) {
                    case (.right, .leading), (.left, .trailing): bounds.minX - 18
                    case (.right, .trailing), (.left, .leading): bounds.maxX - (size.width - 18)
                    case (.down, .leading), (.up, .trailing): bounds.minY - 18
                    case (.down, .trailing), (.up, .leading): bounds.maxY - (size.height - 16)
                    }
                    #expect(abs(contact) < 0.000001)
                }
            }
        }
    }

    @Test func straightDragUsesVisibleClearanceInsteadOfHiddenPlacementCenter() {
        let initial = ElasticPlaybackControlBarGeometry(containerSize: size,
            center: CGPoint(x: 850, y: 600), utilityCount: 3, bendDirection: .up,
            renderOffset: CGSize(width: -100, height: 0))
        #expect(initial.bendProgress == 0)
        var drag = ElasticPlaybackBarDrag(geometry: initial)
        let pressedCenter = drag.update(translation: .zero, size: size, utilityCount: 3)
        let pressed = ElasticPlaybackControlBarGeometry(containerSize: size, center: pressedCenter,
            utilityCount: 3, bendDirection: .up, renderOffset: drag.renderOffset)
        #expect(pressed.point(at: pressed.dragHandleS) == initial.point(at: initial.dragHandleS))
        let center = drag.update(translation: CGSize(width: 100, height: 0), size: size, utilityCount: 3)
        let moved = geometry(center: center)
        #expect(moved.bendProgress == 0)
        #expect(moved.surfaceBounds.maxX < size.width - 18)
    }

    @Test func barBendsUpInBothHalvesOfTheWindow() {
        for height: CGFloat in [-300, 300] {
            var drag = ElasticPlaybackBarDrag(geometry: geometry())
            _ = drag.update(translation: CGSize(width: 0, height: height), size: size, utilityCount: 3)
            #expect(drag.bendDirection == .up)
            let center = drag.update(translation: CGSize(width: 600, height: height), size: size, utilityCount: 3)
            let bent = ElasticPlaybackControlBarGeometry(containerSize: size, center: center,
                utilityCount: 3, bendDirection: drag.bendDirection,
                attachmentStrength: drag.attachmentStrength, renderOffset: drag.renderOffset)
            #expect(bent.bendProgress > 0)
            #expect(bent.pointOnSurface(fraction: 1).y < bent.pointOnSurface(fraction: 0).y)
        }
    }

    @Test func oldDownwardPlacementRestoresUpwardWithoutLosingItsLocation() throws {
        let name = "UpwardBarPlacement.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var saved = ElasticPlaybackControlBarPlacement.defaultValue
        saved.bendDirection = .down
        saved.normalizedCenter = CGPoint(x: 0.7, y: 0.3)
        ElasticPlaybackControlBarPlacementStore.persist(saved, defaults: defaults)
        let restored = ElasticPlaybackControlBarPlacementStore.restored(defaults: defaults)
        #expect(restored.bendDirection == .up)
        #expect(restored.normalizedCenter == saved.normalizedCenter)
    }

    @Test func attachmentPersistenceAcceptsLegacyDataAndRejectsInvalidStrength() throws {
        let legacy = Data(#"{"orientationRawValue":0,"bendsUp":true}"#.utf8)
        let restored = try JSONDecoder().decode(ElasticPlaybackControlBarPlacement.self, from: legacy)
        #expect(restored.isValid)
        #expect(restored.attachmentStrength == nil)
        var placement = restored
        placement.attachmentStrength = 0.35
        #expect(try JSONDecoder().decode(ElasticPlaybackControlBarPlacement.self,
            from: JSONEncoder().encode(placement)) == placement)
        placement.attachmentStrength = 2
        #expect(!placement.isValid)
    }
}
