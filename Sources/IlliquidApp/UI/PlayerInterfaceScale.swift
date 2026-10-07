import Observation
import SwiftUI

@MainActor
@Observable
final class PlayerInterfaceScaleStore {
    static let shared = PlayerInterfaceScaleStore()
    static let storageKey = "Illiquid.interface-scale.v1"
    static let percentages = Array(stride(from: 80, through: 150, by: 10))

    private let defaults: UserDefaults
    private(set) var percentage: Int
    var factor: CGFloat { CGFloat(percentage) / 100 }
    var canIncrease: Bool { percentage < 150 }
    var canDecrease: Bool { percentage > 80 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.object(forKey: Self.storageKey) as? Int
        percentage = saved.flatMap { Self.percentages.contains($0) ? $0 : nil } ?? 100
    }

    func select(_ percentage: Int) {
        guard Self.percentages.contains(percentage), self.percentage != percentage else { return }
        self.percentage = percentage
        defaults.set(percentage, forKey: Self.storageKey)
    }

    func increase() { select(min(150, percentage + 10)) }
    func decrease() { select(max(80, percentage - 10)) }
    func reset() { select(100) }
}

/// Propose logical dimensions to the content and reserve its scaled footprint.
/// Unlike a bare scaleEffect, this keeps surrounding layout and hit targets aligned.
struct PlayerInterfaceScaleLayout: Layout {
    let factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(logicalProposal(proposal))
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: logicalProposal(ProposedViewSize(bounds.size))
        )
    }

    private func logicalProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / factor }, height: proposal.height.map { $0 / factor })
    }
}

private struct ScaledPlayerInterface<Content: View>: View {
    @Bindable private var scale = PlayerInterfaceScaleStore.shared
    let content: Content

    var body: some View {
        PlayerInterfaceScaleLayout(factor: scale.factor) {
            content
                .environment(\.playerInterfaceScale, scale.factor)
                .scaleEffect(scale.factor, anchor: .topLeading)
        }
    }
}

private struct PlayerInterfaceScaleEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var playerInterfaceScale: CGFloat {
        get { self[PlayerInterfaceScaleEnvironmentKey.self] }
        set { self[PlayerInterfaceScaleEnvironmentKey.self] = newValue }
    }
}

extension View {
    func scaledPlayerInterface() -> some View {
        ScaledPlayerInterface(content: self)
    }
}
