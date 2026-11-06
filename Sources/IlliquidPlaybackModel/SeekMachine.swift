public enum SeekBarrier: String, Codable, Hashable, Sendable {
  case inputReadCancellation
  case videoDecoderFlush
  case audioDecoderFlush
  case presentationFence
  case subtitleVisibleClear
  case subtitleSourceInvalidation

  static let allCasesForTransaction: [SeekBarrier] = [
    .inputReadCancellation, .videoDecoderFlush, .audioDecoderFlush,
    .presentationFence, .subtitleVisibleClear, .subtitleSourceInvalidation,
  ]
}

public enum SeekTransactionPhase: String, Codable, Equatable, Sendable {
  case invalidating
  case demuxSeeking
  case prerolling
}

public struct SeekTransactionState: Codable, Equatable, Sendable {
  public let operationID: PlaybackOperationID
  public let generation: PlaybackGenerationID
  public let target: MediaTimestamp
  public let mode: SeekMode
  public var phase: SeekTransactionPhase
  public var pendingBarriers: Set<SeekBarrier>

  public init(
    operationID: PlaybackOperationID,
    generation: PlaybackGenerationID,
    target: MediaTimestamp,
    mode: SeekMode,
    phase: SeekTransactionPhase = .invalidating,
    pendingBarriers: Set<SeekBarrier>
  ) {
    self.operationID = operationID
    self.generation = generation
    self.target = target
    self.mode = mode
    self.phase = phase
    self.pendingBarriers = pendingBarriers
  }
}

func boundedSeekTarget(_ target: MediaTimestamp, duration: MediaTimestamp) -> MediaTimestamp {
  guard case let .valid(time) = target else { return target }
  if time.value < 0, let zero = ValidMediaTime(value: 0, timescale: time.timescale) {
    return .valid(zero)
  }
  guard case let .valid(end) = duration, end.value >= 0 else { return target }
  // Compare rational timestamps without floating-point rounding or overflow.
  let requested = time.value.multipliedFullWidth(by: Int64(end.timescale))
  let limit = end.value.multipliedFullWidth(by: Int64(time.timescale))
  return (requested.high, requested.low) > (limit.high, limit.low) ? duration : target
}

func addingMediaTimestamp(_ base: MediaTimestamp, _ delta: MediaTimestamp) -> MediaTimestamp {
  guard case .valid(let lhs) = base, case .valid(let rhs) = delta else {
    return .invalid(.unmappable)
  }
  let divisor = greatestCommonDivisor(Int64(lhs.timescale), Int64(rhs.timescale))
  let lhsScale = Int64(rhs.timescale) / divisor
  let rhsScale = Int64(lhs.timescale) / divisor
  let (timescale64, timescaleOverflow) = Int64(lhs.timescale)
    .multipliedReportingOverflow(by: lhsScale)
  guard !timescaleOverflow, timescale64 > 0, timescale64 <= Int64(Int32.max) else {
    return .invalid(.overflow)
  }
  let (lhsValue, lhsOverflow) = lhs.value.multipliedReportingOverflow(by: lhsScale)
  let (rhsValue, rhsOverflow) = rhs.value.multipliedReportingOverflow(by: rhsScale)
  guard !lhsOverflow, !rhsOverflow else { return .invalid(.overflow) }
  let (sum, sumOverflow) = lhsValue.addingReportingOverflow(rhsValue)
  guard !sumOverflow, let valid = ValidMediaTime(value: max(sum, 0), timescale: Int32(timescale64))
  else { return .invalid(.overflow) }
  return .valid(valid)
}

private func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
  var a = lhs
  var b = rhs
  while b != 0 {
    let remainder = a % b
    a = b
    b = remainder
  }
  return max(a, 1)
}
