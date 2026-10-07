import CryptoKit
import Foundation

public enum DifferentialHarnessError: Error, Equatable, CustomStringConvertible {
  case invalidFixturePath(String)
  case missingFixture(String)
  case missingFixtureProvenance(String)
  case missingTruthDump(String)
  case fixtureHashMismatch(expected: String, actual: String)
  case failedFixtureAssertion(String)
  case undisposedFindings([String])
  case artifactDirectoryExists(String)
  case externalProcessFailed(String)
  case malformedArtifactInput(String)

  public var description: String {
    switch self {
    case .invalidFixturePath(let path): "Fixture path escapes its manifest directory: \(path)"
    case .missingFixture(let path): "Fixture is missing: \(path)"
    case .missingFixtureProvenance(let path): "Fixture provenance is incomplete: \(path)"
    case .missingTruthDump(let path): "Fixture truth dump is missing: \(path)"
    case .fixtureHashMismatch(let expected, let actual):
      "Fixture SHA-256 mismatch: expected \(expected), got \(actual)"
    case .failedFixtureAssertion(let name): "Fixture truth assertion failed: \(name)"
    case .undisposedFindings(let codes):
      "Differential findings require disposition: \(codes.joined(separator: ", "))"
    case .artifactDirectoryExists(let path): "Artifact directory already exists: \(path)"
    case .externalProcessFailed(let message): "External process failed: \(message)"
    case .malformedArtifactInput(let message): "Malformed artifact input: \(message)"
    }
  }
}

