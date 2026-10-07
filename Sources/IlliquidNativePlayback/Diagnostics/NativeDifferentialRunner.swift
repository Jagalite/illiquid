import CFFmpeg
import CLibass
import CoreMedia
import Foundation

public struct NativeDifferentialRunOutput: Sendable {
  public let result: DifferentialPlayerResult
  public let log: String

  public init(result: DifferentialPlayerResult, log: String) {
    self.result = result
    self.log = log
  }
}

public enum NativeDifferentialRunner {
  public static var ffmpegRuntimeConfiguration: String {
    avcodec_configuration().map(String.init(cString:)) ?? "unavailable"
  }

  public static var ffmpegRuntimeVersion: String {
    let value = avcodec_version()
    return "\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
  }

  public static var libassRuntimeVersion: String {
    String(format: "0x%08x", ass_library_version())
  }

  public static func runHeadlessSemanticSmoke(
    fixtureURL: URL,
    seekTarget: Double
  ) throws -> NativeDifferentialRunOutput {
    let started = ProcessInfo.processInfo.systemUptime
    func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }

    let demuxer = try FFmpegDemuxer(url: fixtureURL)
    let info = demuxer.mediaInfo
    let videoStream = info.videoStreams.first { $0.index == info.selectedVideoIndex }
    let audioStream = info.audioStreams.first { $0.index == info.selectedAudioIndex }
    guard videoStream != nil || audioStream != nil else {
      throw DifferentialHarnessError.failedFixtureAssertion("playable-audio-or-video")
    }

    var videoDecoder = try videoStream.flatMap { stream -> VideoDecoder? in
      guard let parameters = demuxer.codecParameters(streamIndex: stream.index) else {
        return nil
      }
      return try VideoDecoder(
        parameters: parameters,
        stream: stream,
        preferHardware: true,
        timelineOriginSeconds: info.startTime
      )
    }
    let audioDecoder = try audioStream.flatMap { stream -> AudioDecoder? in
      guard let parameters = demuxer.codecParameters(streamIndex: stream.index) else {
        return nil
      }
      return try AudioDecoder(
        parameters: parameters,
        stream: stream,
        timelineOriginSeconds: info.startTime
      )
    }
    let hardwareWasConfigured = videoDecoder?.hardwareWasConfigured ?? false

    var timeline = [
      DifferentialTimelineEvent(
        name: "open",
        monotonicSeconds: elapsed(),
        detail: info.containerName
      ),
      DifferentialTimelineEvent(name: "pause", monotonicSeconds: elapsed()),
    ]
    var log = [
      "opened=\(fixtureURL.path)",
      "container=\(info.containerName)",
      "start-time=\(info.startTime)",
      "duration=\(info.durationStatus)",
    ]
    var firstDecoded: [DifferentialStreamKind: Double] = [:]
    var videoFailure: String?
    var actualVideoFrameFormat: String?
    var actualHardwareOutput: Bool?

    var initialPackets = 0
    while initialPackets < 2_000,
      (videoDecoder != nil && firstDecoded[.video] == nil)
        || (audioStream != nil && firstDecoded[.audio] == nil)
    {
      guard let packet = try demuxer.readPacket(generation: 1) else { break }
      initialPackets += 1
      if packet.streamIndex == videoStream?.index, let decoder = videoDecoder {
        do {
          if let frame = try decoder.decode(packet).first,
            firstDecoded[.video] == nil
          {
            actualVideoFrameFormat = frame.ffmpegPixelFormat
            actualHardwareOutput = frame.isHardwareDecoded
            firstDecoded[.video] = frame.presentationTime.seconds
            timeline.append(
              .init(
                name: "first-decoded-video",
                monotonicSeconds: elapsed(),
                mediaTime: frame.presentationTime.seconds
              ))
          }
        } catch {
          videoFailure = String(describing: error)
          videoDecoder = nil
          log.append("video-decode-environment-failure=\(error)")
          timeline.append(
            .init(
              name: "video-decode-failure",
              monotonicSeconds: elapsed(),
              detail: String(describing: error)
            ))
        }
      }
      if packet.streamIndex == audioStream?.index,
        let frame = try audioDecoder?.decode(packet).first,
        firstDecoded[.audio] == nil
      {
        firstDecoded[.audio] = frame.presentationTime.seconds
        timeline.append(
          .init(
            name: "first-decoded-audio",
            monotonicSeconds: elapsed(),
            mediaTime: frame.presentationTime.seconds
          ))
      }
    }

