# Ring-buffer index wrapping

## Question and production change

Does replacing general integer remainder with bounded index wrapping improve the
fixed-capacity storage used by playback queues?

`FixedRingBuffer` maintains a positive capacity, a head in
`0..<capacity`, and a count in `0...capacity`. Before an append,
count is below capacity, so `head + count` needs at most one subtraction.
Prepend wraps zero to the last slot; removing the first item wraps the last slot
to zero. The candidate changes only those three index calculations. It retains
the admission preconditions, payload stores and clearing, element counts,
copy-on-write storage, and fixed capacity after `removeAll`.

The production consumer is `BoundedQueue` in
`Sources/IlliquidNativePlayback/Playback/PacketQueue.swift`.
`MediaSession` uses queue capacities of 96 video packets, 192 audio packets,
64 subtitle packets, 48 audio frames, and a default of 12 video frames. The
benchmark includes direct ring operations and complete uncontended queue
operations, preserving the queue's existing synchronization and accounting.

This is component research. It does not measure playback frame rate, frame
latency, decoding throughput, energy, or performance under producer/consumer
contention.

## Results: Linux component qualification

[Successful Linux run](https://github.com/Jagalite/illiquid/actions/runs/40639921080)
on commit `2b937583e431e2efadfc8a6b612339f5416cd222`.
Target-platform macOS qualification is still outstanding; these results must not
be extrapolated to native macOS performance.

Host: x86_64 Ubuntu 24.04.5, Swift 6.3.3, runner-reported AMD EPYC 9V45 processor
with four CPUs in its affinity mask. Eight balanced pairs per workload, 208
timed observations and 78 retained calibration observations.

| Workload | Baseline median ns/element | Candidate median ns/element | Paired wall reduction | Paired CPU reduction | Wall wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Scalar FIFO, capacity 1 / depth 1 | 4.113 | 1.098 | 73.14% | 73.14% | 8/8 |
| Scalar FIFO, capacity 12 / depth 1 | 4.121 | 1.106 | 73.22% | 73.21% | 8/8 |
| Scalar FIFO, capacity 12 / depth 6 | 4.090 | 1.060 | 74.09% | 74.09% | 8/8 |
| Scalar FIFO, capacity 48 / depth 24 | 4.083 | 1.067 | 73.92% | 73.92% | 8/8 |
| Scalar FIFO, capacity 96 / depth 48 | 4.101 | 1.068 | 73.90% | 73.90% | 8/8 |
| Scalar FIFO, capacity 192 / depth 96 | 4.093 | 1.132 | 72.34% | 72.34% | 8/8 |
| Scalar FIFO, capacity 256 / depth 128 | 4.086 | 1.118 | 72.69% | 72.69% | 8/8 |
| Prepend/drain, capacity 96 | 5.555 | 1.454 | 73.82% | 73.81% | 8/8 |
| Append/drain, capacity 96 | 4.137 | 1.517 | 63.46% | 63.45% | 8/8 |
| Partial drain/clear, capacity 96 | 1.893 | 1.118 | 41.01% | 40.98% | 8/8 |
| Reference FIFO, capacity 96 / depth 48 | 16.780 | 16.300 | 2.99% | 2.98% | 8/8 |
| Complete queue, capacity 12 / depth 6 | 46.650 | 46.692 | -0.20% | -0.19% | 3/8 |
| Complete queue, capacity 96 / depth 48 | 46.310 | 45.880 | 0.74% | 0.76% | 6/8 |

For FIFO scenarios, one logical element means a pop-and-push cycle (two API
operations). Prepend/drain and append/drain rows average one insertion and one
removal per input element. The scalar clear row averages over admitted input
elements, with bulk clearing; it does not measure object destruction. Reference
FIFO uses preallocated objects whose fixture retains another owner, so
allocation and final destruction are outside timing.

Scalar FIFO improvements are consistent in all 56 pairs and save roughly
3 ns/cycle. The reference scenario improves by about 3%, saving about
0.5 ns/cycle. The complete queue controls show small mixed differences:
capacity 12 has a -0.20% paired wall reduction (a slight slowdown), while
capacity 96 has a +0.74% reduction. These results do not establish a material
complete-queue or whole-player improvement. Both control rows and every
individual observation are retained.

The table's first two columns are independent medians. Paired reductions are
medians of each pair's percentage change, so they need not equal the percentage
computed from the two independent medians. Positive reduction means faster.

Validation passed:

- 15 test methods in each of four baseline/candidate debug/release configurations.
- Exact baseline/candidate differential receipts across 15 capacities, 30,720
  mixed-operation steps and 1,262 head offsets (210,412 checked wrap elements).
- All measured checksums matched their independent integer expectations.
- Source and binary hashes remained unchanged throughout qualification.
- Independent review reproduced the complete Array-oracle corpus, every checksum,
  paired observation order and all wall/CPU summary calculations.

[Complete retained evidence](evidence/linux/review-evidence.json) contains every
calibration and measured observation, source/binary hashes, command receipts,
the exact differential outputs and host provenance.
[Independent calculation audit](evidence/linux/audit.json) records the checks.

The compact evidence file has SHA-256
`d87ed9dba253d2b0fec63a59593aea9dc391cf671a857df47dd29999f991bbde`.
Full command logs and staged sources are also attached to the run with 14-day
artifact retention. The committed evidence and reproduction source remain
available after that artifact expires.

## Reproduction

Requirements: macOS, the native Swift 6.1+ toolchain, and Python 3.10+.
The hosted qualification uses macOS 26 and Xcode 26.6. No third-party packages,
FFmpeg installation, media fixtures, or application launch are required.

When the shared Kyoto queue is available, submit the command through it as
required by the repository's `AGENTS.md` and inspect the resulting job and logs.
On an isolated host without Kyoto, run:

```sh
python3 Benchmarks/RingBufferWrap/run.py \
  --pairs 8 --target-ms 80 --output /tmp/illiquid-ring-wrap-results
```

The output directory must be new or empty. Builds and tests are serialized.
The workflow explicitly reports Kyoto's absence before using direct compilation
on the ephemeral GitHub runner.

The frozen baseline is the complete production file at commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`,
Git blob `f381657f22d07f49941b05afbd0c2549a2d98b1e`.
Both implementations use the same complete current `PacketQueue.swift`.
The initial qualification uses blob
`ed52718d3bd42d1ebbd157343334be2bc6b6cc91`; later queue changes are shared by
both variants and recorded rather than rejected. Only the ring baseline is
frozen. The runner verifies its identity and records SHA-256 hashes of all source,
test, harness, package, and executable inputs.

Linux can run the same source and validation as a separate portability check:

```sh
python3 Benchmarks/RingBufferWrap/run.py --platform linux \
  --pairs 8 --target-ms 80 --output /tmp/illiquid-ring-wrap-linux
```

The runner verifies the selected platform and records its actual environment.
Linux measurements are separate component evidence and must not be reported as
native macOS results.

## Validation and measurement

Baseline and candidate run the same ring-buffer regressions and existing queue
wakeup/invalidation tests in debug and release. The focused tests cover repeated
wraparound at small and production-sized capacities, deterministic mixed
operations against an Array oracle, optional nil payloads, independent copies,
and release of reference payloads after removal and clearing.

The benchmark builds each implementation from complete production sources
with optimized whole-module Swift compilation. Capacities are parsed from
runtime input so the compiler cannot replace a known constant divisor.
Fixtures and warmup are outside timing. A separate differential mode validates
the actual ordered results; timed work accumulates observable checksums and
checks final state.

Each workload uses the same iteration count for baseline and candidate.
Calibration is retained separately. Timed observations use eight alternating
baseline/candidate and candidate/baseline pairs, with rotated workload order.
Monotonic wall time and process CPU time are both recorded. No samples are
discarded and no empty-loop cost is subtracted. The primary unit is one logical
element; the report also records API-operation counts.

The workflow retains all command logs and staged sources as an artifact, and
emits machine-readable evidence for independent review. Native macOS results
will be added when target-platform qualification is available.
