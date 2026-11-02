import Darwin
import Foundation
import IlliquidPlayer

@main
struct IlliquidArchitectureCheck {
  @MainActor
  static func main() {
    let failures = ArchitectureValidation.run()
      + playbackModelBoundaryFailures()
      + legacyPlaybackEngineFailures()
      + nativeOnlyProductionFailures()
    if failures.isEmpty {
      print("Illiquid architecture checks passed")
      return
    }

    for failure in failures {
      print("FAIL: \(failure)")
    }
    exit(1)
  }

  /// The production model is deterministic value code consumed by
  /// Statelessness: no media frameworks, clocks, threads or UI.
  private static func playbackModelBoundaryFailures() -> [String] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sourceRoot = root.appendingPathComponent("Sources/IlliquidPlaybackModel")
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: nil
      )
    else {
      return ["playback model source directory is unavailable"]
    }

    let forbiddenImports = [
      "AppKit", "SwiftUI", "AVFoundation", "AVKit", "VideoToolbox",
      "AudioToolbox", "CoreMedia", "CoreVideo", "QuartzCore", "OpenGL",
      "CFFmpeg", "CLibass", "CNativeAudio", "CMpv", "Observation", "Dispatch",
    ]
    let forbiddenAPIs = [
      "DispatchQueue", "Task {", "Task.detached", "@MainActor", "Timer(",
      "ContinuousClock", "SuspendingClock", "Date()", "UUID()", "NSLock(",
      "CACurrentMediaTime", "CFAbsoluteTimeGetCurrent", "Thread.sleep",
    ]
    var failures: [String] = []

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
      guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
        failures.append("playback model source unreadable: \(fileURL.lastPathComponent)")
        continue
      }
      for module in forbiddenImports where source.contains("import \(module)") {
        failures.append(
          "playback model imports forbidden module \(module): \(fileURL.lastPathComponent)"
        )
      }
      let serialization = ["PlaybackReplay.swift", "CanonicalJSON.swift", "PlaybackProductionCodec.swift"]
      if source.contains("import Foundation"), !serialization.contains(fileURL.lastPathComponent) {
        failures.append(
          "Foundation is restricted to model serialization: \(fileURL.lastPathComponent)"
        )
      }
      for api in forbiddenAPIs where source.contains(api) {
        failures.append(
          "playback model uses forbidden runtime API \(api): \(fileURL.lastPathComponent)"
        )
      }
    }
    return failures.sorted()
  }

  /// Statelessness owns production execution. The legacy engine, its runtime
  /// wrapper and its module must not return to active sources or the package.
  private static func legacyPlaybackEngineFailures() -> [String] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var failures: [String] = []
    let legacySymbols = ["PlaybackModelRuntime", "IlliquidPlaybackCore", "PlaybackCore(", "PlaybackCore.update", ": PlaybackCore", "struct PlaybackCore"]
    if let package = try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8),
      package.contains("IlliquidPlaybackCore")
    {
      failures.append("package retains the legacy playback core target")
    }
    for directory in ["Sources", "Tests", "Validation"] {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
      else { continue }
      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        if fileURL.lastPathComponent == "main.swift", fileURL.path.contains("IlliquidArchitectureCheck") {
          continue
        }
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
        for symbol in legacySymbols where source.contains(symbol) {
          failures.append("legacy playback engine symbol \(symbol): \(fileURL.path.replacingOccurrences(of: root.path + "/", with: ""))")
        }
      }
    }
    failures += executionOwnershipFailures(root: root)
    return failures.sorted()
  }

  /// Source lines without `//` comments, for structural checks.
  private static func code(_ url: URL) -> String? {
    guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
      .joined(separator: "\n")
  }

  private static func swiftFiles(_ directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  /// A stored (not computed) property holding the playback domain state.
  private static func storesDomainState(_ source: String) -> Bool {
    source.split(separator: "\n").contains { line in
      let text = line.trimmingCharacters(in: .whitespaces)
      // Any annotated declaration, including one written inline after a
      // type's opening brace; a trailing `{` marks a computed property.
      guard text.range(of: #"\b(var|let) [A-Za-z_]+: PlaybackDomainState\b"#, options: .regularExpression) != nil
      else { return false }
      return !text.hasSuffix("{")
    }
  }

  /// Statelessness owns execution and committed state: live targets reach the
  /// model only through `PlaybackSessionHost`, which submits to a session; no
  /// live or model type keeps its own copy of the domain state.
  private static func executionOwnershipFailures(root: URL) -> [String] {
    var failures: [String] = []
    let modelRoot = root.appendingPathComponent("Sources/IlliquidPlaybackModel")
    guard let model = code(modelRoot.appendingPathComponent("PlaybackProductionModel.swift")) else {
      return ["production model source PlaybackProductionModel.swift is missing or unreadable"]
    }
    for required in ["import Statelessness", "-> Transition<PlaybackDomainState, PlaybackTransition>", "Model("] {
      if !model.contains(required) {
        failures.append("production model is not a Statelessness model (missing \(required))")
      }
    }
    guard let host = code(modelRoot.appendingPathComponent("PlaybackSessionHost.swift")) else {
      return failures + ["PlaybackSessionHost.swift is missing or unreadable"]
    }
    for required in ["PlaybackProductionModel.session(", "session.submit(", "session.snapshot()"] {
      if !host.contains(required) { failures.append("PlaybackSessionHost does not execute through its session (missing \(required))") }
    }
    for forbidden in ["PlaybackProductionModel.step(", ".turn(", "PlaybackRules"] where host.contains(forbidden) {
      failures.append("PlaybackSessionHost bypasses the session: \(forbidden)")
    }
    for file in swiftFiles(modelRoot) {
      if let source = code(file), storesDomainState(source) {
        failures.append("model type stores its own playback state: \(file.lastPathComponent)")
      }
    }
    let liveTargets = ["IlliquidPlayer", "IlliquidPlayback", "IlliquidNativePlayback", "IlliquidApp"]
    let bypasses = ["PlaybackProductionModel.step(", "PlaybackProductionModel.make(", "PlaybackProductionModel.turn(",
                    "PlaybackProductionModel.session(", "ExecutionSession("]
    for target in liveTargets {
      for file in swiftFiles(root.appendingPathComponent("Sources/\(target)")) {
        guard let source = code(file) else { continue }
        let name = "\(target)/\(file.lastPathComponent)"
        for bypass in bypasses where source.contains(bypass) {
          failures.append("live target bypasses PlaybackSessionHost (\(bypass)): \(name)")
        }
        if storesDomainState(source) { failures.append("live target stores its own playback state: \(name)") }
      }
    }
    if let driver = code(root.appendingPathComponent("Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift")),
      !driver.contains("PlaybackSessionHost")
    {
      failures.append("the live driver does not submit through PlaybackSessionHost")
    }
    return failures
  }

  private static func nativeOnlyProductionFailures() -> [String] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let packageURL = root.appendingPathComponent("Package.swift")
    guard let package = try? String(contentsOf: packageURL, encoding: .utf8) else {
      return ["Package.swift is unreadable"]
    }
    var failures: [String] = []
    let removedPackageSymbols = [
      "CMpv", "LegacyMpv", "MpvEngine", ".linkedFramework(\"OpenGL\")",
      "PlayerBackendSelector", "IlliquidNativePlaybackPOC",
    ]
    for symbol in removedPackageSymbols where package.contains(symbol) {
      failures.append("package retains removed playback symbol: \(symbol)")
    }

    let sourceRoot = root.appendingPathComponent("Sources")
    if let enumerator = FileManager.default.enumerator(
      at: sourceRoot,
      includingPropertiesForKeys: nil
    ) {
      let removedSourceSymbols = [
        "import CMpv", "LegacyMpvBackend", "MpvRenderContext",
        "PlayerBackendSelector", "PlaybackShadowEventLoop",
        "IlliquidNativePlaybackPOC", "Timer.scheduledTimer",
        "observationTimer", "NativeLifecycleController",
      ]
      for case let file as URL in enumerator where file.pathExtension == "swift" {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for symbol in removedSourceSymbols where source.contains(symbol) {
          failures.append("\(file.lastPathComponent) retains removed orchestration: \(symbol)")
        }
      }
    }

    let coordinatorURL = sourceRoot
      .appendingPathComponent("IlliquidPlayer/Player/PlaybackController.swift")
    let coordinator = (try? String(contentsOf: coordinatorURL, encoding: .utf8)) ?? ""
    if !coordinator.contains("PlaybackRuntimeDriver") {
      failures.append("production coordinator bypasses the deterministic runtime driver")
    }
    if !coordinator.contains("driver.onTransition") ||
      !coordinator.contains("applyCoreTransition")
    {
      failures.append("product phase is not projected from deterministic core snapshots")
    }
    let appRoot = sourceRoot.appendingPathComponent("IlliquidApp")
    if let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) {
      for case let file as URL in enumerator where file.pathExtension == "swift" {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        if source.contains("player.state") {
          failures.append("\(file.lastPathComponent) bypasses immutable PlaybackViewStore")
        }
      }
    }
    return failures.sorted()
  }
}
