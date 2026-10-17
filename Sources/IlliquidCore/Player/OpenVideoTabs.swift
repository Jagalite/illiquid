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
    /// Mirrors `MediaSource.representsSameResource` without normalizing every
    /// existing URL for every admission. Sources are immutable while open.
    private enum ResourceKey: Hashable, Sendable {
        case local(String)
        case remote(String)

        init?(_ source: MediaSource) {
            switch source {
            case let .localFile(url):
                // Direct enum construction can supply a non-file URL. Such a
                // source never matches another local source, including itself.
                guard let path = NormalizedFileURL.persistenceKey(for: url) else { return nil }
                self = .local(path)
            case let .remoteStream(url):
                self = .remote(url.absoluteURL.absoluteString)
            }
        }
    }

    public private(set) var items: [OpenVideoTab] = []
    public private(set) var selectedID: UUID?
    private var resourceIDs: [ResourceKey: UUID] = [:]
    public var selected: OpenVideoTab? { items.first { $0.id == selectedID } }
    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.selectedID == rhs.selectedID
    }

    @discardableResult
    public mutating func add(_ source: MediaSource) -> UUID {
        let key = ResourceKey(source)
        if let key, let id = resourceIDs[key] {
            return id
        }
        let tab = OpenVideoTab(source: source)
        items.append(tab)
        if let key { resourceIDs[key] = tab.id }
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
        if let key = ResourceKey(items[index].source) {
            resourceIDs.removeValue(forKey: key)
        }
        items.remove(at: index)
        if items.isEmpty { resourceIDs = [:] }
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
