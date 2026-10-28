# Ring index wrapping experiment

Compare the complete production `FixedRingBuffer.swift` and `PacketQueue.swift`
against main at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The candidate replaces
three runtime remainder operations with bounded wrap arithmetic. This is an
experiment; no performance result is implied by the source change.

## Predeclared acceptance

For **each** append/pop workload at production capacities 48, 64, 96, and 192,
for both integer and reference payloads:

- Ring-only median paired CPU and wall time must fall by at least **10%**.
- Complete `BoundedQueue` median paired CPU and wall time must fall by at least
  **5%**, including locking, budget accounting, and condition broadcasts.
- The candidate must be faster in at least **seven of eight pairs** for both
  measurements.
- No control may show a repeatable regression greater than 10%. Here repeatable
  means a paired median increase above 10%, with the candidate slower or equal
  in at least seven of eight pairs in either measurement.

Ring-only gains are insufficient. Failure to demonstrate the queue gain is an
inconclusive or negative result, not a reason to weaken these criteria. Native
macOS results, full baseline/candidate debug/release tests, and complete parity
are required for the runner's `accepted` result. Quick Linux results guide the
investigation and do not satisfy native acceptance.

## Reproduce

Use the shared Kyoto queue when available, following repository `AGENTS.md`.
When unavailable, disclose that limitation and run these builds serially:

```sh
python3 Benchmarks/RingIndexWrap/run.py \
  --output /tmp/illiquid-ring-wrap --run-tests --enforce-performance
```

Requires Python 3.10+ and Swift 6.1+ with Swift Testing. There are no package
downloads or native media dependencies. `--swift /path/to/swift` selects a
toolchain. Output must be new and empty. The default is eight fresh-process
AB/BA pairs per workload, with a 0.2-second calibration target for both CPU and
wall time. `--quick` uses four pairs and 0.05 seconds; `--run-tests` is still
required to execute the test matrix. Pair and target overrides are recorded.

## Workloads and measurement boundary

There are 48 cases: ring/queue × append/prepend × integer/reference × capacities
3, 48, 64, 96, 97, and 192. Capacities 3 and 97 are non-production controls;
all prepend cases are controls. Each queue starts with `capacity - 1` entries.
Every transfer enqueues one item then removes the first, keeping occupancy
steady and exercising wrapped FIFO storage. Prepend/pop controls exercise the
front-insertion path, repeatedly prepending at head zero and popping back to
head zero. Correctness tests cover the other head positions; these timing
controls do not survey them. The reference pool contains 256 preallocated immutable
objects, reused throughout timing. No payload allocation or file I/O occurs in
the timed loop. Ordinary reference retention/release is part of the operation.

Queue cases use the actual blocking `push`/`pushFirst` and `pop` APIs on one
thread, with varied positive byte and duration costs and sufficient budgets to
avoid waiting. The production locks, admission checks, counters, broadcasts,
and callback check remain in the timed path. These are uncontended queue service
costs, not producer/consumer scheduling or playback throughput measurements.

Each iteration contains 256 transfers. Setup, excluded warmup, fixture
allocation, correctness models, final draining, serialization, and process
startup are outside the timer. An opaque, specialized kernel accumulates every
removed value into a checked checksum. Final FIFO contents, occupancy, byte and
duration budgets are verified against an independent sequence model after
timing. Queue wait counters must remain zero.

The concrete kernels compile beside the two **complete production files**
into an optimized `IlliquidNativePlayback` library. The candidate differs
only in `FixedRingBuffer.swift`; the runner rejects other production source
differences. A separate driver calls the library. This permits normal whole
module specialization for the concrete payloads without driver specialization
of fixture arguments into the implementation. The driver, kernels, tests, and
support file are captured once and shared byte-for-byte by both arms. No stub
implementation or source extraction is used.

## Evidence and verification

Before timing each case, both implementations generate a complete operation
trace while checking every result against a simple array model. The retained
compressed JSON includes every popped value, final FIFO contents, and every
queue budget snapshot; baseline and candidate bytes must agree. Timed processes
also check their entire final state and checksum, and the runner compares these
receipts within every pair.

`--run-tests` stages the actual `PacketQueueWakeupTests.swift` and
`FixedRingBufferIndexTests.swift` for both implementations in debug and release.
Those tests cover order/wrapping, non-power-of-two capacities, value semantics,
reference lifetime, wakeups, invalidation, admission budgets, and callbacks.
The isolated test packages use the same production files as measurement.
Test compiler warnings are retained in the logs, without promotion to errors:
the lifetime tests use weak variables, compatible with Swift 6.1, that Swift 6.3
warns could be constants. Measured production, kernel, and driver builds still use
warnings as errors.

Pilot measurements calibrate both implementations separately; the fastest
observed CPU/wall service rate selects one shared iteration count with 10%
headroom. All measured observations are retained. Batches shorter than 80% of
the requested target are recorded and prevent acceptance. No timing outlier
is deleted or subtracted. Each pair runs baseline/candidate then
candidate/baseline on alternating pairs. Builds and benchmark processes run
serially. Shared-host frequency, cache state, and scheduling can still vary.

`manifest.json` records source, test, harness and binary hashes, compiler and
host information, source revisions, and the criteria above. `commands.jsonl`
and `logs/` retain each executed command and its output. `calibration.json`,
`measurements.jsonl`, `semantics/`, `verification.json`, `tests.json`,
`summary.json`, and `acceptance.json` retain the experiment. Summary times are
nanoseconds **per enqueue/remove transfer**, divided by all 256 transfers per
iteration. Paired changes use medians of individual within-pair reductions;
the separately reported baseline and candidate medians need not produce the
same percentage. CPU time includes the wall-clock sampling overhead.

This experiment does not measure decoded frames, the complete player, visible
UI latency, memory consumption, energy, or contended queue throughput.
