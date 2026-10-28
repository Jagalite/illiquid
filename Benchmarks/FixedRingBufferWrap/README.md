# Independent fixed ring buffer wraparound research

This is a companion study for [PR #193](https://github.com/Jagalite/illiquid/pull/193),
which proposes the same optimization. It adds an independent experiment with
reference-payload queue workloads, a checksum-only control, twelve balanced pairs,
and retained timing evidence. The companion PR targets that implementation branch
and adds no production-source changes.

The production ring computes integer remainders on append, prepend and removal.
Its invariants need at most one wrap at each operation. The candidate replaces
those remainder expressions with a conditional subtraction or increment/decrement
at the boundary. Storage, checked indexing, admission preconditions, copy-on-write,
payload ownership, clear order and synchronization remain unchanged.

Actual default queue capacities are 12 video frames, 48 audio frames, 64 subtitle
packets, 96 video packets and 192 audio packets. Arbitrary positive capacities
remain supported, including one and non-powers of two.

## Results: Linux component qualification

**Native macOS qualification is pending.** The successful Ubuntu job in
[run 40641333427](https://github.com/Jagalite/illiquid/actions/runs/40641333427/job/122659933594)
used Swift 6.4, Linux x86_64, and an AMD EPYC 7763 virtual machine with four
logical CPUs. Its measured source revision is
`0f545d1a60dbb7f0d080d49846ad8faafdad6a5d`.

The storage-only results are consistent: integer FIFO time falls 47.84–47.91%,
reference FIFO time falls 34.43%, and every storage pair favors the candidate.
The complete queue results are smaller and mixed. Reference-payload queue
medians improve 2.68–2.94%, while integer queue medians range from a 2.43%
slowdown to a 1.28% improvement. These measurements establish a portable storage
improvement; they do not establish a general queue or macOS player speedup.
Keep the proposal in draft until native qualification can assess that tradeoff.

All times below are **nanoseconds per enqueue/dequeue pair**, including the
checksum work. Positive reduction means less elapsed time; a negative value
means a slowdown. “Median reduction” compares the two variant medians.
“Paired median reduction” takes the median of the twelve within-pair percentage
changes. Neither statistic discards observations.

### Ring storage

| Workload | Capacity | Baseline ns | Candidate ns | Median reduction | Paired median reduction | Faster pairs |
|---|---:|---:|---:|---:|---:|---:|
| `ring-fifo-int` | 12 | 5.406 | 2.816 | 47.91% | 47.89% | 12/12 |
| `ring-fifo-int` | 48 | 5.402 | 2.817 | 47.84% | 47.85% | 12/12 |
| `ring-fifo-int` | 64 | 5.407 | 2.819 | 47.86% | 47.88% | 12/12 |
| `ring-fifo-int` | 96 | 5.413 | 2.821 | 47.88% | 47.89% | 12/12 |
| `ring-fifo-int` | 192 | 5.407 | 2.820 | 47.85% | 47.86% | 12/12 |
| `ring-prepend-int` | 12 | 7.541 | 2.659 | 64.74% | 64.76% | 12/12 |
| `ring-prepend-int` | 96 | 7.542 | 2.660 | 64.73% | 64.75% | 12/12 |
| `ring-burst-int` | 96 | 5.443 | 3.136 | 42.39% | 42.39% | 12/12 |
| `ring-burst-int` | 192 | 5.443 | 3.189 | 41.42% | 41.41% | 12/12 |
| `ring-fifo-ref` | 96 | 12.811 | 8.400 | 34.43% | 34.37% | 12/12 |

The prepend workload repeatedly prepends and immediately removes at half
occupancy; it is a specific boundary-oscillation pattern. Mixed sequences are
covered by correctness tests, but their timing is not represented by this row.

### Complete uncontended queue

| Workload | Capacity | Baseline ns | Candidate ns | Median reduction | Paired median reduction | Faster pairs |
|---|---:|---:|---:|---:|---:|---:|
| `queue-fifo-int` | 12 | 85.924 | 87.282 | -1.58% | 0.44% | 8/12 |
| `queue-fifo-int` | 48 | 86.439 | 87.071 | -0.73% | -0.56% | 6/12 |
| `queue-fifo-int` | 64 | 87.124 | 86.010 | 1.28% | 0.96% | 9/12 |
| `queue-fifo-int` | 96 | 85.791 | 87.132 | -1.56% | -0.27% | 6/12 |
| `queue-fifo-int` | 192 | 86.211 | 87.051 | -0.97% | 0.01% | 6/12 |
| `queue-prepend-int` | 96 | 85.488 | 87.565 | -2.43% | -0.89% | 5/12 |
| `queue-burst-int` | 96 | 85.979 | 85.402 | 0.67% | 1.23% | 9/12 |
| `queue-fifo-ref` | 96 | 104.830 | 102.017 | 2.68% | 2.28% | 11/12 |
| `queue-fifo-ref` | 192 | 104.937 | 101.851 | 2.94% | 2.61% | 9/12 |

Queue timings have wider variation than the storage-only timings. For example,
the integer capacity-192 case has paired changes from a 20.33% slowdown to a
44.00% improvement. The prepend queue includes two unusually slow baseline
observations; they are retained. Its overall median is nevertheless 2.43%
slower for the candidate, and seven of twelve pairs are slower. The capacity-96
integer FIFO paired median changes sign between AB and BA order. These facts
limit conclusions about small queue differences.

The reference queue's paired reductions are positive in both orders: at
capacity 96 the AB/BA medians are 2.50%/2.20%; at capacity 192 they are
2.58%/3.40%. That is encouraging component evidence, not native confirmation.

The checksum-only control is 1.245107 ns/update for baseline and
1.244861 ns/update for candidate, a 0.0197% median difference. Process CPU
measurements closely track wall measurements; full values and order splits are
in [summary.json](evidence/linux/summary.json) and
[audit.json](evidence/linux/audit.json).

### Qualification and evidence

- All eleven tests in two suites passed for both variants in debug and release.
  That includes the unchanged queue wakeup/invalidation suite and four added
  ring tests.
- Four exact traces match across debug/release and baseline/candidate: sixteen
  ring/queue cases, 116,929 values per trace.
- All 480 timed observations have matching pair checksums, final contents,
  operation counts and seeds. All twenty summary rows were independently
  recomputed from the observations, including AB/BA order splits.
- Every measured observation exceeds the 150 ms target; the shortest is
  156.474814 ms. No timed samples or unfavorable rows were dropped.
- The first attempt stopped before timing because the harness promoted a
  Swift 6.4 weak-variable warning in the existing suite to an error.
  The test invocation now uses normal compiler warnings; production-source
  and benchmark builds still reject warnings. Test assertions and production
  sources were unchanged. Both old and added tests retain Swift 6.1-compatible
  weak-variable syntax. See [attempts.json](evidence/attempts.json).
- [manifest.json](evidence/linux/manifest.json) records compiler, host, exact
  source hashes, binary hashes and dynamic-library resolution;
  [observations.json](evidence/linux/observations.json) retains all timing
  samples; [calibration.json](evidence/linux/calibration.json) retains probes.
  [tests.json](evidence/linux/tests.json), the four test logs,
  [parity.json](evidence/linux/parity.json),
  [completion.json](evidence/linux/completion.json), and
  [commands.json](evidence/linux/commands.json) retain qualification receipts.
- The [CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40641333427/artifacts/12796143070)
  also contains complete differential traces and staged source snapshots.
  Its configured retention is fourteen days; the compact evidence above is
  committed here for durable review.

The frozen baseline, bridge, driver, runner and added tests match the measured
source hashes. The [measured ring snapshot](evidence/linux/FixedRingBuffer.measured.swift)
retains the exact qualified production source. PR #193's inherited production
file differs from that snapshot only by one explanatory comment in append;
removing that exact comment gives byte-for-byte equality. See
[integration.json](evidence/integration.json). This comment-only comparison does
not claim qualification of a new binary or native platform. Repeated runs use
the current production file and record its actual hash. The original complete
experiment is also available at measured Git commit
`0f545d1a60dbb7f0d080d49846ad8faafdad6a5d`.

Final packaging adds this report and evidence and simplifies the workflow to PR
correctness checks plus manual full performance runs. The two studies have
different compilers, hosts, drivers and work sequences; their absolute timings
and percentage gains should be interpreted separately.

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
compiler. Linux results do not establish macOS application performance. The
workflow runs correctness checks on pull requests and full timings on manual
workflow dispatch; performance measurements are not a noisy pass/fail CI gate.

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
PR #133, so it was superseded before opening a duplicate PR. The study
is limited to ring storage and its queue callers. During final packaging,
PR #193 was found to implement the same ring change, so these results are offered
as a stacked companion qualification PR. The implementation remains in PR #193.

