import Darwin
import Foundation
import IlliquidPlaybackCore
import IlliquidPlayer

@main
struct IlliquidArchitectureCheck {
  @MainActor
  static func main() {
    let failures = ArchitectureValidation.run()
      + playbackCoreBoundaryFailures()
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

  private static func playbackCoreBoundaryFailures() -> [String] {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sourceRoot = root.appendingPathComponent("Sources/IlliquidPlaybackCore")
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: nil
      )
    else {
      return ["playback core source directory is unavailable"]
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
        failures.append("playback core source unreadable: \(fileURL.lastPathComponent)")
        continue
      }
      for module in forbiddenImports where source.contains("import \(module)") {
        failures.append(
          "playback core imports forbidden module \(module): \(fileURL.lastPathComponent)"
        )
      }
      if source.contains("import Foundation"), fileURL.lastPathComponent != "PlaybackReplay.swift" {
        failures.append(
          "Foundation is restricted to replay serialization: \(fileURL.lastPathComponent)"
        )
      }
      for api in forbiddenAPIs where source.contains(api) {
        failures.append(
          "playback core uses forbidden runtime API \(api): \(fileURL.lastPathComponent)"
        )
      }
    }
    return failures.sorted()
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
