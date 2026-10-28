# Playback queue notification research

This study measures condition-notification overhead in `BoundedQueue`, used by
`MediaSession` for the normal video/audio/subtitle packet queues and decoded
frame queues. The production change touches four notification sites in
`PacketQueue.swift`.

## Change and correctness argument

Successful `push`, `tryPush`, and `pushFirst` broadcast when storage becomes
nonempty. `pop` broadcasts when a producer is waiting for capacity.
All decisions remain under the existing condition lock.

Consumers can enter their wait only while storage is empty. The first enqueue
broadcasts to all existing sleepers; while storage remains nonempty, a new
consumer cannot enter that wait. Producers increment their existing waiter
count before the atomic unlock-and-wait operation, so a zero count excludes a
parked producer. A producer still acquiring the lock will inspect the current
budget itself. This follows the predicate/lock protocol described in
[Apple's NSCondition documentation](https://developer.apple.com/documentation/foundation/nscondition).

Close, removal/invalidation, diagnostic observer notifications, the FIFO and
prepend rules, item/byte/duration limits, oversize-singleton admission, and the
capacity callback remain intact. Notifications still use broadcast because
producer and consumer waiters share one condition.

For the uncontended fill/drain fixture, inspection gives 2d broadcasts for d
transfers before the change and one broadcast after it. This is a count derived
from the source and fixture, not an instrumented measurement of kernel wakeups.

## Reproduce

Use the shared Kyoto queue when available as described in [AGENTS.md](../../AGENTS.md).
On an isolated host without Kyoto, with Swift 6.1 or newer on PATH:

```sh
bash Scripts/test-queue-notifications.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-queue-notifications.sh --jobs 2 -c release -Xswiftc -warnings-as-errors
ILLIQUID_PACKET_QUEUE_SOURCE="$PWD/Benchmarks/QueueNotifications/baseline/PacketQueue.swift" \
  bash Scripts/test-queue-notifications.sh --jobs 2 -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/QueueNotifications/run.py --output /tmp/illiquid-queue-results --rounds 8
```

The output directory must not already exist. The test script creates an isolated
package from the complete production queue and ring sources, the new liveness
suite, and the existing queue wakeup tests. It does not resolve FFmpeg or build
the player. Its override applies only to the queue source, allowing the same
regression contract to run against the frozen baseline.

The runner checks the frozen baseline from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` against Git blob
`ed52718d3bd42d1ebbd157343334be2bc6b6cc91` and checks the shared ring source
against `f381657f22d07f49941b05afbd0c2549a2d98b1e`. It compiles the actual
complete files in Swift 6 language mode with `-O`,
`-whole-module-optimization`, and warnings as errors.

## Measurement design

There are 30 workloads and eight fresh-process baseline/candidate pairs per
workload, totaling 480 observations per cohort. Case order is deterministically
shuffled; variant order alternates AB and BA. Buffered cases calibrate toward
100 ms of baseline work and use the same iteration count for the candidate.

The 24 uncontended cases cover all three enqueue APIs, zero-cost frame-like
items and packet byte/duration accounting, capacities 48/64/96/192, and depths
1/4/16/48. Six threaded controls use a real producer and consumer, capacities
1/48/96, and both cost modes. Their capacity and consumer waits are included.
Capacity 1 uses 20,000 transfers; the other threaded controls use 100,000.
The byte/duration budgets in these fixtures are intentionally nonbinding, so
measured backpressure comes from item capacity. The focused regression tests
separately check byte- and duration-limited admission. Queue depths and payload
costs are synthetic, not taken from an observed playback trace.

One **transfer** is one enqueue plus one pop. Queue/thread creation, payload
allocation, and warmup are outside the measured region. Payloads are
preallocated reference objects. Timed work includes locks, admission, ownership
operations, delivery-order checks, and checksums. The receipt after each run
verifies delivery count, payload checksum, and empty item/byte/duration budgets.
The runner compares semantic receipts between variants; scheduling-dependent
wait counters are retained but are not required to match.

The manifest records the compiler, host, source and binary hashes, exact
commands, and Git state. Raw observations preserve every pair and all CPU/wall
measurements. No noisy speed threshold is used as a CI gate.

## Initial observations

[Research run 40634131339](https://github.com/Jagalite/illiquid/actions/runs/40634131339)
measured commit `05dd06abc6eeb17e6ac5f8271567c3df472d6680` on an Apple M1
virtual macOS 26.6.2 runner with Apple Swift 6.3.3.

All 24 uncontended medians decreased by 5.47–18.36%, saving 4.95–15.69 ns per
enqueue/pop transfer. Threaded controls are noisy and do not establish a
throughput improvement or a nonregression bound. In particular, capacity-1
packet transfers had a candidate median 11.76% worse, while balanced pairs split
4–4 and the median paired ratio was 0.999631. Both variants showed widely
separated fast and slow scheduling regimes. This cell is retained below.

| Workload | Cost | Capacity | Depth | Baseline ns/transfer | Candidate ns/transfer | Reduction |
|---|---|---:|---:|---:|---:|---:|
| buffered: push | zero | 96 | 1 | 96.71 | 90.48 | 6.44% |
| buffered: try-push | zero | 96 | 1 | 91.43 | 85.47 | 6.52% |
| buffered: prepend | zero | 96 | 1 | 96.57 | 90.07 | 6.73% |
| buffered: push | zero | 48 | 4 | 99.89 | 87.33 | 12.57% |
| buffered: try-push | zero | 48 | 4 | 89.04 | 78.17 | 12.21% |
| buffered: push | zero | 64 | 16 | 97.74 | 84.43 | 13.61% |
| buffered: try-push | zero | 64 | 16 | 86.30 | 72.38 | 16.13% |
| buffered: push | zero | 96 | 48 | 97.35 | 83.69 | 14.04% |
| buffered: try-push | zero | 96 | 48 | 85.07 | 72.74 | 14.50% |
| buffered: push | zero | 192 | 48 | 97.18 | 83.87 | 13.70% |
| buffered: try-push | zero | 192 | 48 | 85.00 | 72.27 | 14.98% |
| buffered: prepend | zero | 64 | 16 | 98.63 | 85.74 | 13.07% |
| threaded: push | zero | 1 | 1 | 8950.85 | 8789.17 | 1.81% |
| threaded: push | zero | 48 | 1 | 270.47 | 255.83 | 5.41% |
| threaded: push | zero | 96 | 1 | 206.82 | 202.89 | 1.90% |
| buffered: push | packet | 96 | 1 | 97.25 | 90.15 | 7.30% |
| buffered: try-push | packet | 96 | 1 | 90.41 | 85.46 | 5.47% |
| buffered: prepend | packet | 96 | 1 | 97.37 | 89.80 | 7.78% |
| buffered: push | packet | 48 | 4 | 99.57 | 88.08 | 11.54% |
| buffered: try-push | packet | 48 | 4 | 87.66 | 77.92 | 11.11% |
| buffered: push | packet | 64 | 16 | 97.29 | 84.04 | 13.62% |
| buffered: try-push | packet | 64 | 16 | 86.32 | 72.09 | 16.48% |
| buffered: push | packet | 96 | 48 | 97.24 | 83.31 | 14.33% |
| buffered: try-push | packet | 96 | 48 | 84.42 | 71.83 | 14.92% |
| buffered: push | packet | 192 | 48 | 97.57 | 83.45 | 14.47% |
| buffered: try-push | packet | 192 | 48 | 85.44 | 69.75 | 18.36% |
| buffered: prepend | packet | 64 | 16 | 98.23 | 84.70 | 13.78% |
| threaded: push | packet | 1 | 1 | 8186.23 | 9148.96 | -11.76% |
| threaded: push | packet | 48 | 1 | 265.19 | 255.64 | 3.60% |
| threaded: push | packet | 96 | 1 | 205.94 | 200.63 | 2.58% |

## Validation status and retained evidence

The source review and initial measurement audit support proposing this change.
The PR remains a draft pending execution of the corrected regression gates.
The [Apple Silicon confirmation](https://github.com/Jagalite/illiquid/actions/runs/40635790679)
and [additional Intel macOS validation](https://github.com/Jagalite/illiquid/actions/runs/40636096026)
were queued at publication. No Intel performance result is claimed.


The initial benchmark compiled both optimized variants and all 480 measurement
receipts passed. Independent recomputation checked every receipt, all 240 AB/BA
pairs, and all 30 summary cells.

The initial run's green workflow status did **not** establish test success.
Piped test output masked compilation errors: Swift 6.3.3 reported the existing
test's never-reassigned weak variable as an error under warnings-as-errors.
The test now reuses that weak reference to check close-time payload release as
well as removal, and the workflow uses explicit Bash pipefail semantics.
The corrected correctness gates and the unchanged benchmark are being rerun.
No regression-test pass is claimed from the initial cohort.

[initial-macos.zip](evidence/initial-macos.zip) retains the original manifest,
raw observations, full summaries, calibration, build logs, and failed test logs.
Its SHA-256 is
`a0b8417d3237eb97b92458ec571817651c87a09f5d347988f9cd0899a5469821`.
[initial-audit.json](evidence/initial-audit.json) records the independent
receipt audit and the explicit test-qualification limitation.

These component timings do not measure full playback CPU, FPS, seeking,
decoding, rendering, energy use, or physical-device presentation quality.

The complete [initial summary](evidence/initial-summary.json) is available without
unpacking the archive. [provenance.json](evidence/provenance.json) records source
identities, the original run, and the pending corrected validation runs.

PR CI runs the focused debug/release/baseline checks with failure propagation.
The full 30-workload benchmark remains available through explicit workflow
dispatch and the command above; the temporary research-push trigger is removed.
The repository's existing native integration gates are unchanged.
