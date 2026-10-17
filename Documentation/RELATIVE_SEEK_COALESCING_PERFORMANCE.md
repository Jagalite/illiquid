# Relative seek coalescing: effect lifetime and continuing event cost

Retiring superseded deferred seeks eliminates the abandoned pending/outstanding
records in the measured workloads. On native macOS, median position-event service
after 256 relative commands fell from **46.432 to 2.096 microseconds**. The
zero-command control did not show an improvement. The change is 19 production
lines; the regression tests, source-matched benchmark, and raw evidence accompany
the fix.

## Finding and change

Rapid relative seeks can leave effects behind even after the driver cancels their
dispatch. The driver uses a real 40 ms coalescing window. Each accepted relative
command advances the session generation and creates a seek effect. If another
command supersedes a deferred seek, `cancelPendingRelativeSeek()` cancels the task
and discards the driver's reference. In the baseline, it never settles that effect.
The effect never reached the native executor, so no native completion can arrive.

| Command | Driver behavior | Baseline effect ownership |
| --- | --- | --- |
| A | Dispatch immediately | Native executor owns completion |
| B, inside A's coalescing window | Defer dispatch | Driver owns an undispatched effect |
| C, before B dispatches | Supersede B and cancel its task | B remains pending and outstanding without an executor |

Those abandoned records remain in both `PlaybackModelRuntime.pendingEffects` and
`PlaybackCoreState.outstandingEffects`. Later events traverse these collections in
the model and invariant checker. That adds work to ordinary playback observations
after the input burst has ended. The native runtime's steady position observations
are throttled to one per 0.25 seconds; the benchmark compresses such events to
measure component service cost, without reproducing real-time playback.

The production change retires the deferred effect through the existing
`.cancelled` completion path once its session or generation is superseded. The
core removes the effect before rejecting its stale authority, so retirement does
not apply an old seek result to the current target.

The guard matters: sleep detaches a still-current seek before dispatching it, and
same-generation subtitle revisions do not invalidate the core's seek authority.
Already-dispatched effects remain native-owned. Shutdown retains its existing
cleanup path. This change does not alter the 40 ms window or relative target
accumulation.

## Native performance results

