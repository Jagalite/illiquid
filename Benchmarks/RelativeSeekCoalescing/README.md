# Relative-seek effect lifetime research

This investigation checks the cost of accepted relative seeks that are superseded
before the driver's 40 ms dispatch timer sends them to the native executor.
Previously, clearing the deferred request left its full effect payload in both
the model's pending list and the core's outstanding dictionary. Subsequent
playback events continued scanning those records.

The candidate reports cancellation for a never-dispatched effect after its
session or generation is superseded. It preserves native ownership of dispatched
effects, the current seek flushed before sleep, and existing shutdown behavior.
See [the production driver](../../Sources/IlliquidPlayer/Player/PlaybackRuntimeDriver.swift)
and [the regression suite](../../Tests/IlliquidPlayerTests/RelativeSeekEffectLifetimeTests.swift).

## Qualification status

The pinned baseline is `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

| Validation | Result |
| --- | --- |
| Candidate selected-source tests, Swift 6.3.2 on Linux, debug | All 7 test functions / 8 cases passed |
| Candidate selected-source tests, Swift 6.3.2 on Linux, release | All 7 test functions / 8 cases passed |
| Current regression suite against pinned baseline, debug | 4 functions / 5 cases failed, with 16 assertion issues |
| Native macOS selected-source tests, Apple Swift 6.3.3, debug and release | All 7 functions / 8 invocations passed in each configuration |
| Native macOS matched timings | 40 observations / 20 pairs passed; all five workloads complete |
| Separate callback replay verification | Six runs passed; 10,554 retired callbacks all reported duplicate |
| Full macOS app graph and coordinator tests | Build and 83 tests passed |

The complete native results, controls, ranges, and interpretation are in the
[research report](../../Documentation/RELATIVE_SEEK_COALESCING_PERFORMANCE.md).
[Canonical run 39047099141](https://github.com/Jagalite/illiquid/actions/runs/39047099141)
used macOS 26.6.2 arm64. Raw outputs, manifests, and independent audits are
[committed with the research](../../Documentation/PerformanceEvidence/RelativeSeekCoalescing/macos-ci).

Baseline failures demonstrate retained pending/outstanding payloads and missing
retirement acknowledgements. Native-dispatched completion ownership, sleep, and
shutdown preservation cases pass on both versions.

**No Linux timing cohort is accepted.** Optimized timing attempts encountered a
libdispatch trap independently reproduced outside the player, associated with a
`/proc` and thread-ID namespace incompatibility in the execution environment.
These failed runs are excluded from performance conclusions. The reported native
measurements come from the complete macOS cohort. They establish component
service-time changes, without measuring total app memory or normal-playback speed.

## Reproduce on macOS

Run from the repository root with Python 3, macOS 26, and the project's Swift
toolchain. The CI workflow selects Xcode 26.6. The pinned baseline commit must be
available in local Git history. Output directories must be new or empty.

```bash
ILLQ_SEEK_OUT="$(mktemp -d "${TMPDIR:-/tmp}/illiquid-relative-seek.XXXXXX")"

python3 Benchmarks/RelativeSeekCoalescing/run.py test \
  --configuration debug --output "$ILLQ_SEEK_OUT/tests-debug"
python3 Benchmarks/RelativeSeekCoalescing/run.py test \
  --configuration release --output "$ILLQ_SEEK_OUT/tests-release"

python3 Benchmarks/RelativeSeekCoalescing/run.py build \
  --source-ref 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548 \
  --output "$ILLQ_SEEK_OUT/baseline-build"
python3 Benchmarks/RelativeSeekCoalescing/run.py build \
  --output "$ILLQ_SEEK_OUT/candidate-build"

python3 Benchmarks/RelativeSeekCoalescing/measure.py \
  --baseline-build "$ILLQ_SEEK_OUT/baseline-build" \
  --candidate-build "$ILLQ_SEEK_OUT/candidate-build" \
  --output "$ILLQ_SEEK_OUT/measurements" \
  --bursts 0,32,256,2048,8192 --repeats 6 --ticks 4096
```

The baseline sensitivity check intentionally exits nonzero because the current
regression suite detects its retained effects:

```bash
python3 Benchmarks/RelativeSeekCoalescing/run.py test \
  --configuration debug \
  --source-ref 8c3cc3d4008d5d1b8d436bcf2d51d891382b6548 \
  --output "$ILLQ_SEEK_OUT/baseline-tests-debug"
```

Additional callback-replay checks use the candidate executable. Verification
retains extra effect contexts and must remain separate from headline timings.

```bash
"$ILLQ_SEEK_OUT/candidate-build/RelativeSeekBenchmark" \
  --burst 256 --ticks 64 --verify > "$ILLQ_SEEK_OUT/verify-playing.json"
"$ILLQ_SEEK_OUT/candidate-build/RelativeSeekBenchmark" \
  --burst 256 --ticks 64 --verify --paused > "$ILLQ_SEEK_OUT/verify-paused.json"
