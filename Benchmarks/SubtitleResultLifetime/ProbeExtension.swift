import LifetimeProbe

// Appended verbatim to each staged complete SubtitleDecoder.swift. Swift's
// same-file private access permits observation without rewriting production
// methods or exposing pointers in the application target.
extension SubtitleDecoder {
    func benchmarkRetainedResult() -> LifetimeSnapshot {
        lifetime_snapshot(result)
    }
}
