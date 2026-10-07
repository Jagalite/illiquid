import AppKit
import SwiftUI
import IlliquidCore

/// Opt-in view drawing witness. This is not WindowServer scan-out or photon
/// evidence, and it is never instantiated by the production bundle.
struct PreviewDrawingProbe: NSViewRepresentable {
    let requestID: Int
    let started: UInt64
    let representedPosition: Double

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        let token = "\(requestID)-\(representedPosition)"
        guard view.token != token else { return }
        view.token = token
        view.started = started
        view.requestID = requestID
        view.recorded = false
        view.needsDisplay = true
    }

    final class ProbeView: NSView {
        var token = ""
        var started: UInt64 = 0
        var requestID = 0
        var recorded = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard !recorded, started != 0, window?.isVisible == true else { return }
            recorded = true
            LifecyclePerformance.end("preview-view-draw-\(requestID)", since: started)
        }
    }
}
