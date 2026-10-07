import Darwin
import Foundation
import IlliquidNativePlayback

private let pinnedMPVRevision = "94335ab87ab225ca3e36e0faeac831639d3e1d4e"

@main
struct IlliquidDifferentialHarnessMain {
  @MainActor static func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "acceptance-report":
      let matrixDirectory = URL(
        fileURLWithPath: try require(
          value(after: "--matrix-directory", in: arguments),
          "missing --matrix-directory"
        ), isDirectory: true
      ).standardizedFileURL
      let output = URL(
        fileURLWithPath: try require(
          value(after: "--output", in: arguments),
          "missing --output"
        )
      ).standardizedFileURL
      let artifacts = try loadRunArtifacts(from: matrixDirectory)
      let deterministic = DifferentialAcceptanceEvaluator.deterministicEvidence(
        raceReport: DifferentialRaceQualification.run(),
        semanticPolicyReport: DifferentialSemanticPolicyQualification.run()
      )
      let evidence = DifferentialAcceptanceEvaluator.liveSemanticEvidence(
        results: artifacts.map { ($0.oracle, $0.native) },
        merging: deterministic
      )
      let report = DifferentialAcceptanceEvaluator.evaluate(evidence)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(report).write(to: output, options: .atomic)
      guard !report.hasFailure else {
        throw DifferentialHarnessError.failedFixtureAssertion("acceptance-report")
      }
      print(output.path)
      return
    case "deterministic-acceptance":
      let output = URL(
        fileURLWithPath: try require(
          value(after: "--output", in: arguments),
          "missing --output"
        )
      ).standardizedFileURL
      let raceReport = DifferentialRaceQualification.run()
      let policyReport = DifferentialSemanticPolicyQualification.run()
      let evidence = DifferentialAcceptanceEvaluator.deterministicEvidence(
        raceReport: raceReport,
        semanticPolicyReport: policyReport
      )
      let report = DifferentialAcceptanceEvaluator.evaluate(evidence)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(report).write(to: output, options: .atomic)
      guard !report.hasFailure else {
        throw DifferentialHarnessError.failedFixtureAssertion(
          "deterministic-acceptance-report"
        )
      }
      print(output.path)
      return
    case "deterministic-semantic-policies":
      let output = URL(
        fileURLWithPath: try require(
          value(after: "--output", in: arguments),
          "missing --output"
        )
      ).standardizedFileURL
      let report = DifferentialSemanticPolicyQualification.run()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(report).write(to: output, options: .atomic)
      guard report.passed else {
        throw DifferentialHarnessError.failedFixtureAssertion(
          "deterministic-semantic-policy-report"
        )
      }
      print(output.path)
      return
    case "deterministic-races":
      let output = URL(
        fileURLWithPath: try require(
          value(after: "--output", in: arguments),
          "missing --output"
        )
      ).standardizedFileURL
      let report = DifferentialRaceQualification.run()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(report).write(to: output, options: .atomic)
      guard report.passed else {
        throw DifferentialHarnessError.failedFixtureAssertion("deterministic-race-report")
      }
      print(output.path)
      return
    case "fixture-matrix":
      let directory = URL(
        fileURLWithPath: try require(
          value(after: "--directory", in: arguments),
          "missing --directory"
        ), isDirectory: true
      ).standardizedFileURL
      try writeFixtureMatrix(directory: directory)
      print(directory.appendingPathComponent("fixture-matrix.json").path)
      return
    case "fixture-manifest":
      let directory = URL(
        fileURLWithPath: try require(
          value(after: "--directory", in: arguments),
          "missing --directory"
        ), isDirectory: true
      ).standardizedFileURL
      let revision = try require(
        value(after: "--generator-revision", in: arguments),
        "missing --generator-revision"
      )
      try writeFixtureManifest(directory: directory, generatorRevision: revision)
      print(directory.appendingPathComponent("fixture-manifest.json").path)
      return
    case "verify-fixture-manifest":
      let directory = URL(
        fileURLWithPath: try require(
          value(after: "--directory", in: arguments),
          "missing --directory"
        ), isDirectory: true
      ).standardizedFileURL
      try verifyFixtureManifest(in: directory)
      print("verified \(directory.appendingPathComponent("fixture-manifest.json").path)")
      return
    case "native-renderer-smoke":
      let fixture = URL(
        fileURLWithPath: try require(
          value(after: "--fixture", in: arguments),
          "missing --fixture"
        )
      ).standardizedFileURL
      let output = URL(
        fileURLWithPath: try require(
          value(after: "--output", in: arguments),
          "missing --output"
        ), isDirectory: true
      ).standardizedFileURL
      let run = try NativeDifferentialRunner.runRendererBackedSmoke(
        fixtureURL: fixture,
        seekTarget: 1.25
      )
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(run.result).write(
        to: output.appendingPathComponent("native-renderer-result.json"),
        options: .atomic
      )
      try Data(run.log.utf8).write(
        to: output.appendingPathComponent("native-renderer.log"),
        options: .atomic
      )
      print(output.path)
      return
    case "semantic-matrix":
      let directory = URL(
        fileURLWithPath: try require(
          value(after: "--directory", in: arguments),
          "missing --directory"
        ), isDirectory: true
      ).standardizedFileURL
      let output = URL(
        fileURLWithPath: try require(
          value(after: "--output", in: arguments),
          "missing --output"
        ), isDirectory: true
      ).standardizedFileURL
      let mpv = URL(
        fileURLWithPath: try value(after: "--mpv", in: arguments, required: false)
          ?? "/opt/homebrew/bin/mpv"
      ).standardizedFileURL
      let revision = try value(
        after: "--mpv-source-revision",
        in: arguments,
        required: false
      )
      if let revision, revision != pinnedMPVRevision {
        throw DifferentialHarnessError.malformedArtifactInput(
          "mpv source revision must match the pinned revision \(pinnedMPVRevision)"
        )
      }
      try runSemanticMatrix(
        fixtureDirectory: directory,
        outputDirectory: output,
        mpvURL: mpv,
        mpvSourceRevision: revision
      )
      print(output.path)
      return
    case "smoke": break
    default:
      throw DifferentialHarnessError.malformedArtifactInput(
        "usage: IlliquidDifferentialHarness {acceptance-report|deterministic-acceptance|deterministic-races|deterministic-semantic-policies|fixture-matrix|fixture-manifest|verify-fixture-manifest|semantic-matrix|native-renderer-smoke|smoke} ..."
      )
    }
    let fixtureURL = URL(
      fileURLWithPath: try require(
        value(after: "--fixture", in: arguments),
        "missing --fixture"
      )
    )
    .standardizedFileURL
    let outputURL = URL(
      fileURLWithPath: try require(
        value(after: "--output", in: arguments),
        "missing --output"
      )
    )
    .standardizedFileURL
    let mpvURL = URL(
      fileURLWithPath: try value(
        after: "--mpv",
        in: arguments,
        required: false
      )
        ?? "/opt/homebrew/bin/mpv"
    ).standardizedFileURL
    let mpvSourceRevision = try value(
      after: "--mpv-source-revision",
      in: arguments,
      required: false
    )
    if let mpvSourceRevision, mpvSourceRevision != pinnedMPVRevision {
      throw DifferentialHarnessError.malformedArtifactInput(
        "mpv source revision must match the pinned revision \(pinnedMPVRevision)"
      )
    }
    try runSmoke(
      fixtureURL: fixtureURL,
      outputURL: outputURL,
      mpvURL: mpvURL,
      mpvSourceRevision: mpvSourceRevision
    )
    print(outputURL.path)
  }

  private static func loadRunArtifacts(
    from directory: URL
  ) throws -> [DifferentialRunArtifact] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw DifferentialHarnessError.malformedArtifactInput(
        "cannot enumerate semantic matrix at \(directory.path)"
      )
    }
    let decoder = JSONDecoder()
    var artifacts: [DifferentialRunArtifact] = []
    for case let url as URL in enumerator where url.lastPathComponent == "result.json" {
      artifacts.append(
        try decoder.decode(DifferentialRunArtifact.self, from: Data(contentsOf: url)))
    }
    guard !artifacts.isEmpty else {
      throw DifferentialHarnessError.malformedArtifactInput(
        "semantic matrix contains no result.json artifacts"
      )
    }
    return artifacts
  }

  private static func runSmoke(
    fixtureURL: URL,
    outputURL: URL,
    mpvURL: URL,
    mpvSourceRevision: String?
  ) throws {
    let fixtureDirectory = fixtureURL.deletingLastPathComponent()
    let fixtureManifestURL = fixtureDirectory.appendingPathComponent("fixture-manifest.json")
    let decoder = JSONDecoder()
    let fixtureManifest = try decoder.decode(
      DifferentialFixtureManifest.self,
      from: Data(contentsOf: fixtureManifestURL)
    )
    let fixture = try require(
      fixtureManifest.fixture(named: fixtureURL.lastPathComponent),
      "fixture is absent from fixture-manifest.json: \(fixtureURL.lastPathComponent)"
    )
    _ = try DifferentialFixtureVerifier.verify(fixture, in: fixtureDirectory)

    let wallStart = ISO8601DateFormatter().string(from: Date())
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("illiquid-differential-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    let ffprobe = try runProcess(
      executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
      arguments: [
        "-v", "error", "-print_format", "json", "-show_format", "-show_streams",
        "-show_packets", "-show_frames", fixtureURL.path,
      ]
    )
    guard ffprobe.status == 0 else {
      throw DifferentialHarnessError.externalProcessFailed(ffprobe.stderrString)
    }

    let mpv = try runMPV(
      executable: mpvURL,
      fixtureURL: fixtureURL,
      seekTarget: 1.25,
      stagingDirectory: staging
    )
    let native = try NativeDifferentialRunner.runHeadlessSemanticSmoke(
      fixtureURL: fixtureURL,
      seekTarget: 1.25
    )
    let comparison = DifferentialComparator.compare(
      oracle: mpv.result,
      native: native.result,
      frameTolerance: 1.0 / 30.0
    )
    let dispositions = comparison.findings.map { finding in
      DifferentialDisposition(
        findingCode: finding.code,
        category: finding.code == "nativeOpenFailed"
          ? .nondeterministicPlatformBehavior
          : .oracleLimitation,
        rationale: finding.code == "nativeOpenFailed"
          ? "The managed test environment rejected CoreVideo pixel-buffer allocation; logs retain the exact CVReturn"
          : "The P0 smoke uses recorded headless AO/VO; presentation parity remains unmeasured"
      )
    }
    let harnessURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let gitRevision = try commandText("/usr/bin/git", ["rev-parse", "HEAD"])
    let harnessHash = SHA256Digest.file(at: harnessURL)
    let worktreeStatus = try commandText("/usr/bin/git", ["status", "--porcelain"])
    let harnessRevision =
      worktreeStatus.isEmpty
      ? gitRevision
      : "git:\(gitRevision);worktree:dirty;binary-sha256:\(harnessHash)"
    let mpvVersion = try runProcess(executable: mpvURL, arguments: ["--version"])
    let ffmpegVersion = try runProcess(
      executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
      arguments: ["-version"]
    )
    let manifest = DifferentialRunManifest(
      harnessRevision: harnessRevision,
      fixtureGeneratorRevision: fixtureManifest.generatorRevision,
      illiquid: .init(
        name: "IlliquidDifferentialHarness",
        revision: harnessRevision,
        binaryPath: harnessURL.path,
        sha256: harnessHash,
        version:
          "Swift package executable; FFmpeg runtime \(NativeDifferentialRunner.ffmpegRuntimeVersion); libass runtime \(NativeDifferentialRunner.libassRuntimeVersion)",
        configuration: NativeDifferentialRunner.ffmpegRuntimeConfiguration
      ),
      mpv: .init(
        name: "mpv",
        revision: mpvSourceRevision,
        binaryPath: mpvURL.path,
        sha256: SHA256Digest.file(at: mpvURL.resolvingSymlinksInPath()),
        version: mpvVersion.stdoutString,
        configuration: "--no-config --vo=null --ao=null --hwdec=no --hr-seek=yes"
      ),
      runtimeDependencies: try dynamicMediaClosure(
        binaries: [harnessURL, mpvURL],
        configuration: ffmpegVersion.stdoutString
      ),
      system: systemRecord().merging([
        "requested-mpv-source-pin": pinnedMPVRevision,
        "mpv-binary-pin-status": mpvSourceRevision == nil
          ? "unverified-binary-revision"
          : "verified-by-caller-against-source-build",
      ]) { _, new in new },
      presentationEnvironment: [
        "mode": "headless-semantic",
        "display": "unmeasured",
        "audio-device": "unmeasured",
        "visible-readiness": "unmeasured",
        "audible-readiness": "unmeasured",
      ],
      options: mpv.options,
      environment: relevantEnvironment(),
      wallClockStart: wallStart,
      wallClockEnd: ISO8601DateFormatter().string(from: Date())
    )
    let artifact = DifferentialRunArtifact(
      manifest: manifest,
      fixture: fixture,
      oracle: mpv.result,
      native: native.result,
      comparison: comparison,
      dispositions: dispositions,
      faultPolicyRecords: DifferentialFaultTranslator.requiredPolicyRecords(
        mpvRevision: pinnedMPVRevision
      ),
      limitations: [
        "P0 smoke is headless semantic evidence, not visible or audible presentation proof",
        "Physical display, audio-route, HDR, fullscreen, PiP, and lifecycle gates are unmeasured",
      ]
        + (mpvSourceRevision == nil
          ? [
            "The mpv executable revision is unverified; the expected source pin is recorded separately"
          ] : [])
    )
    try DifferentialArtifactWriter.write(
      artifact,
      oracleLog: mpv.log,
      nativeLog: Data(native.log.utf8),
      ipcLog: mpv.ipcLog,
      ffprobeTruth: ffprobe.stdout,
      to: outputURL
    )
  }

  private struct SemanticMatrixEntry: Codable {
    let caseID: DifferentialSemanticCaseID
    let fixture: String
    let status: String
    let artifactPath: String?
    let limitation: String?
  }

  private struct SemanticMatrixSummary: Codable {
    let mpvBinary: String
    let mpvSourceRevision: String?
    let expectedMPVSourceRevision: String
    let entries: [SemanticMatrixEntry]
  }

  private static func runSemanticMatrix(
    fixtureDirectory: URL,
    outputDirectory: URL,
    mpvURL: URL,
    mpvSourceRevision: String?
  ) throws {
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )
    let raceReportURL = outputDirectory.appendingPathComponent("deterministic-races.json")
    let policyReportURL = outputDirectory.appendingPathComponent(
      "deterministic-semantic-policies.json"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let raceReport = DifferentialRaceQualification.run()
    let policyReport = DifferentialSemanticPolicyQualification.run()
    try encoder.encode(raceReport).write(to: raceReportURL, options: .atomic)
    try encoder.encode(policyReport).write(to: policyReportURL, options: .atomic)
    guard raceReport.passed, policyReport.passed else {
      throw DifferentialHarnessError.failedFixtureAssertion(
        "deterministic semantic prerequisites"
      )
    }
    let textExtensions = Set(["ass", "srt", "ssa", "vtt"])
    var entries: [SemanticMatrixEntry] = []
    for semanticCase in DifferentialSemanticMatrix.requiredCases {
      for fixtureName in semanticCase.fixtureNames {
        if semanticCase.id == .faultAndRace {
          entries.append(
            .init(
              caseID: semanticCase.id,
              fixture: fixtureName,
              status: "deterministic-artifact-written",
              artifactPath: raceReportURL.path,
              limitation: "Live mpv cannot deterministically inject commit-boundary faults"
            ))
          continue
        }
        if textExtensions.contains(URL(fileURLWithPath: fixtureName).pathExtension.lowercased()) {
          entries.append(
            .init(
              caseID: semanticCase.id,
              fixture: fixtureName,
              status: "deterministic-policy-and-fixture-artifact",
              artifactPath: policyReportURL.path,
              limitation:
                "External subtitle conversion and policy are covered in-process; combined live-mpv subtitle attachment is separate"
            ))
          continue
        }
        let artifact = outputDirectory.appendingPathComponent(
          "\(semanticCase.id.rawValue)--\(fixtureName)",
          isDirectory: true
        )
        do {
          try runSmoke(
            fixtureURL: fixtureDirectory.appendingPathComponent(fixtureName),
            outputURL: artifact,
            mpvURL: mpvURL,
            mpvSourceRevision: mpvSourceRevision
          )
          entries.append(
            .init(
              caseID: semanticCase.id,
              fixture: fixtureName,
              status: "artifact-written",
              artifactPath: artifact.path,
              limitation: nil
            ))
        } catch {
          entries.append(
            .init(
              caseID: semanticCase.id,
              fixture: fixtureName,
              status: "environment-or-runner-blocked",
              artifactPath: nil,
              limitation: String(describing: error)
            ))
        }
      }
    }
    let summary = SemanticMatrixSummary(
      mpvBinary: mpvURL.path,
      mpvSourceRevision: mpvSourceRevision,
      expectedMPVSourceRevision: pinnedMPVRevision,
      entries: entries
    )
    try encoder.encode(summary).write(
      to: outputDirectory.appendingPathComponent("semantic-matrix-summary.json"),
      options: .atomic
    )
  }
}

