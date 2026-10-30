# Subtitle read-ahead wakeups

This experiment targets unnecessary condition broadcasts in the player's
`MediaReadAheadGate`. `NativePlaybackRuntime.consumeRuntimeObservation` updates
the gate before its separate 0.25-second position-emission throttle.
The subtitle worker can still be blocked beyond the 30-second lookahead or at
EOF when those observations arrive.

The baseline is commit `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, gate blob
`10374be342abef4546031d6edd988566b31a62b0`. The candidate retains the earliest
registered timestamp and signals only when the original admission predicate can
succeed. Reset and close still broadcast unconditionally. Diagnostic observers
are notified on the first blocked reader; readers do not notify one another
when returning to sleep.

An earlier unmerged experiment at
[2bea445](https://github.com/Jagalite/illiquid/commit/2bea445f23e65f238ca46539fa2b63169f1ffebb)
identified the same unnecessary wakeups. This follow-up starts from current
`main`, independently qualifies the predicate and observer transitions, and
separates exact-source CPU measurements from untimed instrumentation. The older
branch is preserved; its results are not counted as new measurements here.

## Reproduce

Requires Swift 6 or later, Python 3.10+, and a Git checkout containing the pinned
baseline. This is a Foundation component benchmark; the full media player and
native dependencies are not required.

On an isolated host without Kyoto:

```sh
python3 Benchmarks/SubtitleReadAheadWakeups/run.py \
  --pairs 7 --output /tmp/illiquid-read-ahead-new-results
```

The output directory must be new. Builds and measurements run serially. Where
the shared Kyoto queue exists, submit the complete runner through it:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/SubtitleReadAheadWakeups/run.py --queued \
  --pairs 7 --output /tmp/illiquid-read-ahead-new-results
```

Inspect `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID` before reporting success.
The `--queued` flag is only for an invocation actually executing in that job.
The hosted CI runner reports Kyoto's absence before direct compilation.

## Measurement design

The runner compiles the complete, byte-for-byte baseline and candidate production
gate into separate optimized Swift executables. Each sample uses a fresh process.
Seven pairs alternate baseline/candidate order and rotate the workload order.

| Workload | Operations | Purpose |
| --- | ---: | --- |
| EOF, paced | 120 updates at nominal 60 Hz | Finished subtitle reader while playback advances |
| Distant timestamp, paced | 120 updates at nominal 60 Hz | Sparse subtitle gap below the admission horizon |
| No reader | 2,000,000 updates | Uncontended update control |
| Immediate admission | 2,000,000 waits | Already-eligible fast-path control |
| EOF / distant timestamp, burst | 500,000 updates each | Accelerated primitive/lock contention, not playback cadence |
| Useful progress | 2,000 releases | A genuinely blocked reader becomes eligible at each step |

Thread creation, warmup, close, and joins are outside the resource interval.
The useful-progress control deliberately includes its handshake overhead in
both variants. Process CPU is user plus system CPU from `getrusage`; wall time
uses monotonic uptime. Context-switch counts are process totals, including the
identical sender pacing and handshakes, not exact worker wakeup counts. Paced
wall time is a scheduling control, not a speedup metric.

A separate untimed executable mechanically replaces the one `NSCondition`
construction with a forwarding wrapper. It uses the real OS condition and
counts broadcasts, reader waits, and reader returns under that condition's lock.
The source transformation and hashes are retained. Its registration snapshots
prove actual blocking and observer-before-reader ordering. Candidate ineligible
updates must generate zero broadcasts; spurious OS wait returns are allowed.
Its mixed-reader cohort also verifies no self-generated wake storm, two rapid
threshold crossings, same-generation reset, EOF retention, and invalidation.

The same 14 public-contract tests run against both production sources in debug
and release: 56 test executions. They cover boundary arithmetic, EOF, generations,
reset/close, duplicate and independent deadlines, racing arrivals, diagnostic
observers, nonfinite values, and finite addition overflowing to infinity.

## Evidence and limits

The output includes staged sources, executable/source hashes, platform/compiler
metadata, exact commands and logs, all raw paired samples, mechanism receipts,
test receipts, medians, paired ratios, and a completion receipt. CI uploads the
complete evidence and prints machine-readable `READAHEAD_EVIDENCE` lines.

Results are recorded after the research workflow completes. No percentage gain
is assumed in advance, and correctness CI has no timing-based speedup threshold.

The production-representative benefit is less unnecessary signaling for a
single independent subtitle reader at EOF or in a sparse external bitmap
subtitle interval. Embedded inputs evaluate packet timestamps before filtering
the selected subtitle stream, so dense interleaved media may benefit less until
read-ahead EOF. Multiple-reader behavior is a synchronization stress check.

This experiment does not measure full-player CPU, visible playback, decoding,
frame rate, presentation latency, or battery consumption. Foundation's
[condition-variable contract](https://developer.apple.com/documentation/foundation/nscondition)
still requires every awakened reader to recheck its predicate under the lock.
