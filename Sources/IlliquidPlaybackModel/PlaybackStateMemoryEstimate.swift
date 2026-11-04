/// An approximate logical retained-size estimate for a playback model state.
///
/// Includes inline state, collection capacity and string UTF-8 payloads. This
/// deliberately does not claim allocator, framework, decoder or process memory.
/// Shared copy-on-write storage may be counted more than once; small strings
/// may be counted even when inline. Collection metadata and hash tables are
/// not measured. Overflow makes the estimate unknown.
enum PlaybackStateMemoryEstimate {
  fileprivate protocol CollectionStorage {
    var estimatedSlots: UInt64? { get }
  }

  fileprivate static func multiply(_ a: Int, _ b: Int) -> UInt64? {
    let (value, overflow) = UInt64(a).multipliedReportingOverflow(by: UInt64(b))
    return overflow ? nil : value
  }

  static func estimate(_ state: PlaybackDomainState) -> UInt64? {
    var bytes = UInt64(MemoryLayout<PlaybackDomainState>.stride)
    func add(_ amount: UInt64) -> Bool {
      let (sum, overflow) = bytes.addingReportingOverflow(amount)
      if overflow { return false }
      bytes = sum
      return true
    }
    func visit(_ value: Any) -> Bool {
      if let string = value as? String { return add(UInt64(string.utf8.count)) }
      if let storage = value as? any CollectionStorage {
        guard let slots = storage.estimatedSlots, add(slots) else { return false }
      }
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .class {
        guard value is PendingPlaybackSession,
          add(UInt64(MemoryLayout<ActivePlaybackSession>.stride)) else { return false }
      }
      for child in mirror.children where !visit(child.value) { return false }
      return true
    }
    return visit(state) ? bytes : nil
  }
}

extension Array: PlaybackStateMemoryEstimate.CollectionStorage {
  fileprivate var estimatedSlots: UInt64? {
    PlaybackStateMemoryEstimate.multiply(capacity, MemoryLayout<Element>.stride)
  }
}

extension Set: PlaybackStateMemoryEstimate.CollectionStorage {
  fileprivate var estimatedSlots: UInt64? {
    PlaybackStateMemoryEstimate.multiply(capacity, MemoryLayout<Element>.stride)
  }
}

extension Dictionary: PlaybackStateMemoryEstimate.CollectionStorage {
  fileprivate var estimatedSlots: UInt64? {
    PlaybackStateMemoryEstimate.multiply(capacity, MemoryLayout<Element>.stride)
  }
}
