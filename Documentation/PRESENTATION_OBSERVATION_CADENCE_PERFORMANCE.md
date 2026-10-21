# Presentation observation cadence

## Investigated path

Baseline: `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`.

`NativePlaybackRuntime.consumeRuntimeObservation()` refreshes the requested
presentation-clock interval after every delivered runtime observation. The
refresh also runs when subtitle pipelines are enabled or disabled. The interval
depends on the existing subtitle policy, selected video frame rate, and whether
the current snapshot uses deinterlacing.

Previously every refresh called
`NativePresentationCoordinator.setPresentationTimeObservationInterval`.
That setter validates its input, then synchronously enters `commitQueue` before
discovering that the requested interval is unchanged. A steady stream therefore
incurs one redundant main-actor-to-presentation-queue request per refresh.

## Change and lifetime

`PresentationObservationCadence` remembers the last applied `CMTime` on the main
actor and forwards only a new valid interval. Its first request always forwards.
It uses CoreMedia equality, matching the coordinator's existing comparison, and
records the interval only after the synchronous receiver returns.

The runtime owns one gate alongside its immutable `presentation` reference.
Source replacement, seek/flush, and audio/video renderer recovery retain the
coordinator, synchronizer, and configured interval. Replacing a time handler
reinstalls its observer using that same interval. Termination is terminal. If a
future change allows replacing the coordinator itself, it must create a fresh
gate with it.

The coordinator's own input validation, equality check, observer replacement,
callback revision fencing, and queue isolation remain authoritative. The change
does not alter cadence calculation, coalescing, callback scheduling, or subtitle
rendering. A change back to an earlier interval still forwards.

## Qualification

The native-only [component runner](../Benchmarks/PresentationObservationCadence/README.md)
compiles the exact production gate and the coordinator's unchanged setter.
It uses real CoreMedia values and a real serial Dispatch queue. Observer
registration is represented by a trace recorder, so component timing does not
include AVFoundation observer registration or playback.

The runner compares baseline/candidate effective-interval traces before paired
optimized measurements, records source and executable hashes, and runs the
seven gate regression tests in debug and release. The regressions cover first
application, unchanged requests, rationally equivalent intervals, transitions
and returns, independent receiver lifetimes, invalid input, and a blocked
receiver queue. The blocked-queue assertion checks whether the receiver was
called; it has no latency threshold.

The repository's native observation integration job and complete native release
suite additionally exercise the app graph and existing paused/seek/cadence
contracts. Executed results and CI links belong in the associated PR; this
document describes the experiment and does not claim unexecuted tests passed.

## Interpretation

The deterministic benefit is removal of redundant synchronous receiver requests
after the first request at a stable interval. Actual interval changes still
enter the receiver, so the alternating-interval case is an explicit overhead
control. Report per-request costs and absolute differences alongside percentages.

Other synchronous presentation reads remain in `consumeRuntimeObservation()`.
This change removes one avoidable queue wait; it does not establish whole-player
CPU, battery, frame-rate, or end-to-end latency gains. The compressed component
workload is not a live-playback trace or a measurement of real queue contention.
