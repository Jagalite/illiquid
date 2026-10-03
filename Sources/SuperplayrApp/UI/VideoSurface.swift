import SwiftUI
import SuperplayrPlayer

struct VideoSurface: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let host: any PlaybackSurfaceHost
        do {
            host = try model.player.makeVideoSurfaceHost()
        } catch {
            let message = "The system could not create a video surface: "
                + error.localizedDescription
            model.player.reportError(message)
            return VideoSurfaceUnavailableView(message: message)
        }
        host.onOpenURLs = { [weak model] urls, mode in
            model?.handleOpenURLs(urls, mode: mode)
        }
        host.onUserActivity = { [weak model] in
            model?.registerUserActivity()
        }
        host.onInteraction = { [weak model] interaction in
            model?.handleSurfaceInteraction(interaction)
        }
        host.contextMenuProvider = { [weak model] in
            model?.makeVideoContextMenu()
        }
        return host.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        model.player.updateVideoSurfaceCallbacks(
            onOpenURLs: { [weak model] urls, mode in
                model?.handleOpenURLs(urls, mode: mode)
            },
            onUserActivity: { [weak model] in model?.registerUserActivity() },
            onInteraction: { [weak model] interaction in
                model?.handleSurfaceInteraction(interaction)
            },
            contextMenuProvider: { [weak model] in
                model?.makeVideoContextMenu()
            }
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
}

final class VideoSurfaceUnavailableView: NSView {
    let failureMessage: String

    init(message: String) {
        failureMessage = message
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video unavailable")
        setAccessibilityHelp(message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