private func writeFixtureMatrix(directory: URL) throws {
  let matrix = DifferentialFixtureMatrix.requiredPlan
  try DifferentialFixtureMatrixVerifier.verify(matrix)
  let available = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
  for record in matrix.cases where record.status == .generated {
    for path in record.fixturePaths ?? [] where !available.contains(path) {
      throw DifferentialHarnessError.malformedArtifactInput(
        "fixture matrix path is missing: \(path)"
      )
    }
  }
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(matrix).write(
    to: directory.appendingPathComponent("fixture-matrix.json"),
    options: .atomic
  )
}

private func writeFixtureManifest(directory: URL, generatorRevision: String) throws {
  let fileManager = FileManager.default
  let truthDirectory = directory.appendingPathComponent("Truth", isDirectory: true)
  if fileManager.fileExists(atPath: truthDirectory.path) {
    try fileManager.removeItem(at: truthDirectory)
  }
  try fileManager.createDirectory(at: truthDirectory, withIntermediateDirectories: true)
  let names = try fileManager.contentsOfDirectory(atPath: directory.path)
    .filter {
      $0 != "Truth"
        && $0 != "fixture-manifest.json"
        && $0 != "fixture-matrix.json"
        && !$0.hasPrefix(".")
    }
    .sorted()
  var records: [DifferentialFixtureRecord] = []
  for name in names {
    let fileURL = directory.appendingPathComponent(name)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { continue }
    let truthName = "\(name).ffprobe.json"
    let truthURL = truthDirectory.appendingPathComponent(truthName)
    let probe = try fixtureTruth(for: fileURL)
    try probe.data.write(to: truthURL, options: .atomic)
    let assertions = try fixtureAssertions(
      name: name,
      fileURL: fileURL,
      probeObject: probe.object
    )
    let record = DifferentialFixtureRecord(
      path: name,
      sha256: SHA256Digest.file(at: fileURL),
      generatorCommand:
        "ILLIQUID_NATIVE_QUALIFICATION_DURATION=<seconds> Scripts/generate-native-fixtures.sh <fixture-dir> # emits \(name)",
      license: name == "embedded-ass-font.mkv"
        ? "local-only; system font is not redistributed"
        : "CC0-1.0 synthetic fixture",
      origin: name == "embedded-ass-font.mkv"
        ? "repository-generated media plus a local system font; local qualification only"
        : "repository-generated lavfi pattern, tone, or repository-authored text",
      truthPath: "Truth/\(truthName)",
      assertions: assertions
    )
    _ = try DifferentialFixtureVerifier.verify(record, in: directory)
    records.append(record)
  }
  let manifest = DifferentialFixtureManifest(
    generatorRevision: generatorRevision,
    fixtures: records
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(manifest).write(
    to: directory.appendingPathComponent("fixture-manifest.json"),
    options: .atomic
  )
  try verifyFixtureManifest(in: directory)
}

private func verifyFixtureManifest(in directory: URL) throws {
  let manifest = try JSONDecoder().decode(
    DifferentialFixtureManifest.self,
    from: Data(contentsOf: directory.appendingPathComponent("fixture-manifest.json"))
  )
  guard !manifest.generatorRevision.isEmpty, !manifest.fixtures.isEmpty else {
    throw DifferentialHarnessError.malformedArtifactInput("empty fixture manifest")
  }
  for fixture in manifest.fixtures {
    _ = try DifferentialFixtureVerifier.verify(fixture, in: directory)
  }
}

private struct FixtureTruth {
  let data: Data
  let object: [String: Any]
}

private func fixtureTruth(for fileURL: URL) throws -> FixtureTruth {
  let textExtensions = Set(["ass", "srt", "ssa", "vtt"])
  if textExtensions.contains(fileURL.pathExtension.lowercased()) {
    let data = try Data(contentsOf: fileURL)
    let object: [String: Any] = [
      "text_fixture": [
        "byte_count": data.count,
        "utf8": String(data: data, encoding: .utf8) != nil,
      ]
    ]
    return FixtureTruth(
      data: try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
      ),
      object: object
    )
  }
  let output = try runProcess(
    executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
    arguments: [
      "-v", "error", "-print_format", "json", "-show_format", "-show_streams",
      "-show_chapters", "-show_packets", "-show_frames", fileURL.path,
    ]
  )
  guard let parsed = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any]
  else {
    throw DifferentialHarnessError.externalProcessFailed(
      "ffprobe truth is not JSON for \(fileURL.lastPathComponent): \(output.stderrString)"
    )
  }
  var object = parsed
  object["probe_status"] = output.status
  object["probe_stderr"] = output.stderrString
  return FixtureTruth(
    data: try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
    object: object
  )
}

