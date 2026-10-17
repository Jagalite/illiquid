# Planar frame ownership accounting: phase transition cost

## Scope and finding

This investigation covers ownership bookkeeping for the player's qualified
planar software video output. The baseline is
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`, with
`PlanarBufferOwnershipDiagnostics.swift` at Git blob
`0c597cde8a1219d53d3ce0dad760d6d20c8453e3`.

Every accepted phase transition used to recompute all three historical ownership
peaks. That calculation traversed the live checkout dictionary three times and
built a temporary array and set to count distinct buffer identities. Phase
changes do not change an ownership lifetime or buffer identity, so this work
could not discover a new peak.

The production change removes `updatePeaksLocked()` from
`PlanarBufferOwnershipLedger.transition(_:to:)`. The existing lock, checkout
lookup, monotonic phase guard, and phase write remain in place. Checkouts and
renderer attachments continue to update peaks immediately.

This is a component optimization. It does not change video decoding, pixel
conversion, buffer pool limits, presentation timing, or the contents of the
ownership diagnostics.

## Where the work occurs

The normal product policy selects `.planarPreferred` in
[PlaybackController](../Sources/IlliquidPlayer/Player/PlaybackController.swift).
[VideoDecoder](../Sources/IlliquidNativePlayback/Media/VideoDecoder.swift) creates
an ownership token after successfully producing a qualified planar software
frame. Hardware output and BGRA output do not receive a planar ownership token;
this change has no effect on those routes.

There are four normal phase-transition call sites:

| Phase | Caller |
|---|---|
| `waitingForQueue` | `MediaSession.pushVideoFrame`, before queue insertion |
| `queued` | `MediaSession.pushVideoFrame`, after queue insertion |
| `presenting` | `MediaSession.videoPresentationLoop` |
| `submitted` | `SampleBufferVideoPresenter.enqueue`, after renderer enqueue |

These are four attempts per normally submitted frame, rather than a guarantee
of four accepted transitions. In particular, the queue consumer can reach
`presenting` before the producer records `queued`; the existing monotonic guard
already rejects that later backward transition.

The source-defined defaults are a 16-buffer pool, a 12-frame queue, and a
7-frame application pipeline allowance. The latter is calculated as
`min(12, 16 - (5 + 4))` in
[MediaSession](../Sources/IlliquidNativePlayback/Media/MediaSession.swift).
The five unknown-retention and four renderer-attachment slots are allowances
documented from earlier qualification. They are not occupancy observations from
this investigation.

## Why the removed work is redundant

For the current set of checkout records, define:

- **A:** checkouts whose application-frame lifetime is alive.
- **R:** checkouts whose renderer-sample attachment lifetime is alive.
- **K:** distinct buffer identities with either lifetime alive.

The recorded peaks are historical maxima of A, R, and K. An accepted phase
transition changes only a record's phase, so all three quantities stay constant.
The private ledger has two operations that can increase them, and both already
record peaks:

| Operation | Possible increase | Peak update |
|---|---|---|
| Checkout | A and K | Immediately after inserting the record |
| Renderer attachment | R | Immediately after enabling the attachment lifetime |
| Phase transition | None | Removed as redundant |
| Application or renderer release | None | Counts can only decrease |
| Flush, timeout, and snapshot | None | Do not create ownership |

All mutations retain the same lock. This reasoning also covers overlapping
checkouts for a reused buffer, cross-generation ownership, repeated phases, and
both application/renderer release orders. Unknown IDs, backward phases, and
attempts to change a released application's phase retain their existing guards.

## Experiment and evidence

The reproducible runner is in
[Benchmarks/PlanarOwnership](../Benchmarks/PlanarOwnership/README.md).
It compares the pinned baseline source with the candidate source using identical
compiler flags and workload code. Source hashes, compiler details, execution
order, and raw measurements are recorded with each run.

Primary measurements cover complete ownership lifecycles, including checkout,
phase attempts, renderer attachment, and releases. Modeled occupancy spans small
cohorts, the application pipeline allowance, renderer-retained frames, the pool
ceiling, and an explicitly labeled above-pool stress case. A phase-only
measurement, when requested, is an isolated estimate of the removed work rather
than a whole-frame performance result.

Linux uses reference objects for pixel-buffer identity and a small attachment
retention adapter for the unavailable CoreMedia boundary. The ownership ledger,
dictionary operations, locks, phase methods, peak calculation, and token release
methods remain the production source. Native macOS runs use CoreVideo and
CoreMedia directly.

Timing and allocation-instrumented runs are separate. Allocation measurements
count requested heap allocations and bytes; they do not measure live memory,
RSS, GPU memory, or the player's physical footprint.

## Native macOS qualification and measurements

The [dedicated macOS workflow](https://github.com/Jagalite/illiquid/actions/runs/39047209497)
passed on October 17, 2026, using an **Apple M1 virtual runner**, macOS 26.6.2,
and Apple Swift 6.3.3. Native builds used the real production ledger and Apple
frameworks, with `-O -whole-module-optimization` for the timed comparison.
The source and harness hashes match the Linux campaign exactly.

Five native test functions (six cases, including both release orders) passed in **both debug
and release**, including real `CMSampleBuffer` attachment lifetimes and
concurrent phase attempts. The macOS differential run also matched **20,010
snapshots** and passed **30 untimed workload checks** across both configurations.

Eight balanced timing pairs per case used the same 10,000 warmup and 100,000
measured services as the Linux campaign. The primary native pipeline medians
were:

| Modeled retained owners | Baseline, µs/service | Candidate, µs/service | Reduction |
|---|---:|---:|---:|
| 1: one queued frame | 2.221 | 1.327 | 40.3% |
| 7: application pipeline allowance | 3.945 | 1.902 | 51.8% |
| 11: seven queued plus four renderer-only | 5.058 | 2.794 | 44.8% |
| 16: pool-ceiling pressure model | 6.312 | 3.080 | 51.2% |
| 32: above-pool stress | 9.326 | 3.791 | 59.3% |

The seven-plus-four model saved **2.263 µs per service**, a **44.8%** reduction
in native ownership-bookkeeping time. Every native case improved; the mixed
release-order control showed reductions from **39.2% to 54.2%**. All 160 timing
observations had matching paired final states. Recomputing the medians and
checking the raw execution order confirmed four baseline-first and four
candidate-first pairs for every case.

This confirms a component benefit on the target platform. The virtual runner
did not execute the full player or measure physical-device CPU, energy, memory
footprint, frame drops, or responsiveness. The Linux allocation numbers below
remain Linux-specific measurements.

Retained native evidence:

- [Timing summary](../Benchmarks/PlanarOwnership/evidence/macos-timing/summary.json),
  [raw measurements](../Benchmarks/PlanarOwnership/evidence/macos-timing/measurements.jsonl),
  and [platform/source manifest](../Benchmarks/PlanarOwnership/evidence/macos-timing/manifest.json).
- [Native debug test output](../Benchmarks/PlanarOwnership/evidence/macos-validation/native-tests-debug.txt)
  and [release test output](../Benchmarks/PlanarOwnership/evidence/macos-validation/native-tests-release.txt).
- [Qualification receipt](../Benchmarks/PlanarOwnership/evidence/macos-validation/qualification-receipt.json),
  including the tested commit, workflow URL, verified archive digest, and source hash.

## Measured results: Linux component run

Measured on October 17, 2026 with Swift 6.3.2,
`-O -whole-module-optimization`, on an AMD EPYC 9V74 Linux host.
The runner and its children were pinned to logical CPU 0. The timing campaign
used eight paired rounds per case, evenly split between baseline-first and
candidate-first execution, with 10,000 warmup and 100,000 measured services
per process. These are medians from uninstrumented timing runs.

### Primary pipeline workload

| Modeled retained owners | Baseline, µs/service | Candidate, µs/service | Reduction |
|---|---:|---:|---:|
| 1: one queued frame | 1.971 | 1.193 | 39.5% |
| 7: application pipeline allowance | 3.015 | 1.591 | 47.2% |
| 11: seven queued plus four renderer-only | 4.160 | 2.146 | 48.4% |
| 16: pool-ceiling pressure model | 4.761 | 2.504 | 47.4% |
| 32: above-pool stress | 6.793 | 3.285 | 51.6% |

The seven-plus-four model saves **2.014 µs of bookkeeping per frame service**,
a **48.4%** reduction in this component. The absolute saving is small.
Multiplying that component difference by 60 services per second gives about
0.12 milliseconds per second; this is arithmetic context, not a measured
whole-player CPU result. All ten workload/case medians improved, and all 160
paired timing observations ended in matching ownership states.

The alternate lifecycle control, which changes the order in which owners are
released, also improved:

| Modeled retained owners | Baseline, µs/service | Candidate, µs/service | Reduction |
|---|---:|---:|---:|
| 1 | 1.616 | 1.080 | 33.1% |
| 7 | 2.923 | 1.837 | 37.2% |
| 11 | 3.817 | 1.964 | 48.6% |
| 16 | 4.808 | 2.257 | 53.1% |
| 32 | 7.100 | 3.094 | 56.4% |

### Separate allocation run

Four paired rounds per case used the existing Linux/glibc allocation interposer.
Instrumented times were excluded from the timing comparison. The following
counts are normalized per service for the primary pipeline workload; the raw
receipts retain the totals for each 100,000-service process.

| Modeled retained owners | Allocation requests, baseline → candidate | Requested bytes, baseline → candidate |
|---|---:|---:|
| 1 | 14 → 6 | 784 → 304 |
| 7 | 26 → 10 | 2,224 → 784 |
| 11 | 32 → 12 | 3,088 → 1,072 |
| 16 | 35 → 13 | 4,672 → 1,600 |
| 32 | 41 → 15 | 8,608 → 2,912 |

At seven-plus-four modeled owners, allocation requests fell **62.5%**, from 32
to 12 per service, and requested bytes fell **65.3%**, from 3,088 to 1,072.
Those are reductions in temporary allocation traffic. The observed live-owner
counts and historical ownership peaks remained identical. All 80 allocation
measurements had matching paired final states.

### Retained evidence

- [Linux timing summary](../Benchmarks/PlanarOwnership/evidence/linux-timing/summary.json),
  [raw measurements](../Benchmarks/PlanarOwnership/evidence/linux-timing/measurements.jsonl),
  and [manifest](../Benchmarks/PlanarOwnership/evidence/linux-timing/manifest.json).
- [Allocation summary](../Benchmarks/PlanarOwnership/evidence/linux-allocations/summary.json),
  [raw measurements](../Benchmarks/PlanarOwnership/evidence/linux-allocations/measurements.jsonl),
  and [manifest](../Benchmarks/PlanarOwnership/evidence/linux-allocations/manifest.json).
- [Debug differential receipts](../Benchmarks/PlanarOwnership/evidence/linux-validation/differential-debug.json)
  and [release differential receipts](../Benchmarks/PlanarOwnership/evidence/linux-validation/differential-release.json):
  five seeds and 10,005 matching snapshots per configuration, **20,010 total**.
  Another 15 untimed workload checks per configuration passed, **30 total**.

The retained Linux receipt correctly records native CoreMedia tests as
unexecuted on Linux. The separate successful macOS qualification and its
retained evidence are documented above.

## Correctness qualification

The benchmark runner compares baseline and candidate observations over
deterministic operation traces. Clock-dependent durations are compared by
presence and validity, rather than requiring unrelated executions to report
identical wall-clock values.

[PlanarOwnershipTransitionTests](../Tests/IlliquidNativePlaybackTests/PlanarOwnershipTransitionTests.swift)
exercise the native component with real CoreVideo buffers and CoreMedia sample
attachments. Coverage includes peaks before any phase change, forward/equal/
backward attempts, duplicate attachment requests, reused identities with
overlapping checkouts, renderer-only ownership, unknown and released IDs, both
release orders, flush evidence, and concurrent phase attempts. Explicit lifetime
fences keep the checks independent of early ARC destruction.

## Interpretation

Reduced ownership-accounting work is useful on the qualified planar software
path. Its contribution to total player CPU depends on frame rate, live owner
count, accepted phase transitions, and the surrounding decode/presentation work.
Component results must not be presented as an equivalent percentage reduction
in total player CPU or memory.

Apple Silicon playback profiling, power consumption, visual output, and
end-to-end responsiveness require a real macOS player run. Native component
tests and benchmarks can qualify the ledger change without establishing those
broader outcomes.

## Recommendation

The one-call removal is ready for review: native component qualification passed,
and both platforms measured lower bookkeeping cost with matching behavior. It
removes work that cannot change a result and introduces no additional cached
counters or state invariants. Further optimization of checkout/attachment peak calculation
would need its own measurement and correctness case. The present evidence does
not justify claiming a perceptible player-wide speedup.