```

[`relative-seek-lifetime.yml`](../../.github/workflows/relative-seek-lifetime.yml)
runs focused debug/release tests and a separate app-integration job on relevant
PRs. The integration job prepares the existing native SDK and runs the lifetime
suite together with coordinator tests. Manual `workflow_dispatch` additionally
runs a shorter matched cohort with bursts `0,32,256,2048,8192`, four repeats and
2,048 clock events, followed by separate callback verification. Its `baseline_ref`
input defaults to the pinned research baseline. The strict paired-source guard
requires a matched baseline when other selected components change. Keeping this
historic comparison manual prevents it from blocking unrelated future core fixes.
Focused build receipts, test logs, and measurement files are uploaded as artifacts.
The initial research run completed the entire cohort before this manual-only
timing condition was added; its committed evidence remains canonical.

## What is measured

`run.py` creates a dependency-free temporary Swift package and copies **35 real
production Swift files byte for byte**: 16 from `IlliquidCore`, all 13 from
`IlliquidPlaybackCore`, five from `IlliquidPlayback`, and the actual
`PlaybackRuntimeDriver`. The core's invariant checks and the model's pending
effect bookkeeping remain enabled. Replay-document recording uses the
production driver's disabled setting.

The harness uses real Foundation, Swift tasks, `ContinuousClock`, locks used by
those runtimes, and the driver's unchanged 40 ms policy. Its fake native executor
immediately reports successful completion of each dispatched effect. It performs
no media decoding, file I/O, output-device work, or UI rendering. macOS uses its
real platform modules. Linux support supplies unused AppKit surface declarations,
Foundation geometry, and a logging placeholder; it does not replace concurrency
or playback logic.

Each fresh process performs these steps:

1. Initialize a valid playing session at 100 seconds and warm the position-event
   path with 256 events. `--paused` selects paused transport for a standalone run.
2. Time a compressed, synchronous burst of relative `+1` commands. A small
   transition observer collects issued seek IDs and invariant violations. The
   burst measurement includes this observer and the driver's genuine cancellation
   callbacks. Actual native dispatch count is recorded because wall time can
   cross the 40 ms deadline during the burst.
3. Check the accumulated relative target **before** issuing one separately timed
   absolute seek to settle that target. Settlement is outside both the burst and
   clock metrics. Remove the transition observer. With zero relative commands,
   no settlement seek is needed.
4. Allow canceled tasks to retire during an untimed **20 ms best-effort wait**.
   This is not an explicit quiescence barrier and does not prove every canceled
   task has finished. Record the actual wait duration.
5. Check retained effect counts, then time position events spaced by 0.25 seconds
   of media time, starting from the settled target. Events execute without
   real-time pacing. No observer or reflection runs in this timed loop.
6. Verify final playback semantics and unchanged effect counts. Optional
   `--verify` then replays cancellation results for abandoned IDs; already-retired
   candidate effects must report duplicate results without changing the snapshot.

Reflection occurs only at checkpoints. It returns counts and newly constructed
integer-ID sets, so it does not keep copies of model arrays or dictionaries alive
during the next timed region. CPU time uses the process CPU clock; wall time uses
monotonic uptime. Review both alongside the task-drain duration.

## Comparison and interpretation

`measure.py` runs fresh baseline/candidate processes sequentially, rotates workload
order, and gives each workload equal AB and BA pairs. Six repeats mean three pairs
in each order. The zero-burst case is the control. Summaries report each variant's
median, minimum and maximum; percentage change is the **ratio of the two variant
medians**, not the median of paired percentage changes.

Build checks require matching compiler, platform, source set and release
configuration, with only the production driver differing. Receipts include source
and executable hashes. Executables are rechecked after the cohort. Every result
is written before validation or summarization. Pair checks require matching
settled/final playback semantics and checksums, while allowing effect IDs and
native dispatch counts to differ with the real clock.

The clock metric describes continued driver/core processing after seek history
has accumulated. The burst metric describes compressed commands plus a minimal
observer and synchronous executor. Neither establishes native seek latency,
rendering performance, UI responsiveness, battery use, or full-app throughput.

Memory fields are **lower bounds for live value slots**, computed from retained
counts and Swift `MemoryLayout` strides. They exclude spare collection capacity,
allocator overhead, top-level container headers and separately allocated payload
storage. They are
not RSS, heap, physical footprint, or total-memory measurements. The existing
completed-effect ID set continues growing: retirement removes heavyweight
pending/outstanding records while retaining lightweight duplicate-detection IDs.
The report must account for that residual growth.

## Evidence files

| File | Contents |
| --- | --- |
| Build/test `manifest.json` | Baseline revision, compiler, exact source identities, limitations and outcome |
| Build/test `commands.jsonl` and `tests.txt` | Commands and complete captured test output, including expected failures |
| Measurement `environment.json` | Cohort settings, platform and runner identity |
| Measurement `baseline-build.json`, `candidate-build.json` | Frozen build receipts |
| Measurement `measurements.jsonl` | Individual process results, semantic checks, counters and raw timings |
| Measurement `validation.json` | Ordering, pairing and receipt-validation outcome |
| Measurement `summary.json` | Per-workload summary statistics derived from the raw results |

The canonical native cohort was independently audited for source identities,
receipt accounting, pair ordering, semantic checksums, and all summary statistics.
The report discloses the +10% zero-history median with overlapping ranges and the
best-effort drain's observed 25.2–180.4 ms duration alongside the larger gains after
seek history accumulates.