private func fixtureAssertions(
  name: String,
  fileURL: URL,
  probeObject: [String: Any]
) throws -> [FixtureTruthAssertion] {
  let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
  let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
  var assertions = [
    FixtureTruthAssertion(
      name: "file-nonempty",
      passed: byteCount > 0,
      evidence: "\(byteCount) bytes"
    )
  ]
  if let text = probeObject["text_fixture"] as? [String: Any] {
    assertions.append(
      .init(
        name: "valid-utf8-text",
        passed: text["utf8"] as? Bool == true,
        evidence: "utf8=\(text["utf8"] ?? false)"
      ))
    return assertions
  }

  let streams = probeObject["streams"] as? [[String: Any]] ?? []
  assertions.append(
    .init(
      name: "has-playable-stream",
      passed: streams.contains {
        ["video", "audio", "subtitle"].contains($0["codec_type"] as? String)
      },
      evidence: streams.compactMap { $0["codec_type"] as? String }.joined(separator: ",")
    ))
  let combined = probeObject["packets_and_frames"] as? [[String: Any]] ?? []
  let packets =
    probeObject["packets"] as? [[String: Any]]
    ?? combined.filter { $0["type"] as? String == "packet" }
  let frames =
    probeObject["frames"] as? [[String: Any]]
    ?? combined.filter { $0["type"] as? String == "frame" }
  let format = probeObject["format"] as? [String: Any] ?? [:]
  let videoFrames = frames.filter { $0["media_type"] as? String == "video" }

  if name == "variable-frame-rate.mkv" {
    let pts = frames.compactMap { frame -> Double? in
      guard frame["media_type"] as? String == "video" else { return nil }
      return double(frame["pts_time"] ?? frame["best_effort_timestamp_time"])
    }
    let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }.filter { $0 > 0.000_001 }
    let rounded = Set(deltas.map { Int(($0 * 1_000).rounded()) })
    assertions.append(
      .init(
        name: "irregular-video-pts-deltas",
        passed: rounded.count >= 2 && (deltas.max() ?? 0) > (deltas.min() ?? 0) * 1.4,
        evidence: "delta-ms=\(rounded.sorted())"
      ))
  }
  if name == "cfr-control.mkv" {
    let pts = videoFrames.compactMap { double($0["pts_time"] ?? $0["best_effort_timestamp_time"]) }
    let deltas = zip(pts.dropFirst(), pts).map { $0 - $1 }.filter { $0 > 0.000_001 }
    let rounded = Set(deltas.map { Int(($0 * 1_000_000).rounded()) })
    let minimum = deltas.min() ?? 0
    let maximum = deltas.max() ?? .infinity
    assertions.append(
      .init(
        name: "uniform-video-pts-deltas",
        passed: !deltas.isEmpty && maximum - minimum <= 0.002
          && abs((deltas.reduce(0, +) / Double(deltas.count)) - (1.0 / 24.0)) <= 0.001,
        evidence: "delta-us=\(rounded.sorted())"
      ))
    let keyIndices = videoFrames.enumerated().compactMap { index, frame in
      (frame["key_frame"] as? Int) == 1 ? index : nil
    }
    let keyDistances = zip(keyIndices.dropFirst(), keyIndices).map { $0 - $1 }
    assertions.append(
      .init(
        name: "fixed-gop",
        passed: !keyDistances.isEmpty && Set(keyDistances).count == 1,
        evidence: "keyframe-distances=\(keyDistances)"
      ))
  }
  if name == "nonzero-start.mkv" {
    let start = double(format["start_time"])
    assertions.append(
      .init(
        name: "positive-timeline-origin",
        passed: (start ?? 0) >= 1.5,
        evidence: "start_time=\(start.map { String($0) } ?? "missing")"
      ))
    let chapters = probeObject["chapters"] as? [[String: Any]] ?? []
    let starts = chapters.compactMap { double($0["start_time"]) }
    assertions.append(
      .init(
        name: "chapters-retain-positive-source-origin",
        passed: starts.count == 2 && (starts.min() ?? 0) >= 1.5,
        evidence: "source-chapter-starts=\(starts)"
      ))
  }
  if name == "negative-origin.mpg" {
    let minimum = packets.flatMap { [double($0["pts_time"]), double($0["dts_time"])] }
      .compactMap { $0 }.min()
    assertions.append(
      .init(
        name: "negative-packet-origin",
        passed: (minimum ?? 0) < 0,
        evidence: "minimum-pts-or-dts=\(minimum.map { String($0) } ?? "missing")"
      ))
    let decodedFrameCount = frames.filter { $0["media_type"] as? String == "video" }.count
    assertions.append(
      .init(
        name: "negative-origin-retains-all-frames",
        passed: decodedFrameCount >= 90,
        evidence: "decoded-video-frames=\(decodedFrameCount)"
      ))
  }
  if name == "unknown-duration.h264" {
    let duration = double(format["duration"])
    assertions.append(
      .init(
        name: "duration-remains-unknown",
        passed: duration == nil,
        evidence: "duration=\(duration.map { String($0) } ?? "unknown")"
      ))
  }
  if name == "corrupt-packets.mkv" || name == "truncated-h264.mp4" {
    let decode = try runProcess(
      executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
      arguments: ["-hide_banner", "-v", "error", "-i", fileURL.path, "-f", "null", "-"]
    )
    assertions.append(
      .init(
        name: "decode-error-observed",
        passed: !decode.stderr.isEmpty,
        evidence: String(decoding: decode.stderr.prefix(240), as: UTF8.self)
      ))
  }
  if name == "delayed-audio-tail.mkv" {
    let types = Dictionary(
      uniqueKeysWithValues: streams.compactMap { stream -> (Int, String)? in
        guard let index = stream["index"] as? Int,
          let type = stream["codec_type"] as? String
        else { return nil }
        return (index, type)
      })
    var ends: [String: Double] = [:]
    for packet in packets {
      guard let index = packet["stream_index"] as? Int,
        let type = types[index],
        let pts = double(packet["pts_time"])
      else { continue }
      let end = pts + (double(packet["duration_time"]) ?? 0)
      ends[type] = max(ends[type] ?? -.infinity, end)
    }
    let delta = (ends["audio"] ?? 0) - (ends["video"] ?? 0)
    assertions.append(
      .init(
        name: "audio-tail-after-video",
        passed: delta >= 0.25,
        evidence: "audio-minus-video-end=\(delta)"
      ))
  }
  if name == "midstream-resolution-change.ts" {
    let sizes = Set(
      frames.compactMap { frame -> String? in
        guard frame["media_type"] as? String == "video",
          let width = frame["width"] as? Int,
          let height = frame["height"] as? Int
        else { return nil }
        return "\(width)x\(height)"
      })
    assertions.append(
      .init(
        name: "multiple-decoded-resolutions",
        passed: sizes.count >= 2,
        evidence: sizes.sorted().joined(separator: ",")
      ))
  }
  if name == "discontinuous-timestamps.mkv" {
    let pts = packets.compactMap { packet -> Double? in
      guard let index = packet["stream_index"] as? Int,
        streams.contains(where: {
          ($0["index"] as? Int) == index && ($0["codec_type"] as? String) == "video"
        })
      else { return nil }
      return double(packet["pts_time"])
    }
    let regressions = zip(pts.dropFirst(), pts).filter { $0 < $1 }.count
    assertions.append(
      .init(
        name: "nonmonotonic-video-pts",
        passed: regressions > 0,
        evidence: "packet-pts-regressions=\(regressions)"
      ))
  }
  if name == "midstream-pixel-color-change.ts" {
    let configurations = Set(
      videoFrames.map { frame in
        [
          frame["pix_fmt"] as? String ?? "unknown",
          String(describing: frame["color_primaries"] ?? "unknown"),
          String(describing: frame["color_transfer"] ?? "unknown"),
          String(describing: frame["color_space"] ?? "unknown"),
        ].joined(separator: ":")
      })
    assertions.append(
      .init(
        name: "multiple-pixel-or-color-configurations",
        passed: configurations.count >= 2,
        evidence: configurations.sorted().joined(separator: ",")
      ))
  }
  if name == "audio-rate-layout-change.ts" {
    let configurations = Set(
      frames.compactMap { frame -> String? in
        guard frame["media_type"] as? String == "audio" else { return nil }
        return "\(frame["sample_rate"] ?? "unknown"):\(frame["channel_layout"] ?? "unknown")"
      })
    assertions.append(
      .init(
        name: "multiple-audio-configurations",
        passed: configurations.count >= 2,
        evidence: configurations.sorted().joined(separator: ",")
      ))
  }
  if name == "multiple-audio-flags.mkv" {
    let audio = streams.filter { $0["codec_type"] as? String == "audio" }
    let defaultCount = audio.filter {
      (($0["disposition"] as? [String: Any])?["default"] as? Int) == 1
    }.count
    let commentaryCount = audio.filter {
      (($0["disposition"] as? [String: Any])?["comment"] as? Int) == 1
    }.count
    assertions.append(
      .init(
        name: "audio-selection-flags",
        passed: audio.count == 3 && defaultCount == 1 && commentaryCount == 1,
        evidence: "audio=\(audio.count),default=\(defaultCount),commentary=\(commentaryCount)"
      ))
  }
  if name == "anamorphic-sar.mkv" {
    let ratios = Set(videoFrames.compactMap { $0["sample_aspect_ratio"] as? String })
    assertions.append(
      .init(
        name: "anamorphic-sample-aspect-ratio",
        passed: ratios.contains { $0 != "1:1" && $0 != "N/A" },
        evidence: ratios.sorted().joined(separator: ",")
      ))
  }
  if name == "sdr-bt2020.mkv" {
    let configurations = Set(
      videoFrames.map { frame in
        "\(frame["color_primaries"] ?? "unknown"):\(frame["color_transfer"] ?? "unknown")"
      })
    assertions.append(
      .init(
        name: "bt2020-sdr-transfer",
        passed: configurations.contains("bt2020:bt709"),
        evidence: configurations.sorted().joined(separator: ",")
      ))
  }
  if name == "interlaced-tff.mpg" || name == "interlaced-bff.mpg" {
    let expectedTopFieldFirst = name.contains("tff") ? 1 : 0
    let interlaced = videoFrames.filter { ($0["interlaced_frame"] as? Int) == 1 }
    let matching = interlaced.filter {
      ($0["top_field_first"] as? Int) == expectedTopFieldFirst
    }
    assertions.append(
      .init(
        name: expectedTopFieldFirst == 1 ? "top-field-first" : "bottom-field-first",
        passed: !interlaced.isEmpty && matching.count == interlaced.count,
        evidence: "interlaced=\(interlaced.count),matching=\(matching.count)"
      ))
  }
  if name == "mirrored-horizontal.mp4" {
    let matrices = streams.flatMap { stream -> [String] in
      let sideData = stream["side_data_list"] as? [[String: Any]] ?? []
      return sideData.compactMap { $0["displaymatrix"] as? String }
    }
    assertions.append(
      .init(
        name: "reflected-display-matrix",
        passed: matrices.contains { matrix in
          matrix.contains("-65536") && matrix.contains("65536")
        },
        evidence: matrices.joined(separator: " | ")
      ))
  }
  return assertions
}