    let seekStarted = elapsed()
    var seekSupported = true
    do {
      try demuxer.seek(to: seekTarget + info.startTime, exact: true)
      videoDecoder?.flush()
      audioDecoder?.flush()
      timeline.append(
        .init(
          name: "seek-exact",
          monotonicSeconds: elapsed(),
          mediaTime: seekTarget
        ))
    } catch {
      seekSupported = false
      log.append("seek-capability=unsupported:\(error)")
      timeline.append(
        .init(
          name: "seek-unsupported",
          monotonicSeconds: elapsed(),
          mediaTime: seekTarget,
          detail: String(describing: error)
        ))
    }

    var landedVideo: Double?
    var landedAudio: Double?
    var eof: DifferentialEOFOutcome = .clean
    var demuxEOF: Double?
    var decoderEOF: Double?
    var exitCode: Int32 = videoFailure == nil ? 0 : 1
    let generation = seekSupported ? 2 : 1

    func observeVideo(_ frames: [NativeDecodedVideoFrame]) {
      if let frame = frames.first {
        actualVideoFrameFormat = frame.ffmpegPixelFormat
        actualHardwareOutput = frame.isHardwareDecoded
      }
      if landedVideo == nil,
        let frame = frames.first(where: {
          $0.presentationTime.seconds + 0.001 >= seekTarget
        })
      {
        landedVideo = frame.presentationTime.seconds
        timeline.append(
          .init(
            name: "seek-video-eligible",
            monotonicSeconds: elapsed(),
            mediaTime: frame.presentationTime.seconds
          ))
      }
    }
    func observeAudio(_ frames: [NativeDecodedAudioFrame]) {
      guard landedAudio == nil else { return }
      for frame in frames {
        if let accepted = frame.trimmingSamples(before: seekTarget) {
          landedAudio = accepted.presentationTime.seconds
          timeline.append(
            .init(
              name: "seek-audio-eligible",
              monotonicSeconds: elapsed(),
              mediaTime: accepted.presentationTime.seconds
            ))
          return
        }
      }
    }

