import Foundation

/// Session-local navigation survives hiding the sidebar. Closing a tab removes
/// its state; paths are stable row identities, never array positions.
struct SourceNavigationState {
    struct Location: Equatable {
        var query = ""
        var rowID: String?
    }
    private var locations: [String: Location] = [:]

    func location(for tab: String?) -> Location {
        tab.flatMap { locations[$0] } ?? Location()
    }

    mutating func save(_ location: Location, for tab: String?, validTabs: Set<String>) {
        locations = locations.filter { validTabs.contains($0.key) }
        guard let tab, validTabs.contains(tab) else { return }
        locations[tab] = location
    }
}