private func double(_ value: Any?) -> Double? {
  if let number = value as? NSNumber { return number.doubleValue }
  if let string = value as? String { return Double(string) }
  return nil
}

private struct ProcessOutput {
  let status: Int32
  let stdout: Data
  let stderr: Data
  var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
  var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

private struct MPVRunOutput {
  let result: DifferentialPlayerResult
  let log: Data
  let ipcLog: Data
  let options: [String]
}

private struct TimestampedIPCLine {
  let monotonicSeconds: Double
  let data: Data
}

private final class IPCLineRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private var stored: [TimestampedIPCLine] = []
  private let started = ProcessInfo.processInfo.systemUptime

  func consume(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[..<newline]
      stored.append(
        .init(
          monotonicSeconds: ProcessInfo.processInfo.systemUptime - started,
          data: Data(line)
        ))
      buffer.removeSubrange(...newline)
    }
  }

  func finish() -> [TimestampedIPCLine] {
    lock.lock()
    defer { lock.unlock() }
    if !buffer.isEmpty {
      stored.append(
        .init(
          monotonicSeconds: ProcessInfo.processInfo.systemUptime - started,
          data: buffer
        ))
      buffer.removeAll()
    }
    return stored
  }

  func containsEvent(_ name: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return stored.contains { line in
      guard
        let object = try? JSONSerialization.jsonObject(with: line.data)
          as? [String: Any]
      else { return false }
      return object["event"] as? String == name
    }
  }

  func response(requestID: Int) -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return stored.lazy.compactMap { line in
      try? JSONSerialization.jsonObject(with: line.data) as? [String: Any]
    }.first { ($0["request_id"] as? Int) == requestID }
  }
}

