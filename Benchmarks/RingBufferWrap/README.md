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

Native results and interpretation will be added after qualification. The
workflow retains all command logs and staged sources as an artifact, and emits
machine-readable evidence for independent review.
