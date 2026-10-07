import Foundation

public enum DifferentialCommitKind: String, CaseIterable, Sendable {
  case open
  case seek
  case decoder
  case presentation
  case video
  case audio
  case subtitle
  case rateChange
  case endOfStream
  case videoEndOfStream
  case audioEndOfStream
  case hardwareFailure
  case inputRead
}

public struct DifferentialCommitToken: Hashable, Sendable {
  fileprivate let id: UUID
  public let kind: DifferentialCommitKind
  public let epoch: Int
}

public enum DifferentialCommitDisposition: Equatable, Sendable {
  case accepted
  case stale
  case cleanupOnly
  case droppedAfterTermination
  case duplicate
}

/// Test-only deterministic barrier state. A test arms a specific final-commit
/// boundary, captures the old authority there, performs seek/replacement/close,
/// and then releases the token against the new authority. This represents the
/// exact interleaving without relying on timing or repeated random seeks.
public final class DifferentialCommitBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var armed: Set<DifferentialCommitKind> = []
  private var pending: [UUID: DifferentialCommitToken] = [:]
  private var released: Set<UUID> = []

  public init() {}

  public func arm(_ kind: DifferentialCommitKind) {
    _ = lock.withLock { armed.insert(kind) }
  }

  public func arrive(kind: DifferentialCommitKind, epoch: Int) -> DifferentialCommitToken? {
    lock.withLock {
      guard armed.remove(kind) != nil else { return nil }
      let token = DifferentialCommitToken(id: UUID(), kind: kind, epoch: epoch)
      pending[token.id] = token
      return token
    }
  }

  public func release(
    _ token: DifferentialCommitToken,
    currentEpoch: Int,
    terminated: Bool,
    carriesResourceCustody: Bool
  ) -> DifferentialCommitDisposition {
    lock.withLock {
      guard !released.contains(token.id), pending.removeValue(forKey: token.id) != nil else {
        return .duplicate
      }
      released.insert(token.id)
      if terminated {
        return carriesResourceCustody ? .cleanupOnly : .droppedAfterTermination
      }
      return token.epoch == currentEpoch ? .accepted : .stale
    }
  }

  public var pendingCount: Int { lock.withLock { pending.count } }
}