public enum SHA256Digest {
  public static func file(at url: URL) -> String {
    guard let stream = InputStream(url: url) else { return "" }
    stream.open()
    defer { stream.close() }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { return "" }
      if count == 0 { break }
      hasher.update(data: Data(buffer[0..<count]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public struct FixtureTruthAssertion: Codable, Equatable, Sendable {
  public let name: String
  public let passed: Bool
  public let evidence: String

  public init(name: String, passed: Bool, evidence: String) {
    self.name = name
    self.passed = passed
    self.evidence = evidence
  }
}

public struct DifferentialFixtureRecord: Codable, Equatable, Sendable {
  public let path: String
  public let sha256: String
  public let generatorCommand: String
  public let license: String
  public let origin: String
  public let truthPath: String
  public let assertions: [FixtureTruthAssertion]

  public init(
    path: String,
    sha256: String,
    generatorCommand: String,
    license: String,
    origin: String,
    truthPath: String,
    assertions: [FixtureTruthAssertion]
  ) {
    self.path = path
    self.sha256 = sha256
    self.generatorCommand = generatorCommand
    self.license = license
    self.origin = origin
    self.truthPath = truthPath
    self.assertions = assertions
  }
}

public struct DifferentialFixtureManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generatorRevision: String
  public let fixtures: [DifferentialFixtureRecord]

  public init(
    schemaVersion: Int = 1,
    generatorRevision: String,
    fixtures: [DifferentialFixtureRecord]
  ) {
    self.schemaVersion = schemaVersion
    self.generatorRevision = generatorRevision
    self.fixtures = fixtures
  }

  public func fixture(named name: String) -> DifferentialFixtureRecord? {
    fixtures.first { $0.path == name }
  }
}

public enum DifferentialFixtureCaseID: String, Codable, CaseIterable, Sendable {
  case h264CFR = "h264-cfr-aac"
  case hevc8 = "hevc-8bit-audio"
  case hevc10 = "hevc-10bit-p010"
  case vp9 = "vp9-8bit-10bit"
  case av1 = "av1-8bit-10bit"
  case cfrControl = "cfr-controls"
  case vfr
  case nonzeroOrigin = "nonzero-origin"
  case negativeOrigin = "negative-origin"
  case nonmonotonicTimestamps = "nonmonotonic-pts-dts"
  case missingDuration = "missing-duration"
  case corruptPackets = "corrupt-packets"
  case truncatedFiles = "truncated-files"
  case growingInput = "growing-unreadable-readable"
  case resolutionChange = "midstream-resolution-change"
  case pixelColorChange = "midstream-pixel-color-change"
  case multipleAudioTracks = "multiple-audio-tracks"
  case malformedTrackIDs = "malformed-duplicate-track-ids"
  case multichannelAudio = "multichannel-5-1-7-1"
  case audioFormatChange = "audio-sample-rate-layout-change"
  case srt = "embedded-external-srt"
  case ass = "embedded-external-ass"
  case ssaWebVTT = "external-ssa-webvtt"
  case fontAttachments = "font-attachments"
  case missingGlyph = "missing-glyph-font"
  case pgs
  case vobsub = "vobsub-dvd"
  case dvbSubtitle = "dvb-subtitle"
  case rotationMirror = "rotation-mirror"
  case anamorphic = "anamorphic-sar-clean-aperture"
  case colorMatrix = "bt601-709-2020-range"
  case chromaSiting = "chroma-siting"
  case hdr10 = "hdr10-pq"
  case hlg
  case sdrBT2020 = "sdr-bt2020"
  case interlaced = "interlaced-tff-bff"
  case audioOnly = "audio-only"
  case videoOnly = "video-only"
  case rapidNearEOF = "rapid-seeking-near-eof"
  case repeatedReplacement = "repeated-file-replacement"
  case closeAtBoundaries = "close-during-load-seek-decode-present"
}

public enum DifferentialFixtureCaseStatus: String, Codable, Sendable {
  case generated
  case adapterCovered = "adapter-covered"
  case environmentBlocked = "environment-blocked"
  case deferred
}

public struct DifferentialFixtureCaseRecord: Codable, Equatable, Sendable {
  public let id: DifferentialFixtureCaseID
  public let status: DifferentialFixtureCaseStatus
  public let fixturePaths: [String]?
  public let evidence: String?
  public let blocker: String?

  public init(
    id: DifferentialFixtureCaseID,
    status: DifferentialFixtureCaseStatus,
    fixturePaths: [String]? = nil,
    evidence: String? = nil,
    blocker: String? = nil
  ) {
    self.id = id
    self.status = status
    self.fixturePaths = fixturePaths
    self.evidence = evidence
    self.blocker = blocker
  }
}

public struct DifferentialFixtureMatrix: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let cases: [DifferentialFixtureCaseRecord]

  public init(schemaVersion: Int = 1, cases: [DifferentialFixtureCaseRecord]) {
    self.schemaVersion = schemaVersion
    self.cases = cases
  }
}

public enum DifferentialFixtureMatrixVerifier {
  public static func verify(_ matrix: DifferentialFixtureMatrix) throws {
    guard matrix.schemaVersion == 1 else {
      throw DifferentialHarnessError.malformedArtifactInput(
        "unsupported fixture matrix schema version \(matrix.schemaVersion)"
      )
    }
    let ids = matrix.cases.map(\.id)
    guard Set(ids).count == ids.count else {
      throw DifferentialHarnessError.malformedArtifactInput("duplicate fixture matrix case")
    }
    guard Set(ids) == Set(DifferentialFixtureCaseID.allCases) else {
      throw DifferentialHarnessError.malformedArtifactInput("fixture matrix is incomplete")
    }
    for record in matrix.cases {
      switch record.status {
      case .generated:
        guard !(record.fixturePaths ?? []).isEmpty else {
          throw DifferentialHarnessError.malformedArtifactInput(
            "generated fixture case \(record.id.rawValue) has no fixture path"
          )
        }
      case .adapterCovered:
        guard !(record.evidence ?? "").isEmpty else {
          throw DifferentialHarnessError.malformedArtifactInput(
            "adapter-covered case \(record.id.rawValue) has no evidence"
          )
        }
      case .environmentBlocked, .deferred:
        guard !(record.blocker ?? "").isEmpty else {
          throw DifferentialHarnessError.malformedArtifactInput(
            "blocked fixture case \(record.id.rawValue) has no blocker"
          )
        }
      }
    }
  }
}

extension DifferentialFixtureMatrix {
  public static var requiredPlan: Self {
    func generated(
      _ id: DifferentialFixtureCaseID,
      _ paths: [String],
      evidence: String? = nil
    ) -> DifferentialFixtureCaseRecord {
      .init(id: id, status: .generated, fixturePaths: paths, evidence: evidence)
    }
    func adapter(
      _ id: DifferentialFixtureCaseID,
      _ evidence: String
    ) -> DifferentialFixtureCaseRecord {
      .init(id: id, status: .adapterCovered, evidence: evidence)
    }
    func blocked(
      _ id: DifferentialFixtureCaseID,
      _ blocker: String
    ) -> DifferentialFixtureCaseRecord {
      .init(id: id, status: .environmentBlocked, blocker: blocker)
    }
    let bitmapBlocker =
      "No repository-generated bitmap-subtitle packet authoring source and no pinned CC0 sample are available; the installed FFmpeg encoder alone cannot create truthful compositions."
    return .init(cases: [
      generated(.h264CFR, ["h264-aac.mp4", "h264-aac.mkv"]),
      generated(.hevc8, ["hevc-flac.mkv"]),
      generated(.hevc10, ["hevc-10bit-aac.mkv"]),
      generated(.vp9, ["vp9-opus.mkv", "vp9-10bit-video-only.mkv"]),
      generated(.av1, ["av1-video-only.mkv", "av1-10bit-video-only.mkv"]),
      generated(.cfrControl, ["cfr-control.mkv"]),
      generated(.vfr, ["variable-frame-rate.mkv", "long-vfr-av-sync.mkv"]),
      generated(.nonzeroOrigin, ["nonzero-start.mkv"]),
      generated(.negativeOrigin, ["negative-origin.mpg"]),
      generated(.nonmonotonicTimestamps, ["discontinuous-timestamps.mkv"]),
      generated(.missingDuration, ["unknown-duration.h264"]),
      generated(.corruptPackets, ["corrupt-packets.mkv"]),
      generated(.truncatedFiles, ["truncated-h264.mp4"]),
      adapter(.growingInput, "Deterministic staged-input adapter qualification"),
      generated(.resolutionChange, ["midstream-resolution-change.ts"]),
      generated(.pixelColorChange, ["midstream-pixel-color-change.ts"]),
      generated(.multipleAudioTracks, ["multiple-audio.mkv", "multiple-audio-flags.mkv"]),
      adapter(.malformedTrackIDs, "Demux catalog normalization adapter tests"),
      generated(.multichannelAudio, ["audio-5.1.flac", "audio-7.1.flac"]),
      generated(.audioFormatChange, ["audio-rate-layout-change.ts"]),
      generated(.srt, ["external.srt", "embedded-srt.mkv"]),
      generated(.ass, ["external.ass", "heavy-animated.ass", "embedded-ass-font.mkv"]),
      generated(.ssaWebVTT, ["external.ssa", "external.vtt"]),
      generated(
        .fontAttachments,
        ["embedded-ass-font.mkv"],
        evidence: "Local-only system-font case is explicitly non-redistributable"
      ),
      generated(.missingGlyph, ["missing-glyph.ass"]),
      blocked(.pgs, bitmapBlocker),
      blocked(.vobsub, bitmapBlocker),
      blocked(.dvbSubtitle, bitmapBlocker),
      generated(
        .rotationMirror,
        [
          "rotated-90.mp4", "rotated-180.mp4", "rotated-270.mp4",
          "mirrored-horizontal.mp4",
        ],
        evidence: "All quarter turns and reflected display-matrix policy are generated"
      ),
      generated(.anamorphic, ["anamorphic-sar.mkv"]),
      generated(
        .colorMatrix,
        [
          "color-bt601-limited.mkv", "color-bt601-full.mkv",
          "color-bt709-limited.mkv", "color-bt709-full.mkv", "sdr-bt2020.mkv",
        ]
      ),
      generated(.chromaSiting, ["chroma-left.mkv", "chroma-center.mkv"]),
      generated(.hdr10, ["hdr10-pq-p010.mkv", "long-hevc-p010-av-sync.mkv"]),
      generated(.hlg, ["hlg-p010.mkv"]),
      generated(.sdrBT2020, ["sdr-bt2020.mkv"]),
      generated(.interlaced, ["interlaced-tff.mpg", "interlaced-bff.mpg"]),
      generated(
        .audioOnly,
        [
          "audio-only.flac", "audio-only-opus.mka", "audio-only-vorbis.ogg",
          "audio-only.mp3", "audio-only-pcm.wav",
        ]
      ),
      generated(.videoOnly, ["video-only.mp4", "av1-video-only.mkv"]),
      adapter(.rapidNearEOF, "Deterministic latest-seek and stale-EOF regressions"),
      adapter(.repeatedReplacement, "Deterministic runtime lease and epoch replacement fences"),
      adapter(.closeAtBoundaries, "Commit-barrier cancellation and callback tombstone tests"),
    ])
  }
}

public enum DifferentialFixtureVerifier {
  @discardableResult
  public static func verify(
    _ record: DifferentialFixtureRecord,
    in directory: URL
  ) throws -> URL {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    let fixture = root.appendingPathComponent(record.path).standardizedFileURL
      .resolvingSymlinksInPath()
    let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard fixture.path.hasPrefix(rootPrefix) else {
      throw DifferentialHarnessError.invalidFixturePath(record.path)
    }
    guard FileManager.default.fileExists(atPath: fixture.path) else {
      throw DifferentialHarnessError.missingFixture(record.path)
    }
    guard !record.generatorCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !record.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !record.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      record.sha256.count == 64,
      !record.assertions.isEmpty
    else {
      throw DifferentialHarnessError.missingFixtureProvenance(record.path)
    }
    let truth = root.appendingPathComponent(record.truthPath).standardizedFileURL
      .resolvingSymlinksInPath()
    guard truth.path.hasPrefix(rootPrefix), FileManager.default.fileExists(atPath: truth.path)
    else {
      throw DifferentialHarnessError.missingTruthDump(record.truthPath)
    }
    let actual = SHA256Digest.file(at: fixture)
    guard actual == record.sha256 else {
      throw DifferentialHarnessError.fixtureHashMismatch(
        expected: record.sha256,
        actual: actual
      )
    }
    if let failed = record.assertions.first(where: { !$0.passed }) {
      throw DifferentialHarnessError.failedFixtureAssertion(failed.name)
    }
    return fixture
  }
}

public enum DifferentialRunnerIdentity: String, Codable, Sendable {
  case mpv
  case illiquid
}

public enum DifferentialRunnerMode: String, Codable, Sendable {
  case headlessSemantic
  case rendererBacked
  case faultInjection
}

public enum DifferentialSemanticCaseID: String, Codable, CaseIterable, Sendable {
  case openCatalogSelection = "open-catalog-selection"
  case timelineCapabilities = "timeline-capabilities"
  case seeking
  case drainAndEOF = "drain-and-eof"
  case trackAndSubtitle = "track-and-subtitle"
  case faultAndRace = "fault-and-race"
  case presentation
}

public struct DifferentialSemanticCase: Codable, Equatable, Sendable {
  public let id: DifferentialSemanticCaseID
  public let fixtureNames: [String]

  public init(id: DifferentialSemanticCaseID, fixtureNames: [String]) {
    self.id = id
    self.fixtureNames = fixtureNames
  }
}

public enum DifferentialSemanticMatrix {
  public static let requiredCases: [DifferentialSemanticCase] = [
    .init(
      id: .openCatalogSelection,
      fixtureNames: ["h264-aac.mp4", "multiple-audio-flags.mkv", "vp9-opus.mkv"]
    ),
    .init(
      id: .timelineCapabilities,
      fixtureNames: ["nonzero-start.mkv", "negative-origin.mpg", "unknown-duration.h264"]
    ),
    .init(
      id: .seeking,
      fixtureNames: ["cfr-control.mkv", "variable-frame-rate.mkv", "audio-only.mp3"]
    ),
    .init(
      id: .drainAndEOF,
      fixtureNames: [
        "delayed-audio-tail.mkv", "truncated-h264.mp4", "corrupt-packets.mkv",
        "audio-only.flac", "video-only.mp4",
      ]
    ),
    .init(
      id: .trackAndSubtitle,
      fixtureNames: [
        "multiple-audio-flags.mkv", "embedded-srt.mkv", "external.ass", "external.vtt",
      ]
    ),
    .init(id: .faultAndRace, fixtureNames: ["h264-aac.mp4"]),
    .init(
      id: .presentation,
      fixtureNames: [
        "rotated-90.mp4", "anamorphic-sar.mkv", "color-bt709-limited.mkv",
        "hdr10-pq-p010.mkv", "hlg-p010.mkv",
      ]
    ),
  ]
}

public enum DifferentialStreamKind: String, Codable, Hashable, Sendable {
  case video
  case audio
  case subtitle
}

public struct DifferentialSelectedStream: Codable, Equatable, Sendable {
  public let kind: DifferentialStreamKind
  public let index: Int32
  public let codec: String
  public let language: String?
  public let dispositions: [String]
  public let stableID: String
  public let selectionReason: String

  public init(
    kind: DifferentialStreamKind,
    index: Int32,
    codec: String,
    language: String?,
    dispositions: [String],
    stableID: String,
    selectionReason: String
  ) {
    self.kind = kind
    self.index = index
    self.codec = codec
    self.language = language
    self.dispositions = dispositions
    self.stableID = stableID
    self.selectionReason = selectionReason
  }
}

public enum DifferentialReadiness: Codable, Equatable, Sendable {
  case measured(monotonicSeconds: Double, evidence: String)
  case unmeasured(reason: String)
}

public enum DifferentialSeekMode: String, Codable, Sendable {
  case exact
  case keyframe
  case preview
}

public struct DifferentialSeekResult: Codable, Equatable, Sendable {
  public let mode: DifferentialSeekMode
  public let requestedTarget: Double
  public let lowLevelTarget: Double?
  public let actualVideoPTS: Double?
  public let firstAudioSamplePTS: Double?
  public let completionReason: String
  public let latencyMilliseconds: Double

  public init(
    mode: DifferentialSeekMode,
    requestedTarget: Double,
    lowLevelTarget: Double?,
    actualVideoPTS: Double?,
    firstAudioSamplePTS: Double?,
    completionReason: String,
    latencyMilliseconds: Double
  ) {
    self.mode = mode
    self.requestedTarget = requestedTarget
    self.lowLevelTarget = lowLevelTarget
    self.actualVideoPTS = actualVideoPTS
    self.firstAudioSamplePTS = firstAudioSamplePTS
    self.completionReason = completionReason
    self.latencyMilliseconds = latencyMilliseconds
  }
}

public enum DifferentialEOFOutcome: String, Codable, Sendable {
  case clean
  case truncated
  case readFailure
  case cancelled
  case timedOut
  case notReached
}

public struct DifferentialHardwareDecoderObservation: Codable, Equatable, Sendable {
  public let requested: Bool
  public let configured: Bool
  public let actualFrameFormat: String?
  public let actualHardwareOutput: Bool?
  public let fallbackOrRecreationReason: String?

  public init(
    requested: Bool,
    configured: Bool,
    actualFrameFormat: String? = nil,
    actualHardwareOutput: Bool? = nil,
    fallbackOrRecreationReason: String? = nil
  ) {
    self.requested = requested
    self.configured = configured
    self.actualFrameFormat = actualFrameFormat
    self.actualHardwareOutput = actualHardwareOutput
    self.fallbackOrRecreationReason = fallbackOrRecreationReason
  }
}

public struct DifferentialEOFTimingObservation: Codable, Equatable, Sendable {
  public let demuxEOF: Double?
  public let decoderEOF: Double?
  public let resamplerEOF: Double?
  public let lastEnqueue: Double?
  public let lastPresentationEnd: Double?
  public let productEOF: Double?
  public let outcome: DifferentialEOFOutcome
  public let limitation: String?

  public init(
    demuxEOF: Double? = nil,
    decoderEOF: Double? = nil,
    resamplerEOF: Double? = nil,
    lastEnqueue: Double? = nil,
    lastPresentationEnd: Double? = nil,
    productEOF: Double? = nil,
    outcome: DifferentialEOFOutcome,
    limitation: String? = nil
  ) {
    self.demuxEOF = demuxEOF
    self.decoderEOF = decoderEOF
    self.resamplerEOF = resamplerEOF
    self.lastEnqueue = lastEnqueue
    self.lastPresentationEnd = lastPresentationEnd
    self.productEOF = productEOF
    self.outcome = outcome
    self.limitation = limitation
  }
}

public struct DifferentialTrackSwitchObservation: Codable, Equatable, Sendable {
  public let oldStableID: String?
  public let requestedStableID: String?
  public let effectiveStableID: String?
  public let preparationMilliseconds: Double?
  public let commitMilliseconds: Double?
  public let outcome: String

  public init(
    oldStableID: String? = nil,
    requestedStableID: String? = nil,
    effectiveStableID: String? = nil,
    preparationMilliseconds: Double? = nil,
    commitMilliseconds: Double? = nil,
    outcome: String
  ) {
    self.oldStableID = oldStableID
    self.requestedStableID = requestedStableID
    self.effectiveStableID = effectiveStableID
    self.preparationMilliseconds = preparationMilliseconds
    self.commitMilliseconds = commitMilliseconds
    self.outcome = outcome
  }
}

public struct DifferentialSubtitleObservation: Codable, Equatable, Sendable {
  public let activeCueIDs: [String]
  public let geometryHash: String?
  public let maskHash: String?
  public let visibleAt: Double?
  public let clearedAt: Double?
  public let capability: String

  public init(
    activeCueIDs: [String] = [],
    geometryHash: String? = nil,
    maskHash: String? = nil,
    visibleAt: Double? = nil,
    clearedAt: Double? = nil,
    capability: String
  ) {
    self.activeCueIDs = activeCueIDs
    self.geometryHash = geometryHash
    self.maskHash = maskHash
    self.visibleAt = visibleAt
    self.clearedAt = clearedAt
    self.capability = capability
  }
}

public struct DifferentialMemoryObservation: Codable, Equatable, Sendable {
  public let residentBytes: UInt64?
  public let highWaterBytes: UInt64?
  public let postCloseBytes: UInt64?
  public let queueBytes: Int?
  public let queueDurationSeconds: Double?
  public let pixelBufferCount: Int?
  public let limitation: String?

  public init(
    residentBytes: UInt64? = nil,
    highWaterBytes: UInt64? = nil,
    postCloseBytes: UInt64? = nil,
    queueBytes: Int? = nil,
    queueDurationSeconds: Double? = nil,
    pixelBufferCount: Int? = nil,
    limitation: String? = nil
  ) {
    self.residentBytes = residentBytes
    self.highWaterBytes = highWaterBytes
    self.postCloseBytes = postCloseBytes
    self.queueBytes = queueBytes
    self.queueDurationSeconds = queueDurationSeconds
    self.pixelBufferCount = pixelBufferCount
    self.limitation = limitation
  }
}

public struct DifferentialRecoveryObservation: Codable, Equatable, Sendable {
  public let errorDomain: String
  public let stableCode: String
  public let retryCount: Int
  public let action: String
  public let finalState: String
  public let liveWorkerCount: Int?
  public let pendingCallbackCount: Int?

  public init(
    errorDomain: String,
    stableCode: String,
    retryCount: Int,
    action: String,
    finalState: String,
    liveWorkerCount: Int? = nil,
    pendingCallbackCount: Int? = nil
  ) {
    self.errorDomain = errorDomain
    self.stableCode = stableCode
    self.retryCount = retryCount
    self.action = action
    self.finalState = finalState
    self.liveWorkerCount = liveWorkerCount
    self.pendingCallbackCount = pendingCallbackCount
  }
}

public struct DifferentialTimelineEvent: Codable, Equatable, Sendable {
  public let name: String
  public let monotonicSeconds: Double
  public let mediaTime: Double?
  public let detail: String?

  public init(
    name: String,
    monotonicSeconds: Double,
    mediaTime: Double? = nil,
    detail: String? = nil
  ) {
    self.name = name
    self.monotonicSeconds = monotonicSeconds
    self.mediaTime = mediaTime
    self.detail = detail
  }
}

public struct DifferentialPlayerResult: Codable, Equatable, Sendable {
  public let runner: DifferentialRunnerIdentity
  public let mode: DifferentialRunnerMode
  public let processExitCode: Int32
  public let opened: Bool
  public let selectedStreams: [DifferentialSelectedStream]
  public let firstDecoded: [DifferentialStreamKind: Double]
  public let firstEnqueued: [DifferentialStreamKind: Double]
  public let readiness: [DifferentialStreamKind: DifferentialReadiness]
  public let seek: DifferentialSeekResult?
  public let eof: DifferentialEOFOutcome
  public let timeline: [DifferentialTimelineEvent]
  public let limitations: [String]
  public let hardwareDecoder: DifferentialHardwareDecoderObservation?
  public let eofTiming: DifferentialEOFTimingObservation?
  public let trackSwitch: DifferentialTrackSwitchObservation?
  public let subtitleOutput: DifferentialSubtitleObservation?
  public let memory: DifferentialMemoryObservation?
  public let recovery: DifferentialRecoveryObservation?

  public init(
    runner: DifferentialRunnerIdentity,
    mode: DifferentialRunnerMode,
    processExitCode: Int32,
    opened: Bool,
    selectedStreams: [DifferentialSelectedStream],
    firstDecoded: [DifferentialStreamKind: Double],
    firstEnqueued: [DifferentialStreamKind: Double],
    readiness: [DifferentialStreamKind: DifferentialReadiness],
    seek: DifferentialSeekResult?,
    eof: DifferentialEOFOutcome,
    timeline: [DifferentialTimelineEvent],
    limitations: [String],
    hardwareDecoder: DifferentialHardwareDecoderObservation? = nil,
    eofTiming: DifferentialEOFTimingObservation? = nil,
    trackSwitch: DifferentialTrackSwitchObservation? = nil,
    subtitleOutput: DifferentialSubtitleObservation? = nil,
    memory: DifferentialMemoryObservation? = nil,
    recovery: DifferentialRecoveryObservation? = nil
  ) {
    self.runner = runner
    self.mode = mode
    self.processExitCode = processExitCode
    self.opened = opened
    self.selectedStreams = selectedStreams
    self.firstDecoded = firstDecoded
    self.firstEnqueued = firstEnqueued
    self.readiness = readiness
    self.seek = seek
    self.eof = eof
    self.timeline = timeline
    self.limitations = limitations
    self.hardwareDecoder = hardwareDecoder
    self.eofTiming = eofTiming
    self.trackSwitch = trackSwitch
    self.subtitleOutput = subtitleOutput
    self.memory = memory
    self.recovery = recovery
  }
}

public struct DifferentialFinding: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct DifferentialComparison: Codable, Equatable, Sendable {
  public let passed: Bool
  public let findings: [DifferentialFinding]

  public init(passed: Bool, findings: [DifferentialFinding]) {
    self.passed = passed
    self.findings = findings
  }
}

public enum DifferentialDispositionCategory: String, Codable, Sendable {
  case illiquidBug
  case intentionalProductDifference
  case dependencyVersionDifference
  case nondeterministicPlatformBehavior
  case oracleLimitation
  case fixtureDefect
}

public struct DifferentialDisposition: Codable, Equatable, Sendable {
  public let findingCode: String
  public let category: DifferentialDispositionCategory
  public let rationale: String

  public init(
    findingCode: String,
    category: DifferentialDispositionCategory,
    rationale: String
  ) {
    self.findingCode = findingCode
    self.category = category
    self.rationale = rationale
  }
}

public enum DifferentialArtifactPolicy {
  public static func validate(
    comparison: DifferentialComparison,
    dispositions: [DifferentialDisposition]
  ) throws {
    guard !comparison.passed else { return }
    let disposed = Set(dispositions.map(\.findingCode))
    let missing = comparison.findings.map(\.code).filter { !disposed.contains($0) }
    if !missing.isEmpty {
      throw DifferentialHarnessError.undisposedFindings(missing)
    }
  }
}

public struct DifferentialComponentIdentity: Codable, Equatable, Sendable {
  public let name: String
  public let revision: String?
  public let binaryPath: String
  public let sha256: String
  public let version: String
  public let configuration: String

  public init(
    name: String,
    revision: String?,
    binaryPath: String,
    sha256: String,
    version: String,
    configuration: String
  ) {
    self.name = name
    self.revision = revision
    self.binaryPath = binaryPath
    self.sha256 = sha256
    self.version = version
    self.configuration = configuration
  }
}

public struct DifferentialRunManifest: Codable, Equatable, Sendable {
  public let harnessRevision: String
  public let fixtureGeneratorRevision: String
  public let illiquid: DifferentialComponentIdentity
  public let mpv: DifferentialComponentIdentity
  public let runtimeDependencies: [DifferentialComponentIdentity]
  public let system: [String: String]
  public let presentationEnvironment: [String: String]
  public let options: [String]
  public let environment: [String: String]
  public let wallClockStart: String
  public let wallClockEnd: String

  public init(
    harnessRevision: String,
    fixtureGeneratorRevision: String,
    illiquid: DifferentialComponentIdentity,
    mpv: DifferentialComponentIdentity,
    runtimeDependencies: [DifferentialComponentIdentity],
    system: [String: String],
    presentationEnvironment: [String: String],
    options: [String],
    environment: [String: String],
    wallClockStart: String,
    wallClockEnd: String
  ) {
    self.harnessRevision = harnessRevision
    self.fixtureGeneratorRevision = fixtureGeneratorRevision
    self.illiquid = illiquid
    self.mpv = mpv
    self.runtimeDependencies = runtimeDependencies
    self.system = system
    self.presentationEnvironment = presentationEnvironment
    self.options = options
    self.environment = environment
    self.wallClockStart = wallClockStart
    self.wallClockEnd = wallClockEnd
  }
}

public struct DifferentialRunArtifact: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let manifest: DifferentialRunManifest
  public let fixture: DifferentialFixtureRecord
  public let oracle: DifferentialPlayerResult
  public let native: DifferentialPlayerResult
  public let comparison: DifferentialComparison
  public let dispositions: [DifferentialDisposition]
  public let faultPolicyRecords: [DifferentialFaultPolicyRecord]
  public let limitations: [String]

  public init(
    schemaVersion: Int = 1,
    manifest: DifferentialRunManifest,
    fixture: DifferentialFixtureRecord,
    oracle: DifferentialPlayerResult,
    native: DifferentialPlayerResult,
    comparison: DifferentialComparison,
    dispositions: [DifferentialDisposition],
    faultPolicyRecords: [DifferentialFaultPolicyRecord],
    limitations: [String]
  ) {
    self.schemaVersion = schemaVersion
    self.manifest = manifest
    self.fixture = fixture
    self.oracle = oracle
    self.native = native
    self.comparison = comparison
    self.dispositions = dispositions
    self.faultPolicyRecords = faultPolicyRecords
    self.limitations = limitations
  }
}

public enum DifferentialArtifactWriter {
  public static func write(
    _ artifact: DifferentialRunArtifact,
    oracleLog: Data,
    nativeLog: Data,
    ipcLog: Data,
    ffprobeTruth: Data,
    to directory: URL
  ) throws {
    try DifferentialArtifactPolicy.validate(
      comparison: artifact.comparison,
      dispositions: artifact.dispositions
    )
    guard !FileManager.default.fileExists(atPath: directory.path) else {
      throw DifferentialHarnessError.artifactDirectoryExists(directory.path)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(artifact).write(
      to: directory.appendingPathComponent("result.json"),
      options: .atomic
    )
    try encoder.encode(artifact.manifest).write(
      to: directory.appendingPathComponent("run-manifest.json"),
      options: .atomic
    )
    try encoder.encode(artifact.faultPolicyRecords).write(
      to: directory.appendingPathComponent("fault-policy-records.json"),
      options: .atomic
    )
    try oracleLog.write(to: directory.appendingPathComponent("mpv.log"), options: .atomic)
    try nativeLog.write(to: directory.appendingPathComponent("illiquid.log"), options: .atomic)
    try ipcLog.write(to: directory.appendingPathComponent("mpv-ipc.jsonl"), options: .atomic)
    try ffprobeTruth.write(
      to: directory.appendingPathComponent("fixture.ffprobe.json"),
      options: .atomic
    )
    let timeline = normalizedTimeline(artifact)
    try Data(timeline.utf8).write(
      to: directory.appendingPathComponent("normalized-timeline.txt"),
      options: .atomic
    )
  }

  private static func normalizedTimeline(_ artifact: DifferentialRunArtifact) -> String {
    func lines(
      _ identity: DifferentialRunnerIdentity,
      _ events: [DifferentialTimelineEvent]
    ) -> [String] {
      events.map {
        let media = $0.mediaTime.map { String(format: " media=%.6f", $0) } ?? ""
        let detail = $0.detail.map { " detail=\($0)" } ?? ""
        return String(
          format: "%@ mono=%.6f event=%@%@%@",
          identity.rawValue,
          $0.monotonicSeconds,
          $0.name,
          media,
          detail
        )
      }
    }
    return
      (lines(.mpv, artifact.oracle.timeline)
      + lines(.illiquid, artifact.native.timeline)).joined(separator: "\n") + "\n"
  }
}

public enum DifferentialFaultScenario: String, CaseIterable, Codable, Sendable {
  case delayedOutcome
  case duplicateOutcome
  case staleOutcome
  case failedOutcome
  case cancelledOutcome
  case blockedDataQueue
  case reorderedOutcome
  case closeDuringBlockedRead
  case oldHardwareErrorAfterReplacement
  case staleEndOfStreamAfterSeek
}

public enum DifferentialFaultOracleMode: String, Codable, Sendable {
  case liveProcess
  case pinnedBehaviorRecord
}

public struct DifferentialFaultPolicyRecord: Codable, Equatable, Sendable {
  public let scenario: DifferentialFaultScenario
  public let oracleMode: DifferentialFaultOracleMode
  public let referenceRevision: String
  public let referenceEvidence: String
  public let expectedIlliquidPolicy: String