private func runMPV(
  executable: URL,
  fixtureURL: URL,
  seekTarget: Double,
  stagingDirectory: URL
) throws -> MPVRunOutput {
  let mpvLog = stagingDirectory.appendingPathComponent("mpv.log")
  var options = [
    "--no-config", "--load-scripts=no", "--vo=null", "--ao=null", "--hwdec=no",
    "--hr-seek=yes", "--pause=yes", "--idle=no", "--keep-open=no",
    "--terminal=no", "--input-terminal=no", "--input-ipc-client=fd://0",
    "--log-file=\(mpvLog.path)", "--msg-level=all=v", fixtureURL.path,
  ]
  if fixtureURL.pathExtension.lowercased() == "h264" {
    options.insert("--demuxer-lavf-o=framerate=30", at: options.count - 1)
  }
  signal(SIGPIPE, SIG_IGN)
  var socketPair: [Int32] = [0, 0]
  guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &socketPair) == 0 else {
    throw DifferentialHarnessError.externalProcessFailed("socketpair failed: \(errno)")
  }
  let parentIPC = FileHandle(fileDescriptor: socketPair[0], closeOnDealloc: true)
  let childIPC = FileHandle(fileDescriptor: socketPair[1], closeOnDealloc: false)
  let recorder = IPCLineRecorder()
  parentIPC.readabilityHandler = { handle in recorder.consume(handle.availableData) }
  let process = Process()
  process.executableURL = executable
  process.arguments = options
  process.standardInput = childIPC
  process.standardError = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  try process.run()
  Darwin.close(socketPair[1])

  func send(_ object: [String: Any]) throws -> Bool {
    guard process.isRunning else { return false }
    let data = try JSONSerialization.data(withJSONObject: object)
    do {
      try parentIPC.write(contentsOf: data + Data([0x0A]))
      return true
    } catch {
      let cocoa = error as NSError
      let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError
      if !process.isRunning
        || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EPIPE))
      {
        return false
      }
      throw error
    }
  }
  _ = try send(["command": ["observe_property", 1, "time-pos"], "request_id": 1])
  _ = try send(["command": ["observe_property", 2, "pause"], "request_id": 2])
  _ = try send(["command": ["observe_property", 3, "eof-reached"], "request_id": 3])
  let loadDeadline = Date().addingTimeInterval(5)
  while !recorder.containsEvent("file-loaded"), process.isRunning, Date() < loadDeadline {
    Thread.sleep(forTimeInterval: 0.01)
  }
  guard recorder.containsEvent("file-loaded") else {
    process.terminate()
    process.waitUntilExit()
    throw DifferentialHarnessError.externalProcessFailed("mpv did not emit file-loaded")
  }
  _ = try send(["command": ["get_property", "track-list"], "request_id": 4])
  let trackDeadline = Date().addingTimeInterval(1)
  while recorder.response(requestID: 4) == nil, process.isRunning, Date() < trackDeadline {
    Thread.sleep(forTimeInterval: 0.005)
  }
  if let tracks = recorder.response(requestID: 4)?["data"] as? [[String: Any]],
    !tracks.contains(where: {
      $0["type"] as? String == "sub" && $0["selected"] as? Bool == true
    }),
    let subtitleID = tracks.first(where: {
      guard $0["type"] as? String == "sub", let codec = $0["codec"] as? String else {
        return false
      }
      return ["ass", "ssa", "subrip", "srt", "webvtt", "text"].contains(codec)
    })?["id"] as? Int
  {
    _ = try send(["command": ["set_property", "sid", subtitleID], "request_id": 8])
    let subtitleDeadline = Date().addingTimeInterval(1)
    while recorder.response(requestID: 8) == nil, process.isRunning, Date() < subtitleDeadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
    _ = try send(["command": ["get_property", "track-list"], "request_id": 9])
  }
  _ = try send(["command": ["set_property", "pause", true], "request_id": 5])
  _ = try send(["command": ["seek", seekTarget, "absolute+exact"], "request_id": 6])
  Thread.sleep(forTimeInterval: 0.10)
  _ = try send(["command": ["set_property", "pause", false], "request_id": 7])

  let deadline = Date().addingTimeInterval(15)
  while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
  if process.isRunning { process.terminate() }
  process.waitUntilExit()
  parentIPC.readabilityHandler = nil
  recorder.consume(parentIPC.readDataToEndOfFile())
  let lines = recorder.finish()

  var selectedStreams: [DifferentialSelectedStream] = []
  var timeline: [DifferentialTimelineEvent] = []
  var firstSeekTime: Double?
  var eof: DifferentialEOFOutcome = .notReached
  var seekCommandSeen = false
  var opened = false
  var rawIPC = Data()
  for line in lines {
    rawIPC.append(Data(String(format: "%.6f ", line.monotonicSeconds).utf8))
    rawIPC.append(line.data)
    rawIPC.append(0x0A)
    guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any]
    else { continue }
    if let event = object["event"] as? String,
      event == "start-file" || event == "file-loaded"
    {
      opened = true
      timeline.append(.init(name: event, monotonicSeconds: line.monotonicSeconds))
    }
    if object["event"] as? String == "end-file" {
      eof = object["reason"] as? String == "eof" ? .clean : .readFailure
      timeline.append(
        .init(
          name: "end-file",
          monotonicSeconds: line.monotonicSeconds,
          detail: object["reason"] as? String
        ))
    }
    if (object["request_id"] as? Int) == 4 || (object["request_id"] as? Int) == 9,
      let tracks = object["data"] as? [[String: Any]]
    {
      selectedStreams = parseMPVTracks(tracks)
      timeline.append(.init(name: "tracks-ready", monotonicSeconds: line.monotonicSeconds))
    }
    if (object["request_id"] as? Int) == 6,
      object["error"] as? String == "success"
    {
      seekCommandSeen = true
      timeline.append(.init(name: "seek-accepted", monotonicSeconds: line.monotonicSeconds))
    }
    if object["event"] as? String == "property-change" {
      let name = object["name"] as? String
      if name == "pause", let paused = object["data"] as? Bool {
        timeline.append(
          .init(
            name: paused ? "pause" : "resume",
            monotonicSeconds: line.monotonicSeconds
          ))
      }
      if name == "time-pos", seekCommandSeen,
        let value = object["data"] as? Double,
        value + 0.001 >= seekTarget,
        firstSeekTime == nil
      {
        firstSeekTime = value
        timeline.append(
          .init(
            name: "seek-output",
            monotonicSeconds: line.monotonicSeconds,
            mediaTime: value
          ))
      }
      if name == "eof-reached", object["data"] as? Bool == true {
        eof = .clean
        timeline.append(.init(name: "eof", monotonicSeconds: line.monotonicSeconds))
      }
    }
  }
  let result = DifferentialPlayerResult(
    runner: .mpv,
    mode: .headlessSemantic,
    processExitCode: process.terminationStatus,
    opened: opened && !selectedStreams.isEmpty,
    selectedStreams: selectedStreams,
    firstDecoded: [:],
    firstEnqueued: [:],
    readiness: Dictionary(
      uniqueKeysWithValues: selectedStreams.map {
        ($0.kind, .unmeasured(reason: "headless null output"))
      }),
    seek: .init(
      mode: .exact,
      requestedTarget: seekTarget,
      lowLevelTarget: nil,
      actualVideoPTS: firstSeekTime,
      firstAudioSamplePTS: nil,
      completionReason: firstSeekTime == nil ? "unmeasured" : "time-pos-observed",
      latencyMilliseconds: timeline.first { $0.name == "seek-output" }
        .map { $0.monotonicSeconds * 1_000 } ?? 0
    ),
    eof: eof,
    timeline: timeline,
    limitations: [
      "mpv uses null AO/VO in headless semantic mode",
      "mpv JSON IPC exposes playback time, not first decoded frame or first audio sample PTS",
    ]
  )
  let log = (try? Data(contentsOf: mpvLog)) ?? Data()
  return MPVRunOutput(result: result, log: log, ipcLog: rawIPC, options: options)
}

