# Relative seek coalescing: effect lifetime and continuing event cost

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

## Evidence and validation status

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

Native macOS timing and full app graph validation are pending the PR's
`Relative seek effect lifetime` workflow. Timing conclusions will be recorded
after that run completes. The first Linux timing cohort is excluded: the supplied
libdispatch worker-pool monitor traps independently of Illiquid, reproduced by a
small C-only dispatch program. The environment exposes incompatible namespace
thread IDs and mounted `/proc` IDs. An independent 100,000-call process CPU-clock
control succeeds. No timing values from that incomplete cohort support this PR.
The [excluded cohort and independent reproduction receipts](PerformanceEvidence/RelativeSeekCoalescing/excluded-linux-dispatch)
are retained for audit; the original failed `open` call's errno was not captured.

## Measurement design and limits

See [the benchmark README](../Benchmarks/RelativeSeekCoalescing/README.md) for
commands and output definitions. Paired executables must use the same compiler,
platform, harness, and production sources except for the driver. Source bytes and
executable identities are checked. Each workload uses fresh sequential processes,
balanced AB/BA ordering, and rotating workload order.
If the PR base changes other selected production sources, the comparison rejects
the run until a matched baseline is selected; that is an attribution check.

The harness measures relative-input burst time separately from continuing
position-event service time. It verifies the accumulated target before explicit
absolute settlement. It records actual native dispatch counts because the real
coalescing deadline can be crossed at different points in each variant. A minimal
common transition observer is active during the burst; it is removed before the
clock-event loop. Reflection occurs only at checkpoints and does not retain model
collection storage across measured mutations. The 20 ms canceled-task drain is
best effort, without an explicit quiescence signal.

Counts and Swift value strides provide a lower bound on the live pending and
outstanding value slots. They do not measure heap allocations, collection capacity,
referenced payloads, RSS, or total player memory. The existing completed-effect-ID
set still grows as operations retire. The improvement concerns abandoned payloads
and repeated collection scans; it does not bound all playback bookkeeping.

This is a driver/core component experiment. It does not measure decoding,
rendering, actual native seek latency, UI frames, battery use, or full-app CPU.
Percentage changes, when reported, are ratios of per-variant medians; ranges
describe observations rather than confidence intervals.

## Relevant implementation

- [Relative seek dispatch and cancellation](../Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift)
- [Model effect tracking](../Sources/IlliquidPlaybackCore/PlaybackModelRuntime.swift)
- [Core result authority and retirement](../Sources/IlliquidPlaybackCore/PlaybackCore.swift)
- [Invariant checks](../Sources/IlliquidPlaybackCore/PlaybackInvariants.swift)
- [Native position emission](../Sources/IlliquidNativePlayback/Production/NativePlaybackRuntime.swift)
- [Regression suite](../Tests/IlliquidPlayerTests/RelativeSeekEffectLifetimeTests.swift)
- [Native CI workflow](../.github/workflows/relative-seek-lifetime.yml)