  public init(
    scenario: DifferentialFaultScenario,
    oracleMode: DifferentialFaultOracleMode,
    referenceRevision: String,
    referenceEvidence: String,
    expectedIlliquidPolicy: String
  ) {
    self.scenario = scenario
    self.oracleMode = oracleMode
    self.referenceRevision = referenceRevision
    self.referenceEvidence = referenceEvidence
    self.expectedIlliquidPolicy = expectedIlliquidPolicy
  }
}

public enum DifferentialFaultTranslator {
  public static func requiredPolicyRecords(
    mpvRevision: String
  ) -> [DifferentialFaultPolicyRecord] {
    DifferentialFaultScenario.allCases.map { scenario in
      let policy: String
      let evidence: String
      switch scenario {
      case .delayedOutcome:
        policy = "Accept only if the captured authority and generation are still current"
        evidence = "player/client.c and player/loadfile.c command completion ownership"
      case .duplicateOutcome:
        policy = "Treat duplicate completion as idempotent and emit no second effect"
        evidence = "player command completion is single-owner at the pinned revision"
      case .staleOutcome:
        policy = "Drop ordinary stale output; retain cleanup-only resource custody"
        evidence = "player/playloop.c seek and playback restart state ownership"
      case .failedOutcome:
        policy = "Emit a typed failure and apply the bounded recovery budget"
        evidence = "video/decode/vd_lavc.c fallback and player error propagation"
      case .cancelledOutcome:
        policy = "Cancellation cannot report success or resume transport"
        evidence = "demux/demux.c cancellation and player/loadfile.c teardown"
      case .blockedDataQueue:
        policy = "Stop and seek use control-priority paths that do not wait for data capacity"
        evidence = "demux/demux.c wakeup and cancellation behavior"
      case .reorderedOutcome:
        policy = "Sequence by authority; out-of-order older completion is stale"
        evidence = "player/core.h playback state and asynchronous command ownership"
      case .closeDuringBlockedRead:
        policy = "Interrupt input before joining workers and release every callback lease"
        evidence = "stream cancellation and demux teardown at the pinned revision"
      case .oldHardwareErrorAfterReplacement:
        policy = "Old decoder failure cannot seek, flush, or replace the current decoder"
        evidence = "video/decode/vd_lavc.c decoder instance ownership"
      case .staleEndOfStreamAfterSeek:
        policy = "EOS from an old generation cannot finalize the new generation"
        evidence = "player/playloop.c EOF and queued seek ordering"
      }
      return DifferentialFaultPolicyRecord(
        scenario: scenario,
        oracleMode: .pinnedBehaviorRecord,
        referenceRevision: mpvRevision,
        referenceEvidence: evidence,
        expectedIlliquidPolicy: policy
      )
    }
  }
}

public enum DifferentialComparator {
  public static func compare(
    oracle: DifferentialPlayerResult,
    native: DifferentialPlayerResult,
    frameTolerance: Double
  ) -> DifferentialComparison {
    var findings: [DifferentialFinding] = []
    if !oracle.opened || oracle.processExitCode != 0 {
      findings.append(.init(code: "oracleOpenFailed", message: "mpv did not open cleanly"))
    }
    if !native.opened || native.processExitCode != 0 {
      findings.append(
        .init(
          code: "nativeOpenFailed",
          message: "Illiquid did not open cleanly"
        ))
    }
    let oracleStreams = oracle.selectedStreams.map(streamComparisonKey).sorted()
    let nativeStreams = native.selectedStreams.map(streamComparisonKey).sorted()
    if oracleStreams != nativeStreams {
      findings.append(
        .init(
          code: "selectedStreamsDiffer",
          message: "Selected stream identities do not match"
        ))
    }
    if let oracleSeek = oracle.seek, let nativeSeek = native.seek {
      if let oracleVideo = oracleSeek.actualVideoPTS,
        let nativeVideo = nativeSeek.actualVideoPTS,
        abs(oracleVideo - nativeVideo) > frameTolerance
      {
        findings.append(
          .init(
            code: "exactVideoLandingDiffers",
            message: "Exact video landing differs by more than one frame tolerance"
          ))
      }
      if let audio = nativeSeek.firstAudioSamplePTS,
        audio + 0.000_000_5 < nativeSeek.requestedTarget
      {
        findings.append(
          .init(
            code: "nativeAudioBeforeExactTarget",
            message: "Illiquid emitted audio before the normalized exact target"
          ))
      }
    } else if oracle.seek != nil || native.seek != nil {
      findings.append(.init(code: "seekResultMissing", message: "Only one runner sought"))
    }
    if oracle.eof != native.eof {
      findings.append(.init(code: "eofOutcomeDiffers", message: "EOF outcomes differ"))
    }
    return DifferentialComparison(passed: findings.isEmpty, findings: findings)
  }

  private static func streamComparisonKey(_ stream: DifferentialSelectedStream) -> String {
    [
      stream.kind.rawValue,
      String(stream.index),
      stream.codec,
      stream.language ?? "",
      stream.dispositions.sorted().joined(separator: ","),
    ].joined(separator: "|")
  }
}
