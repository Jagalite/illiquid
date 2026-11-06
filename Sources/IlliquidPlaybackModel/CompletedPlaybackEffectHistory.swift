/// Exact completed-effect membership with a compact consecutive prefix.
/// IDs are allocated starting at one. Later completions remain in a Set until
/// every earlier ID completes; no allocator or age-based inference is used.
/// The public Set-valued view preserves source and Codable compatibility while
/// the reducer's internal operations avoid expanding the completed prefix.
@propertyWrapper
public struct CompletedPlaybackEffectHistory: Codable, Equatable, Sendable {
  private var prefixThrough: UInt64 = 0
  private var sparse: Set<PlaybackEffectID> = []

  public var wrappedValue: Set<PlaybackEffectID> {
    get {
      var result = sparse
      if prefixThrough > 0 {
        for value in UInt64(1)...prefixThrough {
          result.insert(PlaybackEffectID(rawValue: value))
        }
      }
      return result
    }
    set { self = Self(wrappedValue: newValue) }
  }

  public init(wrappedValue: Set<PlaybackEffectID>) {
    sparse = wrappedValue
    advancePrefix()
  }

  public init(from decoder: any Decoder) throws {
    self.init(wrappedValue: try Set<PlaybackEffectID>(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.unkeyedContainer()
    try forEachSortedID { try container.encode($0) }
  }

  var prefixCount: UInt64 { prefixThrough }
  var sparseCount: Int { sparse.count }
  var sparseCapacity: Int { sparse.capacity }

  var sortedIDs: [PlaybackEffectID] {
    var result: [PlaybackEffectID] = []
    forEachSortedID { result.append($0) }
    return result
  }

  func contains(_ id: PlaybackEffectID) -> Bool {
    (id.rawValue > 0 && id.rawValue <= prefixThrough) || sparse.contains(id)
  }

  mutating func insert(_ id: PlaybackEffectID) {
    guard id.rawValue == 0 || id.rawValue > prefixThrough else { return }
    if prefixThrough < UInt64.max, id.rawValue == prefixThrough + 1 {
      prefixThrough = id.rawValue
      advancePrefix()
    } else {
      sparse.insert(id)
    }
  }

  private mutating func advancePrefix() {
    let previousCount = sparse.count
    while prefixThrough < UInt64.max, !sparse.isEmpty,
      sparse.remove(PlaybackEffectID(rawValue: prefixThrough + 1)) != nil
    {
      prefixThrough += 1
    }
    guard sparse.count < previousCount else { return }
    if sparse.isEmpty {
      // Set.remove retains its allocation, even after the last gap closes.
      sparse = []
      return
    }
    if sparse.capacity > 16, sparse.count <= sparse.capacity / 4 {
      // Trim geometrically, preserving snapshot value semantics. Set(sparse)
      // could share the old storage, so explicitly build a smaller allocation.
      var compact: Set<PlaybackEffectID> = []
      compact.reserveCapacity(sparse.count)
      for id in sparse { compact.insert(id) }
      sparse = compact
    }
  }

  private func forEachSortedID(_ body: (PlaybackEffectID) throws -> Void) rethrows {
    let zero = PlaybackEffectID(rawValue: 0)
    if sparse.contains(zero) { try body(zero) }
    if prefixThrough > 0 {
      for value in UInt64(1)...prefixThrough {
        try body(PlaybackEffectID(rawValue: value))
      }
    }
    for id in sparse.sorted() where id.rawValue > 0 {
      try body(id)
    }
  }
}
