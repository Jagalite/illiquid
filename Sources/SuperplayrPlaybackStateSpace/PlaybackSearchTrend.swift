public struct PlaybackSearchTrendBaseline: Codable, Hashable, Sendable {
  public struct Entry: Codable, Hashable, Sendable {
    public let model: PlaybackSearchModel
    public let seedProfile: String
    public let modelVersion: UInt32
    public let stateCount: Int
    public let edgeCount: Int
    public let canonicalDigest: String

    public init(
      model: PlaybackSearchModel,
      seedProfile: String,
      modelVersion: UInt32,
      stateCount: Int,
      edgeCount: Int,
      canonicalDigest: String
    ) {
      self.model = model
      self.seedProfile = seedProfile
      self.modelVersion = modelVersion
      self.stateCount = stateCount
      self.edgeCount = edgeCount
      self.canonicalDigest = canonicalDigest
    }
  }

  public let schemaVersion: UInt32
  public let tolerancePercent: Int
  public let entries: [Entry]

  public init(
    schemaVersion: UInt32 = 1,
    tolerancePercent: Int = 25,
    entries: [Entry]
  ) {
    self.schemaVersion = schemaVersion
    self.tolerancePercent = tolerancePercent
    self.entries = entries
  }
}

public enum PlaybackSearchTrendViolationKind: String, Codable, Hashable, Sendable {
  case missingBaseline
  case stateCountDrift
  case edgeCountDrift
  case normalizationDrift
  case modelVersionRegression
}

public struct PlaybackSearchTrendViolation: Codable, Hashable, Sendable {
  public let kind: PlaybackSearchTrendViolationKind
  public let details: String
}

public enum PlaybackSearchTrendEvaluator {
  public static func evaluate(
    _ summary: PlaybackSearchSummary,
    against baseline: PlaybackSearchTrendBaseline,
    tolerancePercent: Int? = nil
  ) -> [PlaybackSearchTrendViolation] {
    guard
      let entry = baseline.entries.first(where: {
        $0.model == summary.model && $0.seedProfile == summary.seedProfile
      })
    else {
      return [
        .init(
          kind: .missingBaseline,
          details: "No baseline entry exists for \(summary.model.rawValue)/\(summary.seedProfile)."
        )
      ]
    }
    var violations: [PlaybackSearchTrendViolation] = []
    let tolerance = tolerancePercent ?? baseline.tolerancePercent
    if percentageDifference(summary.stateCount, entry.stateCount) > tolerance {
      violations.append(
        .init(
          kind: .stateCountDrift,
          details: "State count changed from \(entry.stateCount) to \(summary.stateCount)."
        ))
    }
    if percentageDifference(summary.edgeCount, entry.edgeCount) > tolerance {
      violations.append(
        .init(
          kind: .edgeCountDrift,
          details: "Edge count changed from \(entry.edgeCount) to \(summary.edgeCount)."
        ))
    }
    if summary.modelVersion < entry.modelVersion {
      violations.append(
        .init(
          kind: .modelVersionRegression,
          details: "Model version regressed below the recorded baseline."
        ))
    }
    if summary.modelVersion == entry.modelVersion,
      summary.canonicalDigest != entry.canonicalDigest
    {
      violations.append(
        .init(
          kind: .normalizationDrift,
          details: "Reachable-key digest changed without a model-version change."
        ))
    }
    return violations
  }

  private static func percentageDifference(_ value: Int, _ baseline: Int) -> Int {
    guard baseline > 0 else { return value == 0 ? 0 : 100 }
    return abs(value - baseline) * 100 / baseline
  }
}
