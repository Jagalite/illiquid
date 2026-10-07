import Foundation

public enum DifferentialStagedInputStage: Equatable, Sendable {
  case temporarilyUnreadable
  case readable(Data)
}

public enum DifferentialStagedInputError: Error, Equatable, Sendable {
  case cancelled
  case retryLimitExceeded
  case endOfInput
}

/// A deterministic policy seam for inputs that temporarily return no readable
/// bytes. Production AVIO integration can drive the same stages without tests
/// depending on wall-clock sleeps or a racing temporary-file writer.
public struct DifferentialStagedInputAdapter: Sendable {
  private var stages: [DifferentialStagedInputStage]
  private let retryLimit: Int
  private var isCancelled = false

  public private(set) var retryCount = 0

  public init(stages: [DifferentialStagedInputStage], retryLimit: Int) {
    self.stages = stages
    self.retryLimit = max(retryLimit, 0)
  }

  public mutating func cancel() {
    isCancelled = true
  }

  public mutating func read() throws -> Data {
    guard !isCancelled else { throw DifferentialStagedInputError.cancelled }

    while !stages.isEmpty {
      guard !isCancelled else { throw DifferentialStagedInputError.cancelled }
      switch stages.removeFirst() {
      case .readable(let data):
        return data
      case .temporarilyUnreadable:
        retryCount += 1
        guard retryCount <= retryLimit else {
          throw DifferentialStagedInputError.retryLimitExceeded
        }
      }
    }

    throw DifferentialStagedInputError.endOfInput
  }
}
