# Fixed ring buffer wrapping

The native player's `BoundedQueue` stores packets and frames in
`FixedRingBuffer`. Normal playback uses capacities 96 (video packets),
192 (audio packets), 64 (subtitle packets), 48 (audio frames), and a configurable
video-frame capacity whose default is 12.

## Hypothesis and change

The baseline uses a runtime integer remainder to wrap the index in append,
prepend, and removal. The existing bounds on the head and count permit one
conditional wrap instead. Storage, capacity, synchronization, accounting,
copy-on-write behavior, and element ownership remain the same. Arbitrary
positive capacities remain supported; there is no power-of-two requirement.

The experiment compares the exact production source at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` against the candidate working tree.
`PacketQueue.swift` must be byte-identical between them.

## Reproduce

Use Swift 6.1 or newer and Python 3.10 or newer. Run builds through the shared
Kyoto queue when available, as required by the repository's `AGENTS.md`.
The hosted workflow reports that Kyoto is unavailable before running serial,
isolated component builds directly.

```sh
python3 Benchmarks/FixedRingBuffer/run.py \
  --output /tmp/illiquid-fixed-ring-buffer \
  --pairs 10 --target-ms 100 --capacities 3,12,48,64,96,192
```

The output directory must be new or empty. Pass `--tests-only` for the debug
and release component regression checks without timing measurements.

## Method

Both variants compile the unchanged production files into temporary packages,
then run the same ring-buffer and existing queue-wakeup regression tests in
debug and release. A second build compiles the exact source files with a shared
driver using `-O -whole-module-optimization -swift-version 6`.

The driver reads capacity and iterations from runtime arguments. Every process
warms its chosen operation, reconstructs the fixture, and measures only the
enqueue/dequeue cycles. FIFO cases keep capacity minus one elements resident
between cycles. Prepend cases fill in batches, then drain. Reference cases
cycle preallocated, distinct objects through the real storage.

Each workload is calibrated using the baseline to at least 100 ms. Baseline and
candidate then run with identical iteration counts in ten adjacent pairs,
alternating AB and BA; workload order is reproducibly shuffled between pairs.
Independent formulas check both warmup and measured checksums. A cycle means
one enqueue and one dequeue; setup, allocation of payloads, and teardown are
outside the timer.

The evidence retains every sample, source and binary hashes, compiler and host
details, commands, calibration, test logs, medians, ranges, and per-pair ratios.
All cases, including slowdowns or inconclusive differences, must be reported.
Timing is research evidence, not a machine-dependent CI pass/fail threshold.

## Interpretation

A useful outcome requires preserved behavior plus a repeatable component
improvement without a material regression in the surrounding synchronized
queue. The integer ring cases separate index arithmetic from queue locks;
reference payloads also exercise ownership traffic.

These are single-threaded ring and uncontended synchronized-queue measurements.
They do not establish faster video decoding, lower playback CPU usage, reduced
energy use, better responsiveness, or improved behavior under producer
contention. The selected-source tests compile on the Mac runner but do not
build or launch the complete player.

## Results

Research measurements and their interpretation will be recorded here after
the first native run.
