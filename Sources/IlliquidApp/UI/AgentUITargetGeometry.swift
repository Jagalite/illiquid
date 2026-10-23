import SwiftUI

enum AgentUITargetGeometry {
    /// Unscaled PlayerRootView's named space. SwiftUI resolves descendant scale,
    /// placement, and rotation into this space. These are not screen coordinates.
    static let coordinateSpace = "swiftui-player-root-top-left-points"
    static let coordinateSpaceDescription = "Axis-aligned bounds in points relative to PlayerRootView's top-left layout origin; x right, y down. Descendant UI scale, rotation and placement are resolved into this root space. Not global screen coordinates or backing pixels."
    static let timelineGrip = "illiquid.timeline.grip"

    /// Retain layout's source identity rather than assigning the current source
    /// to old bounds when a diagnostic request arrives before the next layout.
    struct Observation: Equatable {
        let bounds: CGRect
        let sourceRevision: UInt64

        init?(bounds: CGRect, sourceRevision: UInt64) {
            guard !bounds.isNull, !bounds.isEmpty,
                  bounds.minX.isFinite, bounds.minY.isFinite,
                  bounds.maxX.isFinite, bounds.maxY.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite else { return nil }
            self.bounds = bounds
            self.sourceRevision = sourceRevision
        }

        func isCurrent(for sourceRevision: UInt64) -> Bool {
            self.sourceRevision == sourceRevision
        }
    }
}

private struct AgentUITargetPublisher: ViewModifier {
    let model: AppModel
    let identifier: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.isAgentUIDiagnosticsEnabled {
            let sourceRevision = model.player.interactionSourceRevision
            content
                .onGeometryChange(for: AgentUITargetGeometry.Observation?.self) { proxy in
                    AgentUITargetGeometry.Observation(
                        bounds: proxy.frame(in: .named(AgentUITargetGeometry.coordinateSpace)),
                        sourceRevision: sourceRevision
                    )
                } action: { observation in
                    model.publishAgentUITarget(identifier, observation: observation)
                }
                .onDisappear { model.publishAgentUITarget(identifier, observation: nil) }
        } else {
            content
        }
    }
}

extension View {
    func agentUITarget(_ identifier: String, model: AppModel) -> some View {
        modifier(AgentUITargetPublisher(model: model, identifier: identifier))
    }
}
