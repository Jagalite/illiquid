import SwiftUI

enum PlayerOverlaySurfaceRole: Equatable {
    case sidebar
    case status
}

enum PlayerGlassGroupID: Hashable {
    case transport
    case timelineControls
}

enum PlayerControlHoverPolicy {
    static let compactHighlightOpacity = 0.16
    static let circularHighlightOpacity = 0.12
    static let circularScale: CGFloat = 1.035
    static let bottomIslandHighlightInsets = EdgeInsets(
        top: 5,
        leading: 2,
        bottom: 5,
        trailing: 2
    )

    static func scale(
        isHovering: Bool,
        reduceMotion: Bool,
        preferredScale: CGFloat
    ) -> CGFloat {
        isHovering && !reduceMotion ? preferredScale : 1
    }
}

/// Native Liquid Glass for the sidebar and compact status surfaces. The system
/// owns the material, depth, contrast adaptation, and accessibility fallback.
/// The sidebar panel itself stays passive; its buttons own interaction motion.
struct PlayerOverlaySurface: ViewModifier {
    let cornerRadius: CGFloat
    let role: PlayerOverlaySurfaceRole
    @Environment(\.playerTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: theme.resolvedCornerRadius(cornerRadius),
            style: .continuous
        )

        surface(content, shape: shape)
    }

    @ViewBuilder
    private func surface(
        _ content: Content,
        shape: RoundedRectangle
    ) -> some View {
        switch theme.surfaceStyle {
        case .liquidGlass:
            switch role {
            case .sidebar:
                content.glassEffect(.clear, in: shape)
            case .status:
                content.glassEffect(.regular, in: shape)
            }
        case .classicMaterial:
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.75)
                }
                .shadow(
                    color: .black.opacity(0.18),
                    radius: theme.surfaceShadowRadius,
                    y: 3
                )
        case .solid:
            content
                .background(theme.surfaceColor(for: role), in: shape)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.75)
                }
                .shadow(
                    color: .black.opacity(0.28),
                    radius: theme.surfaceShadowRadius,
                    y: 4
                )
        }
    }
}

/// A compact clear-glass island inside a shared `GlassEffectContainer`.
/// Stable IDs let SwiftUI preserve the optical identity of each island if its
/// layout changes, while the container handles neighboring merge/separation.
struct PlayerGlassGroupModifier: ViewModifier {
    let id: PlayerGlassGroupID
    let namespace: Namespace.ID
    let cornerRadius: CGFloat
    let isInteractive: Bool
    @Environment(\.playerTheme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: theme.resolvedCornerRadius(cornerRadius),
            style: .continuous
        )

        surface(content, shape: shape)
    }

    @ViewBuilder
    private func surface(
        _ content: Content,
        shape: RoundedRectangle
    ) -> some View {
        switch theme.surfaceStyle {
        case .liquidGlass:
            glass(content, shape: shape)
                .glassEffectID(id, in: namespace)
                .glassEffectTransition(.matchedGeometry)
        case .classicMaterial:
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.75)
                }
                .shadow(
                    color: .black.opacity(0.18),
                    radius: theme.surfaceShadowRadius,
                    y: 3
                )
        case .solid:
            content
                .background(theme.surfaceColor(for: .sidebar), in: shape)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.75)
                }
                .shadow(
                    color: .black.opacity(0.28),
                    radius: theme.surfaceShadowRadius,
                    y: 4
                )
        }
    }

    @ViewBuilder
    private func glass(
        _ content: Content,
        shape: RoundedRectangle
    ) -> some View {
        if isInteractive {
            content.glassEffect(.clear.interactive(), in: shape)
        } else {
            content.glassEffect(.clear, in: shape)
        }
    }
}