The canonical experiment is
[workflow run 39047099141](https://github.com/Jagalite/illiquid/actions/runs/39047099141),
on **macOS 26.6.2, arm64, Apple Swift 6.3.3**, using release builds. It measured
PR code commit `a283c97ffd58cfb317688306796278ccbc2b7e0a` against baseline
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. The runner checked out synthetic merge
`e36bda5c9e6400cd710cf0e54eed978373d1e161`; an independent audit confirms all
candidate production bytes match the PR code commit.

There are **40 observations / 20 pairs**, with four fresh processes per variant
and workload, two AB pairs and two BA pairs. Every process warms the position path
with 256 events, accepts its relative commands, settles the actual accumulated
target, then measures 2,048 position events. All pairs have equal accepted intent
and matching settled/final playback semantics. No failed or partial timing cohort
is included in these results.

### Continuing position-event cost

Numbers are microseconds per event: the median of each process's mean, with the
observed minimum–maximum in brackets. Changes are ratios of variant medians.

| Relative commands | Baseline median [range], µs | Candidate median [range], µs | Change |
| ---: | ---: | ---: | ---: |
| 0 | 1.364 [1.233–4.140] | 1.501 [1.220–2.089] | +10.04% |
| 32 | 9.662 [5.696–10.781] | 3.036 [1.211–3.855] | −68.58% |
| 256 | 46.432 [37.937–48.610] | 2.096 [1.247–4.788] | −95.49% |
| 2,048 | 433.982 [399.405–495.119] | 1.230 [1.219–3.093] | −99.72% |
| 8,192 | 2,388.925 [2,102.881–2,493.099] | 1.254 [1.159–1.310] | −99.948% |

The zero-history median increased by about 10%, with broadly overlapping ranges.
This experiment does not establish a normal-playback speedup. All nonzero-history
cohorts have disjoint observed baseline/candidate ranges. The 2,048- and
8,192-command cases are scaling stress tests, not representative input pacing.

Clock-phase process CPU/wall ratios range from 0.967 to 1.003. CPU time therefore
corroborates the elapsed-time reductions. Four samples per variant and the
control's variability limit conclusions about small differences; these ranges
are observations, not confidence intervals.

### Compressed command burst

These are milliseconds for the whole relative-command loop, including the minimal
transition observer and synchronous fake native executor. Absolute settlement is
timed separately and excluded here.

| Relative commands | Baseline median [range], ms | Candidate median [range], ms | Change |
| ---: | ---: | ---: | ---: |
| 32 | 0.525 [0.419–0.627] | 0.506 [0.400–0.592] | −3.61% |
| 256 | 6.033 [5.899–6.281] | 1.621 [1.488–1.668] | −73.13% |
| 2,048 | 361.008 [311.926–363.552] | 11.509 [10.849–20.914] | −96.81% |
| 8,192 | 9,896.843 [9,634.859–10,052.383] | 43.134 [42.563–45.369] | −99.56% |

The fix adds a genuine cancellation transition callback for each retired effect.
The larger bursts still become much cheaper as abandoned records stop accumulating
inside repeated scans. The 32-command burst's small apparent improvement lies
within overlapping ranges.

The real 40 ms deadline causes different native dispatch counts as execution time
changes. At 2,048 commands, baseline runs dispatch 9–11 native seeks and candidate
runs dispatch two; at 8,192, baseline runs dispatch 237–247 and candidate runs
dispatch three, including the final absolute settlement in all these counts.
Both accept every requested delta and settle identically. These
counts are recorded rather than forcing the coalescer onto an artificial clock.

### Retained value slots

On this native build, `PlaybackEffect` has a 312-byte stride,
`OutstandingEffectRecord` 320 bytes, and `PlaybackEffectID` eight bytes. Each
abandoned seek occupies **640 bytes of value slots** across the pending array and
outstanding dictionary. The candidate retains an eight-byte completed ID for
duplicate detection after retirement.

| Relative commands | Baseline abandoned seeks, median [range] | Baseline pending/outstanding slot bytes, median | Candidate pending/outstanding slot bytes | Candidate completed-ID slot bytes |
| ---: | ---: | ---: | ---: | ---: |
| 32 | 31 [31–31] | 19,840 | 0 | 280 |
| 256 | 255 [255–255] | 163,200 | 0 | 2,072 |
| 2,048 | 2,038.5 [2,038–2,040] | 1,304,640 | 0 | 16,408 |
| 8,192 | 7,949 [7,946–7,956] | 5,087,360 | 0 | 65,568 |

The fractional median at 2,048 averages the two middle integer observations.
Candidate pending and outstanding counts are zero in every settled run. Completed
ID slots include all native completions as well as cancellations. Baseline
completed-ID slot medians are 32, 32, 168, and 3,904 bytes respectively, so its
lightweight ledger also remains visible in the raw data.

These byte figures are lower bounds for live value storage. They exclude spare
capacity, allocation overhead, container headers, and referenced payload storage.
They are not measurements of heap, RSS, physical footprint, or total player memory.

## Validation

The baseline is commit `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

The focused builder compiles 35 complete production source files unchanged,
including the actual driver, model, reducer, invariants, effects, and runtime
protocol. It replaces the native executor with a deterministic fake. On macOS it
uses real platform frameworks. Linux supplies only unused AppKit type surfaces,
Foundation-backed CoreGraphics geometry, and an OSLog sink.

The regression suite passes in debug and optimized release builds on Linux with
Swift 6.3.2 and warnings treated as errors: seven test functions, eight cases.
The same tests against the pinned baseline fail four functions / five cases, with
16 assertion issues. The native-completion, sleep, and shutdown preservation
cases pass against the baseline as well. Source hashes, build commands, and
complete test outputs are retained in
[the Linux test evidence](PerformanceEvidence/RelativeSeekCoalescing/linux-tests).

Coverage includes a 600-command burst, exact-seek and stop supersession, duplicate
callbacks, late native completion, sleep dispatch, an observer replaying a
duplicate cancellation, and final shutdown with no deferred dispatch.

Native macOS debug and release builds also pass all seven registered tests / eight
invocations. The full app graph builds successfully and its driver/coordinator
integration run reports **83 passing tests in two suites**. Six separate benchmark
verification runs pass: playing at all five burst sizes, plus paused at 32. They
replay **10,554 retired cancellation callbacks**, all duplicates, with unchanged
playback semantics and no pending/outstanding effects or invariant violations.

Both existing workflows also pass:
[Restoration and thumbnail regressions](https://github.com/Jagalite/illiquid/actions/runs/39047099093)
and [Non-decoding performance](https://github.com/Jagalite/illiquid/actions/runs/39047099136).
The restoration native job builds the full app and passes 68 XCTest tests and
55 Swift Testing tests. All three workflows complete on their first attempt.

The first Linux timing cohort is excluded: the supplied
libdispatch worker-pool monitor traps independently of Illiquid, reproduced by a
small C-only dispatch program. The environment exposes incompatible namespace
thread IDs and mounted `/proc` IDs. An independent 100,000-call process CPU-clock
control succeeds. No timing values from that incomplete cohort support this PR.
The [excluded cohort and independent reproduction receipts](PerformanceEvidence/RelativeSeekCoalescing/excluded-linux-dispatch)
are retained for audit; the original failed `open` call's errno was not captured.

## Evidence and reproduction

The [native evidence directory](PerformanceEvidence/RelativeSeekCoalescing/macos-ci)
contains all 22 files from the successful workflow artifact, plus sanitized job
and independent audit receipts. The downloaded archive matched GitHub's size
(48,102 bytes) and SHA-256
`849b2534fb3459b77aa74dc4d29d3ed552f2f822446ce3d7a4905340de79580f`.

- [Raw 40-process measurements](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/seek-measurements/measurements.jsonl)
- [Per-workload medians and ranges](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/seek-measurements/summary.json)
- [Cohort settings](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/seek-measurements/environment.json)
- [Source identity audit](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/source-audit.json)
- [Independent numerical audit](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/independent-receipt-audit.json)
- [Separate callback replay audit](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/independent-verification-audit.json)
- [Native tests and job receipt](PerformanceEvidence/RelativeSeekCoalescing/macos-ci/native-job-receipt.json)

The independent audit passes 3,452 checks, recomputing every summary statistic,
effect count equation, value-slot total, event-time division, pair order, and all
80 semantic snapshot checksums. It independently reconstructs 28 abandoned-ID
checksums; the other 12 runs include additional real-time native dispatches whose
full ID sequence is not exported. Those hashes remain harness receipts, with
their count partitions and set-equality checks verified.

The raw measurements have SHA-256
`f648b18875a016b0e9c5d2a933ab9b9682f4d07d1a7d85b21c3e5e94ac815af2`.
Executable hashes were checked on the native runner before and after measurement.
The artifact retains the hashes, not executable bytes, so no independent local
binary rehash is claimed.

The [benchmark README](../Benchmarks/RelativeSeekCoalescing/README.md) provides
standalone commands. The retained workflow runs regression tests on relevant PRs;
manual `workflow_dispatch` additionally runs the paired benchmark using its
`baseline_ref` input. This keeps ordinary future core changes independent of a
fixed historic comparison. The first successful research run above remains the
canonical cohort.

## Measurement design and limits

See [the benchmark README](../Benchmarks/RelativeSeekCoalescing/README.md) for
commands and output definitions. Paired executables must use the same compiler,
platform, harness, and production sources except for the driver. Source bytes and
executable identities are checked. Each workload uses fresh sequential processes,
balanced AB/BA ordering, and rotating workload order.
If a manual comparison changes other selected production sources, it rejects the
run until a matched baseline is selected; that is an attribution check.

The harness measures relative-input burst time separately from continuing
position-event service time. It verifies the accumulated target before explicit
absolute settlement. It records actual native dispatch counts because the real
coalescing deadline can be crossed at different points in each variant. A minimal
common transition observer is active during the burst; it is removed before the
clock-event loop. Reflection occurs only at checkpoints and does not retain model
collection storage across measured mutations. The 20 ms canceled-task drain is
best effort, without an explicit quiescence signal. Its observed wall duration is
25.2–180.4 ms in this cohort and is excluded from the two primary timing regions.

Counts and Swift value strides provide a lower bound on the live pending and
outstanding value slots. They do not measure heap allocations, collection capacity,
referenced payloads, RSS, or total player memory. The existing completed-effect-ID
set still grows as operations retire. The improvement concerns abandoned payloads
and repeated collection scans; it does not bound all playback bookkeeping.

This is a driver/core component experiment. It does not measure decoding,
rendering, actual native seek latency, UI frames, battery use, or full-app CPU.
Percentage changes are ratios of per-variant medians; ranges
describe observations rather than confidence intervals.

## Relevant implementation

- [Relative seek dispatch and cancellation](../Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift)
- [Model effect tracking](../Sources/IlliquidPlaybackCore/PlaybackModelRuntime.swift)
- [Core result authority and retirement](../Sources/IlliquidPlaybackCore/PlaybackCore.swift)
- [Invariant checks](../Sources/IlliquidPlaybackCore/PlaybackInvariants.swift)
- [Native position emission](../Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift)
- [Regression suite](../Tests/IlliquidPlayerTests/RelativeSeekEffectLifetimeTests.swift)
- [Native CI workflow](../.github/workflows/relative-seek-lifetime.yml)
