import Foundation

/// An open video retains its own transport position and playlist context while
/// sharing the application's single native playback engine.
public struct OpenVideoTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: MediaSource
    public var position: TimeInterval = 0
    public var wasPaused = false
    public var playlist: [FolderPlaylistItem]
    public var folder: URL?

    public init(source: MediaSource, playlist: [FolderPlaylistItem] = [], folder: URL? = nil) {
        id = UUID()
        self.source = source
        self.playlist = playlist.isEmpty ? [FolderPlaylistItem(url: source.url)] : playlist
        self.folder = folder
    }

    public var title: String {
        let name = source.url.lastPathComponent
        return name.isEmpty ? (source.url.host ?? "Video") : name
    }
}

public struct OpenVideoTabs: Equatable, Sendable {
    public private(set) var items: [OpenVideoTab] = []
    public private(set) var selectedID: UUID?
    public var selected: OpenVideoTab? { items.first { $0.id == selectedID } }
    public init() {}

    @discardableResult
    public mutating func add(_ source: MediaSource) -> UUID {
        if let existing = items.first(where: { $0.source.representsSameResource(as: source) }) {
            return existing.id
        }
        let tab = OpenVideoTab(source: source)
        items.append(tab)
        return tab.id
    }

    public mutating func record(source: MediaSource, position: TimeInterval, wasPaused: Bool,
                                playlist: [FolderPlaylistItem], folder: URL?) {
        let id = add(source)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].position = position.isFinite ? max(0, position) : 0
        items[index].wasPaused = wasPaused
        items[index].playlist = playlist.isEmpty ? [FolderPlaylistItem(url: source.url)] : playlist
        items[index].folder = folder
    }

    @discardableResult
    public mutating func select(_ id: UUID) -> OpenVideoTab? {
        guard let tab = items.first(where: { $0.id == id }) else { return nil }
        selectedID = id
        return tab
    }

    /// Closing a background tab leaves playback alone. Closing the active tab
    /// selects the next neighbor, or the previous one at the right edge.
    @discardableResult
    public mutating func close(_ id: UUID) -> OpenVideoTab? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return selected }
        let wasSelected = selectedID == id
        items.remove(at: index)
        if wasSelected {
            selectedID = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        }
        return selected
    }

    public func adjacentID(_ direction: Int) -> UUID? {
        guard items.count > 1, let index = items.firstIndex(where: { $0.id == selectedID }) else { return nil }
        return items[(index + (direction < 0 ? items.count - 1 : 1)) % items.count].id
    }
}