/// Clear native Liquid Glass for the circular center transport controls.
struct PlayerCircularGlassControlModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.playerTheme) private var theme

    func body(content: Content) -> some View {
        let shape = Circle()

        surface(content, shape: shape)
    }

    @ViewBuilder
    private func surface(_ content: Content, shape: Circle) -> some View {
        switch theme.surfaceStyle {
        case .liquidGlass:
            content
                .glassEffect(.clear.interactive(), in: shape)
                .overlay {
                    PlayerGlassSpecularHighlight(
                        shape: shape,
                        color: theme.primaryColor,
                        opacity: reduceTransparency ? 0 : 0.2
                    )
                }
                .shadow(
                    color: .black.opacity(reduceTransparency ? 0.1 : 0.2),
                    radius: theme.surfaceShadowRadius,
                    y: 4
                )
        case .classicMaterial:
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.8)
                }
                .shadow(
                    color: .black.opacity(0.18),
                    radius: theme.surfaceShadowRadius,
                    y: 3
                )
        case .solid:
            content
                .background(theme.surfaceColor(for: .sidebar), in: shape)
                .overlay {
                    shape.stroke(theme.separatorColor, lineWidth: 0.8)
                }
                .shadow(
                    color: .black.opacity(0.28),
                    radius: theme.surfaceShadowRadius,
                    y: 4
                )
        }
    }
}

struct PlayerThemedControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.playerTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .overlay {
                Circle()
                    .stroke(
                        theme.primaryColor.opacity(reduceTransparency ? 0 : 0.32),
                        lineWidth: 0.8
                    )
                    .padding(3)
                    .scaleEffect(configuration.isPressed ? 0.72 : 1.14)
                    .opacity(configuration.isPressed ? 0.9 : 0)
                    .allowsHitTesting(false)
            }
            .animation(
                PlatinumMotion.tactilePress(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

private struct PlayerIconHoverEffectModifier<S: Shape>: ViewModifier {
    let shape: S
    let highlightOpacity: Double
    let highlightInsets: EdgeInsets
    let preferredScale: CGFloat
    let isEnabled: Bool

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.playerTheme) private var theme

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .background {
                shape
                    .fill(theme.primaryColor.opacity(activeHighlightOpacity))
                    .padding(highlightInsets)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                shape
                    .stroke(
                        theme.primaryColor.opacity(activeEdgeOpacity),
                        lineWidth: 0.75
                    )
                    .padding(highlightInsets)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .brightness(isHovering && isEnabled ? 0.14 : 0)
            .scaleEffect(
                PlayerControlHoverPolicy.scale(
                    isHovering: isHovering && isEnabled,
                    reduceMotion: reduceMotion,
                    preferredScale: preferredScale
                )
            )
            .animation(
                PlatinumMotion.crispHover(reduceMotion: reduceMotion),
                value: isHovering
            )
            .onHover { hovering in
                isHovering = hovering && isEnabled
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled {
                    isHovering = false
                }
            }
    }

    private var activeHighlightOpacity: Double {
        guard isHovering && isEnabled else { return 0 }
        return reduceTransparency ? highlightOpacity * 0.7 : highlightOpacity
    }

    private var activeEdgeOpacity: Double {
        guard isHovering && isEnabled else { return 0 }
        return reduceTransparency ? 0.14 : 0.24
    }
}

private struct PlayerGlassSpecularHighlight<S: InsettableShape>: View {
    let shape: S
    let color: Color
    let opacity: Double

    var body: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(opacity), location: 0),
                        .init(
                            color: color.opacity(opacity * 0.38),
                            location: 0.36
                        ),
                        .init(color: .clear, location: 0.72),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.7
            )
            .blendMode(.screen)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    func playerOverlaySurface(
        cornerRadius: CGFloat,
        role: PlayerOverlaySurfaceRole
    ) -> some View {
        modifier(PlayerOverlaySurface(cornerRadius: cornerRadius, role: role))
    }

    func playerGlassGroup(
        id: PlayerGlassGroupID,
        namespace: Namespace.ID,
        cornerRadius: CGFloat,
        isInteractive: Bool = true
    ) -> some View {
        modifier(
            PlayerGlassGroupModifier(
                id: id,
                namespace: namespace,
                cornerRadius: cornerRadius,
                isInteractive: isInteractive
            )
        )
    }

    func playerCircularGlassControl() -> some View {
        modifier(PlayerCircularGlassControlModifier())
    }

    func playerIconHoverEffect<S: Shape>(
        in shape: S,
        highlightOpacity: Double = PlayerControlHoverPolicy.compactHighlightOpacity,
        highlightInsets: EdgeInsets = EdgeInsets(),
        scale: CGFloat = 1,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            PlayerIconHoverEffectModifier(
                shape: shape,
                highlightOpacity: highlightOpacity,
                highlightInsets: highlightInsets,
                preferredScale: scale,
                isEnabled: isEnabled
            )
        )
    }
}
