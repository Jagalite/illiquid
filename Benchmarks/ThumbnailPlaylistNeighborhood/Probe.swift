import Foundation
import IlliquidCore

/// Identical benchmark-only ABI for both source variants. The driver is built
/// separately, without cross-module optimization or an inlinable function body.
@inline(never)
public func makeNeighborhood(
    _ playlist: [FolderPlaylistItem],
    current: URL?
) -> (urls: [URL], distances: [URL: Int]) {
    let result = ThumbnailPlaylistNeighborhood(playlist: playlist, current: current)
    return (result.urls, result.distances)
}
