public enum SynchronizedStream: String, Codable, Hashable, Sendable {
  case video
  case audio
}

public enum SynchronizationCoreEvent: Codable, Equatable, Sendable {
  case require(Set<SynchronizedStream>)
  case prerolled(SynchronizedStream)
  case rateAcknowledged(milliRate: Int32)
  case supplyObserved(starved: Bool, cacheMicroseconds: UInt64)
  case clockObserved(MediaTimestamp)
  case presentationObserved(video: MediaTimestamp, audio: MediaTimestamp)
  case formatChanged(stream: SynchronizedStream, revision: MediaFormatRevisionID)
}

public enum SynchronizationDirective: Codable, Equatable, Sendable {
  case applyRate(milliRate: Int32)
  case correctAudioVideoDrift(microseconds: Int64)
  case reconfigureFormat(stream: SynchronizedStream, revision: MediaFormatRevisionID)
}

public struct SynchronizationMachineState: Codable, Equatable, Sendable {
  public var required: Set<SynchronizedStream>
  public var prerolled: Set<SynchronizedStream>
  public var desiredMilliRate: Int32
  public var appliedMilliRate: Int32
  public var startupAcknowledged: Bool
  public var isBuffering: Bool
  public var cacheMicroseconds: UInt64
  public var clock: MediaTimestamp
  public var videoPresentation: MediaTimestamp
  public var audioPresentation: MediaTimestamp
  public var videoFormatRevision: MediaFormatRevisionID?
  public var audioFormatRevision: MediaFormatRevisionID?

  public init(
    required: Set<SynchronizedStream> = [],
    prerolled: Set<SynchronizedStream> = [],
    desiredMilliRate: Int32 = 0,
    appliedMilliRate: Int32 = 0,
    startupAcknowledged: Bool = false,
    isBuffering: Bool = false,
    cacheMicroseconds: UInt64 = 0,
    clock: MediaTimestamp = .unknown,
    videoPresentation: MediaTimestamp = .unknown,
    audioPresentation: MediaTimestamp = .unknown,
    videoFormatRevision: MediaFormatRevisionID? = nil,
    audioFormatRevision: MediaFormatRevisionID? = nil
  ) {
    self.required = required
    self.prerolled = prerolled
    self.desiredMilliRate = desiredMilliRate
    self.appliedMilliRate = appliedMilliRate
    self.startupAcknowledged = startupAcknowledged
    self.isBuffering = isBuffering
    self.cacheMicroseconds = cacheMicroseconds
    self.clock = clock
    self.videoPresentation = videoPresentation
    self.audioPresentation = audioPresentation
    self.videoFormatRevision = videoFormatRevision
    self.audioFormatRevision = audioFormatRevision
  }

  public mutating func observe(
    _ event: SynchronizationCoreEvent,
    driftBoundMicroseconds: Int64 = 100_000
  ) -> [SynchronizationDirective] {
    switch event {
    case .require(let streams):
      required = streams
      prerolled.formIntersection(streams)
      startupAcknowledged = false
      return []
    case .prerolled(let stream):
      guard required.contains(stream) else { return [] }
      prerolled.insert(stream)
      return []
    case .rateAcknowledged(let rate):
      appliedMilliRate = rate
      return []
    case .supplyObserved(let starved, let cache):
      cacheMicroseconds = cache
      guard desiredMilliRate != 0 else {
        isBuffering = false
        return []
      }
      if starved, !isBuffering {
        isBuffering = true
        return [.applyRate(milliRate: 0)]
      }
      if !starved, isBuffering {
        isBuffering = false
        return [.applyRate(milliRate: desiredMilliRate)]
      }
      return []
    case .clockObserved(let value):
      clock = value
      return []
    case .presentationObserved(let video, let audio):
      videoPresentation = video
      audioPresentation = audio
      guard let videoMicros = mediaTimestampMicroseconds(video),
        let audioMicros = mediaTimestampMicroseconds(audio)
      else { return [] }
      let difference = audioMicros - videoMicros
      return abs(difference) > driftBoundMicroseconds
        ? [.correctAudioVideoDrift(microseconds: difference)]
        : []
    case .formatChanged(let stream, let revision):
      switch stream {
      case .video: videoFormatRevision = revision
      case .audio: audioFormatRevision = revision
      }
      return [.reconfigureFormat(stream: stream, revision: revision)]
    }
  }

  public mutating func beginStartupObligation() {
    prerolled.removeAll()
    startupAcknowledged = false
  }

  public mutating func updateRequirementsAfterStartup(_ streams: Set<SynchronizedStream>) {
    required = streams
    prerolled.formIntersection(streams)
    prerolled.formUnion(streams)
  }

  @discardableResult
  public mutating func satisfyStartupObligation() -> Bool {
    guard !startupAcknowledged else { return false }
    prerolled.formUnion(required)
    startupAcknowledged = true
    return true
  }
}

public enum LifecycleCoreEvent: String, Codable, Equatable, Sendable {
  case systemWillSleep
  case systemDidWake
}

public enum LifecycleDirective: Codable, Equatable, Sendable {
  case applyRate(milliRate: Int32)
  case resumeAfterWake(position: MediaTimestamp, milliRate: Int32)
}

public struct LifecycleMachineState: Codable, Equatable, Sendable {
  public var resumeAfterWake: Bool

  public init(resumeAfterWake: Bool = false) {
    self.resumeAfterWake = resumeAfterWake
  }

  public mutating func observe(
    _ event: LifecycleCoreEvent,
    desiredMilliRate: Int32,
    position: MediaTimestamp
  ) -> LifecycleDirective {
    switch event {
    case .systemWillSleep:
      resumeAfterWake = desiredMilliRate != 0
      return .applyRate(milliRate: 0)
    case .systemDidWake:
      let rate = resumeAfterWake ? desiredMilliRate : 0
      resumeAfterWake = false
      return .resumeAfterWake(position: position, milliRate: rate)
    }
  }
}

private func mediaTimestampMicroseconds(_ timestamp: MediaTimestamp) -> Int64? {
  guard case .valid(let value) = timestamp else { return nil }
  let scaled = Double(value.value) * 1_000_000 / Double(value.timescale)
  guard scaled.isFinite, scaled <= Double(Int64.max), scaled >= Double(Int64.min) else {
    return nil
  }
  return Int64(scaled.rounded())
}
