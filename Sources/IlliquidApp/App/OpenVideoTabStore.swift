import Foundation
import Observation
import IlliquidCore

/// Only membership and selection belong to the visible tab strip. Resume data
/// changes on every playback tick and must not invalidate title-bar views.
@MainActor @Observable
final class OpenVideoTabStore {
    struct Item: Identifiable, Equatable {
        let id: UUID
        let source: MediaSource
        let title: String
    }

    private(set) var items: [Item] = []
    private(set) var selectedID: UUID?
    @ObservationIgnored private var storage = OpenVideoTabs()

    var selected: OpenVideoTab? { storage.selected }
    func tab(id: UUID) -> OpenVideoTab? { storage.items.first { $0.id == id } }
    func adjacentID(_ direction: Int) -> UUID? { storage.adjacentID(direction) }

    @discardableResult
    func add(_ source: MediaSource) -> UUID {
        let count = storage.items.count
        let id = storage.add(source)
        if storage.items.count != count { publishMembership() }
        return id
    }

    func record(source: MediaSource, position: TimeInterval, wasPaused: Bool,
                playlist: [FolderPlaylistItem], folder: URL?) {
        let count = storage.items.count
        storage.record(source: source, position: position, wasPaused: wasPaused,
                       playlist: playlist, folder: folder)
        if storage.items.count != count { publishMembership() }
    }

    @discardableResult
    func select(_ id: UUID) -> OpenVideoTab? {
        let tab = storage.select(id)
        if selectedID != storage.selectedID { selectedID = storage.selectedID }
        return tab
    }

    @discardableResult
    func close(_ id: UUID) -> OpenVideoTab? {
        let count = storage.items.count
        let next = storage.close(id)
        if storage.items.count != count { publishMembership() }
        if selectedID != storage.selectedID { selectedID = storage.selectedID }
        return next
    }

    private func publishMembership() {
        items = storage.items.map { Item(id: $0.id, source: $0.source, title: $0.title) }
    }
}
