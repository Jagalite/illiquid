# Packet queue ring arithmetic

This experiment compares the production bounded queue with the original
remainder-based ring indexing and a candidate that wraps by one comparison.
The baseline is the unchanged ring at commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Reproduce

On a host without the shared Kyoto queue:

```sh
python3 Benchmarks/PacketQueueRing/run.py --pairs 12 --target-ms 100 --output /tmp/queue-ring-results
```

When Kyoto is available, submit that command through the shared queue as
described in the repository's AGENTS.md. Use a fresh output directory. Builds
and benchmark subprocesses execute serially.

The runner copies the exact production FixedRingBuffer.swift and
PacketQueue.swift sources into both arms. Only the ring differs. It verifies
the pinned baseline's Git blob ID, records source and binary SHA-256 hashes,
and compiles both with Swift 6, -O and whole-module optimization.

## Correctness and measurements

Both arms run the same FixedRingBufferTests and existing PacketQueueWakeupTests
in debug and release. This includes independent array-model checks, wraparound,
capacity-one and non-power-of-two cases, optional payloads, copy-on-write,
reference lifetimes, budget rules, invalidation, callback lock boundaries and
blocked-producer wakeups.

Measurements use capacities 12, 48, 64, 96 and 192, supplied at runtime. The
primary fixtures use the actual locked BoundedQueue:

- Value and preallocated reference payloads, each at half and full occupancy.
- Mixed FIFO/prepend insertion at rolling occupancy.
- Nonblocking tryPush after each pop.

Bare-ring FIFO/mixed fixtures diagnose the indexing mechanism. An unchanged
queue-count fixture is a negative control. A timed cycle performs one pop and
one enqueue; the control performs one count read. Fixture construction, warmup,
remaining-content checks and destruction are outside the timed interval.

Each sample runs in a fresh subprocess. The runner calibrates both arms to the
same iteration count, balances baseline/candidate order across pairs, rotates
case order, records wall and process CPU time, and requires matching
order-sensitive output and remaining-content fingerprints. Summary intervals
are descriptive paired bootstrap intervals; all raw pairs are retained.

These are component measurements. They do not establish playback CPU, energy,
frame-rate, latency or UI improvements. Reference payloads model queue
transport, not FFmpeg allocation or decoding. Thread contention is tested for
correctness, but the timed queues are intentionally uncontended to isolate the
time spent inside their synchronization boundaries.

## Results

Research in progress. The PR will be opened only if native queue measurements
support a useful improvement and the correctness checks pass.
