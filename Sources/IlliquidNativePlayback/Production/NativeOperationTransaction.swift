import Foundation
import IlliquidPlaybackCore

enum NativeOperationKind: String, CaseIterable, Sendable {
    case open
    case preroll
    case seek
    case trackReplacement
    case externalSubtitle
    case recovery
    case wake
    case presentationFlush
    case sessionCancellation
    case shutdown
}

enum NativeOperationRequestedState: Equatable, Sendable {
    case openSource(MediaSourceIdentity)
    case awaitPreroll
    case seek(target: MediaTimestamp, mode: IlliquidPlaybackCore.SeekMode)
    case audioTrack(Int64?)
    case subtitle(SubtitleSelectionIntent)
    case externalSubtitle(URL)
    case recovery(String)
    case mediaFormat(stream: SynchronizedStream, revision: MediaFormatRevisionID)
    case wake(position: MediaTimestamp, milliRate: Int32)
    case presentationFlush
    case cancelSession
    case shutdown
}

enum NativeOperationCancellationState: Equatable, Sendable {
    case active
    case requested(code: String)
}

/// Immutable identity carried from a deterministic-core effect to the exact
/// native callback allowed to acknowledge it. Correlation updates replace this
/// value in the ledger rather than mutating a shared "pending effect" slot.
struct NativeOperationTransaction: Equatable, Sendable {
    let effect: PlaybackEffect
    let effectID: PlaybackEffectID
    let operationID: PlaybackOperationID
    let kind: NativeOperationKind
    let sessionID: PlaybackSessionID?
    let sessionGeneration: PlaybackGenerationID?
    let nativeSessionID: PlaybackSessionID?
    let nativeGeneration: Int?
    let requestedState: NativeOperationRequestedState
    let deadline: ContinuousClock.Instant
    let cancellationState: NativeOperationCancellationState

    init(
        effect: PlaybackEffect,
        kind: NativeOperationKind,
        requestedState: NativeOperationRequestedState,
        deadline: ContinuousClock.Instant
    ) {
        let authority: (PlaybackSessionID?, PlaybackGenerationID?) = switch
            effect.context.authority
        {
        case .application:
            (nil, nil)
        case let .playback(sessionID, generation, _):
            (sessionID, generation)
        }
        self.init(
            effect: effect,
            kind: kind,
            sessionID: authority.0,
            sessionGeneration: authority.1,
            nativeSessionID: nil,
            nativeGeneration: nil,
            requestedState: requestedState,
            deadline: deadline,
            cancellationState: .active
        )
    }

    private init(
        effect: PlaybackEffect,
        kind: NativeOperationKind,
        sessionID: PlaybackSessionID?,
        sessionGeneration: PlaybackGenerationID?,
        nativeSessionID: PlaybackSessionID?,
        nativeGeneration: Int?,
        requestedState: NativeOperationRequestedState,
        deadline: ContinuousClock.Instant,
        cancellationState: NativeOperationCancellationState
    ) {
        self.effect = effect
        effectID = effect.context.effectID
        operationID = effect.context.operationID
        self.kind = kind
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.nativeSessionID = nativeSessionID
        self.nativeGeneration = nativeGeneration
        self.requestedState = requestedState
        self.deadline = deadline
        self.cancellationState = cancellationState
    }

    func correlating(
        nativeSessionID: PlaybackSessionID? = nil,
        nativeGeneration: Int? = nil
    ) -> Self {
        Self(
            effect: effect,
            kind: kind,
            sessionID: sessionID,
            sessionGeneration: sessionGeneration,
            nativeSessionID: nativeSessionID ?? self.nativeSessionID,
            nativeGeneration: nativeGeneration ?? self.nativeGeneration,
            requestedState: requestedState,
            deadline: deadline,
            cancellationState: cancellationState
        )
    }

    func requestingCancellation(code: String) -> Self {
        Self(
            effect: effect,
            kind: kind,
            sessionID: sessionID,
            sessionGeneration: sessionGeneration,
            nativeSessionID: nativeSessionID,
            nativeGeneration: nativeGeneration,
            requestedState: requestedState,
            deadline: deadline,
            cancellationState: .requested(code: code)
        )
    }
}

private struct NativeGenerationCorrelationKey: Hashable {
    let nativeSessionID: PlaybackSessionID
    let nativeGeneration: Int
}

struct NativeOperationLedger {
    private var transactions: [PlaybackEffectID: NativeOperationTransaction] = [:]
    private var activeByKind: [NativeOperationKind: PlaybackEffectID] = [:]
    private var byNativeGeneration:
        [NativeGenerationCorrelationKey: PlaybackEffectID] = [:]

    var activeCount: Int { activeByKind.count }
    var retainedCount: Int { transactions.count }

    func active(_ kind: NativeOperationKind) -> NativeOperationTransaction? {
        activeByKind[kind].flatMap { transactions[$0] }
    }

    func transaction(effectID: PlaybackEffectID) -> NativeOperationTransaction? {
        transactions[effectID]
    }

