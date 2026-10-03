import CoreMedia
import Foundation

enum SeekPhase: Equatable, Sendable {
    case idle
    case invalidating(
        generation: Int,
        target: CMTime,
        pending: Set<SeekInvalidationBarrier>
    )
    case seeking(generation: Int, target: CMTime)
    case prerolling(generation: Int, target: CMTime)
}

enum SeekInvalidationBarrier: String, Hashable, Sendable {
    case inputReadCancellation
    case packetAndFrameQueues
    case presentationFence
    case subtitleVisibleClear
    case subtitleSourceInvalidation
}

struct SeekRequest: Equatable, Sendable {
    let target: CMTime
    let exact: Bool
    let generation: Int
    let resumeRate: Float
    let isPreview: Bool

    init(
        target: CMTime,
        exact: Bool,
        generation: Int,
        resumeRate: Float,
        isPreview: Bool = false
    ) {
        self.target = target
        self.exact = exact
        self.generation = generation
        self.resumeRate = resumeRate
        self.isPreview = isPreview
    }
}

final class SeekTransactionReducer: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: SeekRequest?
    private var storedPhase: SeekPhase = .idle

    var phase: SeekPhase { condition.withLock { storedPhase } }
    var isActive: Bool {
        condition.withLock {
            if case .idle = storedPhase { false } else { true }
        }
    }

    func submit(_ request: SeekRequest) {
        condition.withLock {
            pending = request
            storedPhase = .invalidating(
                generation: request.generation,
                target: request.target,
                pending: Set([
                    .inputReadCancellation,
                    .packetAndFrameQueues,
                    .presentationFence,
                    .subtitleVisibleClear,
                    .subtitleSourceInvalidation,
                ])
            )
            condition.broadcast()
        }
    }

    func acknowledge(
        _ barrier: SeekInvalidationBarrier,
        generation: Int
    ) {
        condition.withLock {
            guard case let .invalidating(activeGeneration, target, pendingBarriers) = storedPhase,
                  activeGeneration == generation
            else { return }
            var remaining = pendingBarriers
            remaining.remove(barrier)
            storedPhase = .invalidating(
                generation: activeGeneration,
                target: target,
                pending: remaining
            )
            condition.broadcast()
        }
    }

    func takePending() -> SeekRequest? {
        condition.withLock {
            guard let request = pending else { return nil }
            guard case let .invalidating(activeGeneration, _, barriers) = storedPhase,
                  activeGeneration == request.generation,
                  barriers.isEmpty
            else { return nil }
            pending = nil
            storedPhase = .seeking(generation: request.generation, target: request.target)
            return request
        }
    }

    func markPrerolling(_ request: SeekRequest) {
        condition.withLock {
            guard case let .seeking(activeGeneration, _) = storedPhase,
                  activeGeneration == request.generation
            else { return }
            storedPhase = .prerolling(generation: request.generation, target: request.target)
        }
    }

    @discardableResult
    func finish(generation: Int) -> Bool {
        condition.withLock {
            guard case let .prerolling(activeGeneration, _) = storedPhase,
                  activeGeneration == generation
            else { return false }
            storedPhase = .idle
            return true
        }
    }
}

typealias SeekCoordinator = SeekTransactionReducer

private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
