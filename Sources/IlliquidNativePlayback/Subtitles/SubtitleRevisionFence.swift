import Foundation

struct SubtitleFenceRevision: RawRepresentable, Equatable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SubtitleFenceSnapshot: Equatable, Sendable {
    let subtitleRevision: SubtitleFenceRevision
    let overlayRevision: SubtitleFenceRevision
    let pendingVisibleClear: SubtitleFenceRevision?
    let pendingSourceInvalidation: SubtitleFenceRevision?
    let lastAcceptedOverlay: SubtitleFenceRevision?
    let rejectedOverlayCommits: UInt64
}

/// Minimal subtitle reducer slice used by the native executor during the
/// migration. It is the single allocator for subtitle/overlay revisions and
/// performs the final check immediately before a main-actor overlay mutation.
final class SubtitleRevisionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = SubtitleFenceRevision(rawValue: 0)
    private var pendingVisibleClear: SubtitleFenceRevision?
    private var pendingSourceInvalidation: SubtitleFenceRevision?
    private var lastAcceptedOverlay: SubtitleFenceRevision?
    private var rejectedOverlayCommits: UInt64 = 0
    private var terminated = false

    var current: SubtitleFenceRevision { lock.withLock { revision } }

    func beginInvalidation() -> SubtitleFenceRevision {
        lock.withLock {
            precondition(revision.rawValue < UInt64.max, "subtitle revision exhausted")
            revision = SubtitleFenceRevision(rawValue: revision.rawValue + 1)
            pendingVisibleClear = revision
            pendingSourceInvalidation = revision
            return revision
        }
    }

    @discardableResult
    func acknowledgeSourceInvalidation(_ candidate: SubtitleFenceRevision) -> Bool {
        lock.withLock {
            guard !terminated,
                  candidate == revision,
                  pendingSourceInvalidation == candidate
            else { return false }
            pendingSourceInvalidation = nil
            return true
        }
    }

    @discardableResult
    func commitVisibleClear(_ candidate: SubtitleFenceRevision) -> Bool {
        lock.withLock {
            guard !terminated,
                  candidate == revision,
                  pendingVisibleClear == candidate
            else { return false }
            pendingVisibleClear = nil
            lastAcceptedOverlay = candidate
            return true
        }
    }

    @discardableResult
    func commitOverlay(_ candidate: SubtitleFenceRevision) -> Bool {
        lock.withLock {
            guard !terminated,
                  candidate == revision,
                  pendingVisibleClear == nil,
                  pendingSourceInvalidation == nil
            else {
                rejectedOverlayCommits &+= 1
                return false
            }
            lastAcceptedOverlay = candidate
            return true
        }
    }

    func terminate() {
        lock.withLock { terminated = true }
    }

    func snapshot() -> SubtitleFenceSnapshot {
        lock.withLock {
            SubtitleFenceSnapshot(
                subtitleRevision: revision,
                overlayRevision: revision,
                pendingVisibleClear: pendingVisibleClear,
                pendingSourceInvalidation: pendingSourceInvalidation,
                lastAcceptedOverlay: lastAcceptedOverlay,
                rejectedOverlayCommits: rejectedOverlayCommits
            )
        }
    }
}
