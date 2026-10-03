import SwiftUI

enum PlaybackControlBarImplementation: Equatable {
    case legacy
    case elastic
}

enum PlaybackControlBarFeatureGate {
    static let legacyLaunchArgument = "--legacy-playback-control-bar"

    static func implementation(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> PlaybackControlBarImplementation {
        arguments.contains(legacyLaunchArgument) ? .legacy : .elastic
    }
}

/// Makes the elastic replacement available for hands-on testing while keeping
/// the proven playback bar available through an explicit launch-only fallback.
struct PlaybackControlBarHost: View {
    @Bindable var model: AppModel
    let implementation: PlaybackControlBarImplementation
    let sidebarOccupiedWidth: CGFloat

    init(
        model: AppModel,
        implementation: PlaybackControlBarImplementation =
            PlaybackControlBarFeatureGate.implementation(),
        sidebarOccupiedWidth: CGFloat = 0
    ) {
        self.model = model
        self.implementation = implementation
        self.sidebarOccupiedWidth = sidebarOccupiedWidth
    }

    @ViewBuilder
    var body: some View {
        switch implementation {
        case .legacy:
            PlaybackControlBar(model: model)
        case .elastic:
            ElasticPlaybackControlBar(
                model: model,
                sidebarOccupiedWidth: sidebarOccupiedWidth
            )
        }
    }
}