    timeline.append(.init(name: "resume", monotonicSeconds: elapsed()))
    do {
      while let packet = try demuxer.readPacket(generation: generation) {
        if packet.streamIndex == videoStream?.index, let decoder = videoDecoder {
          do {
            observeVideo(try decoder.decode(packet))
          } catch {
            videoFailure = String(describing: error)
            videoDecoder = nil
            exitCode = 1
            log.append("video-decode-environment-failure=\(error)")
            timeline.append(
              .init(
                name: "video-decode-failure",
                monotonicSeconds: elapsed(),
                detail: String(describing: error)
              ))
          }
        } else if packet.streamIndex == audioStream?.index {
          observeAudio(try audioDecoder?.decode(packet) ?? [])
        }
      }
      demuxEOF = elapsed()
      if let decoder = videoDecoder {
        do {
          observeVideo(try decoder.drain(generation: generation))
        } catch {
          videoFailure = String(describing: error)
          exitCode = 1
          log.append("video-drain-environment-failure=\(error)")
        }
      }
      observeAudio(try audioDecoder?.drain(generation: generation) ?? [])
      decoderEOF = elapsed()
      timeline.append(.init(name: "decoder-drain", monotonicSeconds: elapsed()))
      timeline.append(.init(name: "eof", monotonicSeconds: elapsed(), detail: "clean"))
    } catch {
      eof = .readFailure
      exitCode = 1
      log.append("read-failure=\(error)")
      timeline.append(
        .init(
          name: "eof",
          monotonicSeconds: elapsed(),
          detail: "read-failure"
        ))
    }
    let seek = DifferentialSeekResult(
      mode: .exact,
      requestedTarget: seekTarget,
      lowLevelTarget: seekSupported ? seekTarget + info.startTime : nil,
      actualVideoPTS: landedVideo,
      firstAudioSamplePTS: landedAudio,
      completionReason: seekSupported
        ? (landedVideo != nil || landedAudio != nil
          ? "eligible-output-decoded"
          : "no-eligible-output")
        : "unsupported-by-input",
      latencyMilliseconds: (elapsed() - seekStarted) * 1_000
    )
    let result = DifferentialPlayerResult(
      runner: .illiquid,
      mode: .headlessSemantic,
      processExitCode: exitCode,
      opened: true,
      selectedStreams: selectedStreams(info: info),
      firstDecoded: firstDecoded,
      firstEnqueued: [:],
      readiness: readiness(video: videoStream != nil, audio: audioStream != nil),
      seek: seek,
      eof: eof,
      timeline: timeline,
      limitations: [
        "Headless semantic mode decodes but does not enqueue to Apple renderers",
        "Visible and audible presentation readiness is unmeasured",
      ]
        + (videoFailure.map {
          ["Video decode was unmeasured after an environment failure: \($0)"]
        } ?? []),
      hardwareDecoder: .init(
        requested: videoStream != nil,
        configured: hardwareWasConfigured,
        actualFrameFormat: actualVideoFrameFormat,
        actualHardwareOutput: actualHardwareOutput,
        fallbackOrRecreationReason: videoFailure
      ),
      eofTiming: .init(
        demuxEOF: demuxEOF,
        decoderEOF: decoderEOF,
        resamplerEOF: audioStream == nil ? nil : decoderEOF,
        outcome: eof,
        limitation: "Headless mode has no enqueue, renderer drain, or product EOF observation"
      ),
      memory: .init(
        residentBytes: ProcessResidentMemory.bytes(),
        limitation: "Single-process snapshot; replacement slope requires the stress gate"
      ),
      recovery: videoFailure.map { failure in
        .init(
          errorDomain: "video-decode-environment",
          stableCode: "nativeVideoDecodeEnvironmentFailure",
          retryCount: 0,
          action: "retain audio semantic evidence and mark video unmeasured: \(failure)",
          finalState: "headless-run-completed-with-limitation"
        )
      }
    )
    log.append("seek-video=\(landedVideo.map { String($0) } ?? "unmeasured")")
    log.append("seek-audio=\(landedAudio.map { String($0) } ?? "unmeasured")")
    log.append("eof=\(eof.rawValue)")
    return NativeDifferentialRunOutput(result: result, log: log.joined(separator: "\n") + "\n")
  }

  /// Runs the actual Apple sample-buffer presentation graph. This entry point
  /// is intentionally separate from headless semantic mode because some CI or
  /// virtualized hosts cannot construct valid renderers. Callers should run it
  /// in a subprocess and retain a crash/exception as environmental evidence.
  @MainActor public static func runRendererBackedSmoke(
    fixtureURL: URL,
    seekTarget: Double,
    timeoutSeconds: Double = 15
  ) throws -> NativeDifferentialRunOutput {
    let started = ProcessInfo.processInfo.systemUptime
    func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }
    let presentation = try NativePresentationCoordinator()
    let subtitles = try SubtitlePipeline(overlay: SubtitleOverlayView())
    let session = try MediaSession(
      url: fixtureURL,
      presentation: presentation,
      subtitles: subtitles
    )
    defer {
      session.stop()
      _ = session.waitForShutdown(timeout: .now() + 3)
      subtitles.terminate()
      presentation.terminate()
    }

    session.start(rate: 1)
    Thread.sleep(forTimeInterval: 0.25)
    session.seek(to: seekTarget, exact: true, resumeRate: 1)
    var snapshot = session.snapshot()
    var observation = presentation.differentialRendererObservation(demuxEOF: snapshot.ended)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline,
      snapshot.rendererFailure == nil,
      !observation.isRendererDrained
    {
      Thread.sleep(forTimeInterval: 0.02)
      snapshot = session.snapshot()
      observation = presentation.differentialRendererObservation(demuxEOF: snapshot.ended)
    }

    let info = session.mediaInfo
    let hasVideo = info.selectedVideoIndex != nil
    let hasAudio = info.selectedAudioIndex != nil
    var firstEnqueued: [DifferentialStreamKind: Double] = [:]
    if let value = snapshot.firstEnqueuedVideoPTS { firstEnqueued[.video] = value }
    if let value = snapshot.firstEnqueuedAudioPTS { firstEnqueued[.audio] = value }
    var readiness: [DifferentialStreamKind: DifferentialReadiness] = [:]
    if hasVideo { readiness[.video] = observation.readiness(for: .video) }
    if hasAudio { readiness[.audio] = observation.readiness(for: .audio) }
    let seek = DifferentialSeekResult(
      mode: .exact,
      requestedTarget: seekTarget,
      lowLevelTarget: seekTarget + info.startTime,
      actualVideoPTS: snapshot.firstEnqueuedVideoPTS,
      firstAudioSamplePTS: snapshot.firstEnqueuedAudioPTS,
      completionReason: snapshot.isPrerolled ? "renderer-prerolled" : "renderer-not-prerolled",
      latencyMilliseconds: elapsed() * 1_000
    )
    let failure = snapshot.rendererFailure
    let result = DifferentialPlayerResult(
      runner: .illiquid,
      mode: .rendererBacked,
      processExitCode: failure == nil ? 0 : 1,
      opened: true,
      selectedStreams: selectedStreams(info: info),
      firstDecoded: [:],
      firstEnqueued: firstEnqueued,
      readiness: readiness,
      seek: seek,
      eof: observation.isRendererDrained ? .clean : .notReached,
      timeline: [
        .init(name: "renderer-open", monotonicSeconds: 0),
        .init(name: "renderer-seek", monotonicSeconds: 0.25, mediaTime: seekTarget),
        .init(
          name: observation.isRendererDrained ? "renderer-drained" : "renderer-unmeasured",
          monotonicSeconds: elapsed(),
          mediaTime: presentation.currentTime.seconds,
          detail: failure
        ),
      ],
      limitations: [
        "Audio readiness is renderer-clock evidence, not physical audibility",
        "Display composition and physical output still require the physical qualification matrix",
      ],
      hardwareDecoder: .init(
        requested: hasVideo,
        configured: snapshot.hardwareDecoder != "Not initialized",
        actualFrameFormat: snapshot.ffmpegPixelFormat == "Unknown"
          ? nil : snapshot.ffmpegPixelFormat,
        actualHardwareOutput: hasVideo ? snapshot.isHardwareDecoded : nil,
        fallbackOrRecreationReason: snapshot.lastRecoveryMessage
      ),
      eofTiming: .init(
        lastEnqueue: [snapshot.videoPTS, snapshot.audioPTS].filter { $0 > 0 }.max(),
        lastPresentationEnd: observation.isRendererDrained
          ? presentation.currentTime.seconds : nil,
        productEOF: observation.rendererEOFMonotonicSeconds,
        outcome: observation.isRendererDrained ? .clean : .notReached,
        limitation: observation.isRendererDrained
          ? nil : "Renderer clock did not cross the final accepted interval"
      ),
      memory: .init(
        residentBytes: ProcessResidentMemory.bytes(),
        limitation: "Per-run snapshot; replacement slope is recorded by stress qualification"
      ),
      recovery: failure.map { failure in
        .init(
          errorDomain: "presentation",
          stableCode: "nativeRendererFailure",
          retryCount: snapshot.hardwareFallbackCount,
          action: snapshot.lastRecoveryMessage ?? "terminal renderer failure: \(failure)",
          finalState: "failed"
        )
      }
    )
    let log = [
      "mode=renderer-backed",
      "fixture=\(fixtureURL.path)",
      "renderer-drained=\(observation.isRendererDrained)",
      "stale-observations=\(observation.staleObservationCount)",
      "renderer-failure=\(failure ?? "none")",
    ].joined(separator: "\n") + "\n"
    return NativeDifferentialRunOutput(result: result, log: log)
  }

  private static func selectedStreams(info: FFmpegMediaInfo) -> [DifferentialSelectedStream] {
    info.streams.compactMap { stream in
      let kind: DifferentialStreamKind
      switch stream.kind {
      case .video: kind = .video
      case .audio: kind = .audio
      case .subtitle: kind = .subtitle
      case .attachment, .other: return nil
      }
      let selected =
        switch kind {
        case .video: info.selectedVideoIndex == stream.index
        case .audio: info.selectedAudioIndex == stream.index
        case .subtitle: info.selectedSubtitleIndex == stream.index
        }
      guard selected else { return nil }
      var dispositions: [String] = []
      if stream.disposition & 1 != 0 { dispositions.append("default") }
      if stream.disposition & 64 != 0 { dispositions.append("forced") }
      return DifferentialSelectedStream(
        kind: kind,
        index: stream.index,
        codec: stream.codecName,
        language: stream.language,
        dispositions: dispositions,
        stableID: "\(kind.rawValue):\(stream.index)",
        selectionReason: "native demux default policy"
      )
    }
  }

  private static func readiness(
    video: Bool,
    audio: Bool
  ) -> [DifferentialStreamKind: DifferentialReadiness] {
    var values: [DifferentialStreamKind: DifferentialReadiness] = [:]
    if video { values[.video] = .unmeasured(reason: "headless semantic mode") }
    if audio { values[.audio] = .unmeasured(reason: "headless semantic mode") }
    return values
  }
}
