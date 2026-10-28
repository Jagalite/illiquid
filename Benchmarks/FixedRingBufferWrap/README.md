# Fixed ring buffer wraparound research

The production ring computes integer remainders on append, prepend and removal.
Its invariants need at most one wrap at each operation. The candidate replaces
those remainder expressions with a conditional subtraction or increment/decrement
at the boundary. Storage, checked indexing, admission preconditions, copy-on-write,
payload ownership, clear order and synchronization remain unchanged.

Actual default queue capacities are 12 video frames, 48 audio frames, 64 subtitle
packets, 96 video packets and 192 audio packets. Arbitrary positive capacities
remain supported, including one and non-powers of two.

## Reproduction

Run through the shared Kyoto queue when available. On an isolated host without
Kyoto, use Swift 6.1 or newer and Python 3:

```sh
python3 Benchmarks/FixedRingBufferWrap/run.py \
  --output /tmp/ring-wrap-results --pairs 12 --target-ms 150
```

The destination must not already exist. `--tests-only` builds both versions in
debug/release and runs complete differential and regression checks without timing.
macOS and Linux are measured separately; the manifest records the actual host and
compiler. Linux results do not establish macOS application performance.

## Method and scope

- Frozen baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; the runner checks
  its complete source against Git. Only `FixedRingBuffer.swift` differs.
  `PacketQueue.swift` is complete, unchanged production code.
- A small benchmark bridge builds beside both production sources, allowing
  concrete generic specialization as in the application's module. A separately
  compiled driver supplies capacities, iteration counts and seeds at runtime.
  Dynamic-library resolution and all source/binary hashes are retained.
- Independent Array-oracle traces cover mixed operations at eight capacities.
  The new ring tests cover 13 capacities, optional payloads, wrapped copies,
  clear/reuse, and exact payload release order. Existing queue tests cover
  blocked producers, invalidation, close, budgets, callbacks and object release.
  Both suites run against both revisions in debug and release.
- Timings cover the ring alone and the complete uncontended `BoundedQueue`,
  including locks, broadcasts and budget accounting. Integer and reference
  payloads, append/prepend, bursts and a checksum-only control are included.
  Reference payload allocation is outside timing; queue retain/release work is
  inside. Buffer/queue construction, warmup and final draining are outside.
- An operation is one enqueue/dequeue pair (or one checksum update in the
  control). Every removed value and the final queue contents feed checksums.
- Twenty workloads use twelve balanced AB/BA fresh-process pairs. Both variants
  calibrate to at least 150 ms; later observations are all retained, including
  shorter and unfavorable samples. The completion receipt records duration
  minima and any observations below the target. Wall and process CPU times
  are reported separately.

These are storage and uncontended-queue component measurements. They do not
measure blocked producer throughput, decoding, rendering, playback FPS, memory
savings, energy or the full application.

## Research selection

The initial video-color sampler investigation overlapped with newly opened
PR #133, so it was superseded before opening a duplicate PR. The final production
diff is limited to the ring buffer; no sampler changes are proposed here.

Results will be added after qualification completes.