    mutating func begin(
        _ transaction: NativeOperationTransaction,
        supersessionCode: String
    ) -> NativeOperationTransaction? {
        let superseded = active(transaction.kind).flatMap {
            cancel(effectID: $0.effectID, code: supersessionCode)
        }
        transactions[transaction.effectID] = transaction
        activeByKind[transaction.kind] = transaction.effectID
        return superseded
    }

    @discardableResult
    mutating func correlate(
        effectID: PlaybackEffectID,
        nativeSessionID: PlaybackSessionID? = nil,
        nativeGeneration: Int? = nil
    ) -> NativeOperationTransaction? {
        guard let current = transactions[effectID] else { return nil }
        if let previousSessionID = current.nativeSessionID,
           let previousGeneration = current.nativeGeneration
        {
            byNativeGeneration.removeValue(forKey: NativeGenerationCorrelationKey(
                nativeSessionID: previousSessionID,
                nativeGeneration: previousGeneration
            ))
        }
        let updated = current.correlating(
            nativeSessionID: nativeSessionID,
            nativeGeneration: nativeGeneration
        )
        transactions[effectID] = updated
        if let correlatedSessionID = updated.nativeSessionID,
           let correlatedGeneration = updated.nativeGeneration
        {
            byNativeGeneration[NativeGenerationCorrelationKey(
                nativeSessionID: correlatedSessionID,
                nativeGeneration: correlatedGeneration
            )] = effectID
        }
        return updated
    }

    mutating func cancel(
        effectID: PlaybackEffectID,
        code: String
    ) -> NativeOperationTransaction? {
        guard let current = transactions[effectID],
              current.cancellationState == .active
        else { return nil }
        // A superseded native seek may never call back. Remove both indexes
        // now: absence rejects a late result just as a tombstone would, without
        // retaining an unbounded history. Session/generation pairs and effect
        // IDs are not reused; physical resource custody lives outside this ledger.
        remove(current)
        return current.requestingCancellation(code: code)
    }

    mutating func cancel(
        kind: NativeOperationKind,
        code: String
    ) -> NativeOperationTransaction? {
        guard let effectID = activeByKind[kind] else { return nil }
        return cancel(effectID: effectID, code: code)
    }

    mutating func take(
        effectID: PlaybackEffectID
    ) -> NativeOperationTransaction? {
        guard let current = transactions[effectID] else { return nil }
        remove(current)
        guard current.cancellationState == .active else { return nil }
        return current
    }

    mutating func take(
        kind: NativeOperationKind,
        nativeSessionID: PlaybackSessionID
    ) -> NativeOperationTransaction? {
        guard let effectID = activeByKind[kind],
              transactions[effectID]?.nativeSessionID == nativeSessionID
        else { return nil }
        return take(effectID: effectID)
    }

    mutating func take(
        kind: NativeOperationKind,
        nativeSessionID: PlaybackSessionID,
        nativeGeneration: Int
    ) -> NativeOperationTransaction? {
        guard let transaction = take(
            nativeSessionID: nativeSessionID,
            nativeGeneration: nativeGeneration
        ), transaction.kind == kind else {
            return nil
        }
        return transaction
    }

    mutating func take(
        nativeSessionID: PlaybackSessionID,
        nativeGeneration: Int
    ) -> NativeOperationTransaction? {
        let key = NativeGenerationCorrelationKey(
            nativeSessionID: nativeSessionID,
            nativeGeneration: nativeGeneration
        )
        guard let effectID = byNativeGeneration.removeValue(forKey: key),
              let current = transactions[effectID]
        else { return nil }
        remove(current)
        guard current.cancellationState == .active else { return nil }
        return current
    }

    mutating func cancelAll(code: String) -> [NativeOperationTransaction] {
        let effectIDs = Array(activeByKind.values)
        return effectIDs.compactMap { cancel(effectID: $0, code: code) }
    }

    mutating func removeAll() -> [NativeOperationTransaction] {
        let active = activeByKind.values.compactMap { transactions[$0] }
        transactions.removeAll()
        activeByKind.removeAll()
        byNativeGeneration.removeAll()
        return active
    }

    private mutating func remove(_ transaction: NativeOperationTransaction) {
        transactions.removeValue(forKey: transaction.effectID)
        if activeByKind[transaction.kind] == transaction.effectID {
            activeByKind.removeValue(forKey: transaction.kind)
        }
        if let nativeSessionID = transaction.nativeSessionID,
           let nativeGeneration = transaction.nativeGeneration
        {
            byNativeGeneration.removeValue(forKey: NativeGenerationCorrelationKey(
                nativeSessionID: nativeSessionID,
                nativeGeneration: nativeGeneration
            ))
        }
    }
}

enum NativeOperationDeadlinePolicy {
    static func timeout(for kind: NativeOperationKind) -> Duration {
        switch kind {
        case .presentationFlush:
            .seconds(3)
        case .seek, .recovery, .wake:
            .seconds(5)
        case .preroll:
            .seconds(8)
        case .trackReplacement, .externalSubtitle, .sessionCancellation:
            .seconds(10)
        case .open:
            .seconds(15)
        case .shutdown:
            .seconds(8)
        }
    }
}