private func parseMPVTracks(_ tracks: [[String: Any]]) -> [DifferentialSelectedStream] {
  tracks.compactMap { track in
    guard track["selected"] as? Bool == true,
      let type = track["type"] as? String,
      let index = track["ff-index"] as? Int,
      let codec = track["codec"] as? String
    else { return nil }
    let kind: DifferentialStreamKind
    switch type {
    case "video": kind = .video
    case "audio": kind = .audio
    case "sub": kind = .subtitle
    default: return nil
    }
    var dispositions: [String] = []
    if track["default"] as? Bool == true { dispositions.append("default") }
    if track["forced"] as? Bool == true { dispositions.append("forced") }
    return DifferentialSelectedStream(
      kind: kind,
      index: Int32(index),
      codec: codec,
      language: track["lang"] as? String
        ?? (track["metadata"] as? [String: Any])?["language"] as? String,
      dispositions: dispositions,
      stableID: "\(kind.rawValue):\(index)",
      selectionReason: "mpv selected track"
    )
  }
}

private func runProcess(executable: URL, arguments: [String]) throws -> ProcessOutput {
  let captureDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("illiquid-process-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: captureDirectory) }
  let stdoutURL = captureDirectory.appendingPathComponent("stdout")
  let stderrURL = captureDirectory.appendingPathComponent("stderr")
  FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
  FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
  let stdout = try FileHandle(forWritingTo: stdoutURL)
  let stderr = try FileHandle(forWritingTo: stderrURL)
  defer {
    try? stdout.close()
    try? stderr.close()
  }
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()
  try stdout.close()
  try stderr.close()
  return ProcessOutput(
    status: process.terminationStatus,
    stdout: try Data(contentsOf: stdoutURL),
    stderr: try Data(contentsOf: stderrURL)
  )
}

private func commandText(_ path: String, _ arguments: [String]) throws -> String {
  let output = try runProcess(executable: URL(fileURLWithPath: path), arguments: arguments)
  guard output.status == 0 else {
    throw DifferentialHarnessError.externalProcessFailed(output.stderrString)
  }
  return output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func systemRecord() -> [String: String] {
  let process = ProcessInfo.processInfo
  return [
    "operating-system": process.operatingSystemVersionString,
    "processor-count": String(process.processorCount),
    "physical-memory-bytes": String(process.physicalMemory),
    "mac-model": (try? commandText("/usr/sbin/sysctl", ["-n", "hw.model"])) ?? "unavailable",
    "cpu": (try? commandText("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]))
      ?? "unavailable",
    "sdk": (try? commandText("/usr/bin/xcrun", ["--show-sdk-version"])) ?? "unavailable",
  ]
}

private func relevantEnvironment() -> [String: String] {
  let names = [
    "FFMPEG_BIN", "FFPROBE_BIN", "MPV_BIN", "ILLIQUID_NATIVE_FIXTURE_DIR",
    "ILLIQUID_NATIVE_REQUIRE_FIXTURES",
  ]
  return Dictionary(
    uniqueKeysWithValues: names.compactMap { name in
      ProcessInfo.processInfo.environment[name].map { (name, $0) }
    })
}

private func dynamicMediaClosure(
  binaries: [URL],
  configuration: String
) throws -> [DifferentialComponentIdentity] {
  var paths: Set<String> = []
  for binary in binaries {
    let output = try commandText("/usr/bin/otool", ["-L", binary.path])
    for line in output.components(separatedBy: "\n").dropFirst() {
      guard
        let path = line.trimmingCharacters(in: .whitespaces)
          .components(separatedBy: .whitespaces).first,
        path.hasPrefix("/")
      else { continue }
      if path.contains("/ffmpeg/") || path.contains("/libass/")
        || path.contains("/libplacebo/")
      {
        paths.insert(path)
      }
    }
  }
  return paths.sorted().map { path in
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let components = url.pathComponents
    let version =
      components.firstIndex(of: "Cellar").flatMap { index -> String? in
        let versionIndex = index + 2
        return components.indices.contains(versionIndex) ? components[versionIndex] : nil
      } ?? "unknown"
    return DifferentialComponentIdentity(
      name: url.lastPathComponent,
      revision: nil,
      binaryPath: url.path,
      sha256: SHA256Digest.file(at: url),
      version: version,
      configuration: configuration
    )
  }
}

private func value(
  after option: String,
  in arguments: [String],
  required: Bool = true
) throws -> String? {
  guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1)
  else {
    if required {
      throw DifferentialHarnessError.malformedArtifactInput("missing \(option)")
    }
    return nil
  }
  return arguments[index + 1]
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
  guard let value else { throw DifferentialHarnessError.malformedArtifactInput(message) }
  return value
}
