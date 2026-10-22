import CoreMedia

/// Avoids asking the presentation queue to reapply an unchanged clock interval.
/// Keep one instance with one presentation coordinator: seeks, source changes,
/// and renderer recovery retain that coordinator's synchronizer and interval.
@MainActor
struct PresentationObservationCadence {
    private var lastAppliedInterval: CMTime?

    mutating func update(_ interval: CMTime, apply: (CMTime) -> Void) {
        guard interval.isNumeric, interval.seconds > 0,
              interval != lastAppliedInterval else { return }

        // Apply synchronously before recording the value. The initial request
        // must reach the coordinator, even when it matches its default cadence.
        apply(interval)
        lastAppliedInterval = interval
    }
}
