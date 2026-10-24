import AppKit
import SwiftUI

enum AgentUITargetGeometry {
    /// Unscaled PlayerRootView's named space. SwiftUI resolves descendant scale,
    /// placement, and rotation into this space. These are not screen coordinates.
    static let coordinateSpace = "swiftui-player-root-top-left-points"
    static let coordinateSpaceDescription = "Axis-aligned bounds in points relative to PlayerRootView's top-left layout origin; x right, y down. Descendant UI scale, rotation and placement are resolved into this root space. Not global screen coordinates or backing pixels."
    static let screenCoordinateSpace = "quartz-global-logical-points"
    static let timelineGrip = "illiquid.timeline.grip"

    /// Retain layout's source identity rather than assigning the current source
    /// to old bounds when a diagnostic request arrives before the next layout.
    struct Observation: Equatable {
        let bounds: CGRect
        let sourceRevision: UInt64
        let interfaceScale: CGFloat
        let sidebarPresented: Bool
        let cancellationRevision: UInt64
        let positionRevision: UInt64

        init?(bounds: CGRect, sourceRevision: UInt64, interfaceScale: CGFloat = 1,
              sidebarPresented: Bool = false, cancellationRevision: UInt64 = 0, positionRevision: UInt64 = 0) {
            guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty,
                  bounds.minX.isFinite, bounds.minY.isFinite,
                  bounds.maxX.isFinite, bounds.maxY.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite,
                  // CoreGraphics edge accessors can saturate extreme finite
                  // rectangles. Check the underlying arithmetic before use.
                  (bounds.origin.x + bounds.size.width).isFinite,
                  (bounds.origin.y + bounds.size.height).isFinite else { return nil }
            self.bounds = bounds
            self.sourceRevision = sourceRevision
            self.interfaceScale = interfaceScale
            self.sidebarPresented = sidebarPresented
            self.cancellationRevision = cancellationRevision
            self.positionRevision = positionRevision
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
            // Geometry transforms may execute in a Sendable closure. Capture
            // the layout's model context on the main actor with its source pin.
            let interfaceScale = PlayerInterfaceScaleStore.shared.factor
            let sidebarPresented = model.isSidebarPresented
            let cancellationRevision = model.interactionCancellationRevision
            let positionRevision = model.controlsPositionRevision
            content
                .onGeometryChange(for: AgentUITargetGeometry.Observation?.self) { proxy in
                    AgentUITargetGeometry.Observation(
                        bounds: proxy.frame(in: .named(AgentUITargetGeometry.coordinateSpace)),
                        sourceRevision: sourceRevision,
                        interfaceScale: interfaceScale,
                        sidebarPresented: sidebarPresented,
                        cancellationRevision: cancellationRevision,
                        positionRevision: positionRevision
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

/// A noninteractive reference for the named SwiftUI root. Never infer its origin
/// from the window frame/titlebar: SwiftUI may extend underneath window chrome.
@MainActor
final class AgentUIRootGeometryView: NSView {
    var expectedRootSize: CGSize = .zero

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func screenGeometry(for bounds: CGRect, expectedWindow: NSWindow) -> [String: Any]? {
        guard window === expectedWindow, expectedWindow.windowNumber > 0,
              !isHiddenOrHasHiddenAncestor, self.bounds.contains(bounds),
              self.bounds.origin == .zero,
              abs(self.bounds.width - expectedRootSize.width) < 0.01,
              abs(self.bounds.height - expectedRootSize.height) < 0.01,
              let primary = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
              }) else { return nil }
        let display = CGDisplayBounds(CGMainDisplayID())
        // Both APIs must describe the same logical desktop. Refuse unsupported
        // display mappings rather than applying a backing-pixel scale heuristic.
        guard abs(display.width - primary.frame.width) < 0.01,
              abs(display.height - primary.frame.height) < 0.01 else { return nil }
        let appKit = expectedWindow.convertToScreen(convert(bounds, to: nil))
        let quartz = CGRect(x: display.minX + appKit.minX - primary.frame.minX,
                            y: display.minY + primary.frame.maxY - appKit.maxY,
                            width: appKit.width, height: appKit.height)
        guard let checked = AgentUITargetGeometry.Observation(bounds: quartz, sourceRevision: 0) else { return nil }
        func rect(_ r: CGRect) -> [String: Double] {
            ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
        }
        return ["bounds": rect(checked.bounds),
                "coordinate_space": AgentUITargetGeometry.screenCoordinateSpace,
                "window_id": expectedWindow.windowNumber,
                "window_frame_appkit": rect(expectedWindow.frame),
                "root_bounds": rect(self.bounds),
                "root_screen_appkit": rect(expectedWindow.convertToScreen(convert(self.bounds, to: nil))),
                "primary_screen_appkit": rect(primary.frame),
                "primary_display_quartz": rect(display),
                "backing_scale": expectedWindow.backingScaleFactor,
                "conversion": "named-root-flipped-nsview-to-window-to-screen-to-quartz"]
    }
}

private struct AgentUIRootGeometryReference: NSViewRepresentable {
    let model: AppModel
    let rootSize: CGSize

    func makeNSView(context: Context) -> AgentUIRootGeometryView {
        let view = AgentUIRootGeometryView()
        view.expectedRootSize = rootSize
        model.publishAgentUIRootGeometry(view)
        return view
    }

    func updateNSView(_ view: AgentUIRootGeometryView, context: Context) {
        view.expectedRootSize = rootSize
        model.publishAgentUIRootGeometry(view)
    }
}

extension View {
    @ViewBuilder
    func agentUIRootGeometry(model: AppModel) -> some View {
        if model.isAgentUIDiagnosticsEnabled {
            background {
                GeometryReader { proxy in
                    AgentUIRootGeometryReference(model: model, rootSize: proxy.size)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}
