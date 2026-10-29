# Planar ownership peak accounting

## Question and production change

Can the per-frame ownership ledger reduce transient allocation traffic and time
under its lock while keeping exactly the same diagnostics?

The current baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, production
source blob `e110a666400aa680a2d7b86ed4852c4fe05f08cc`. Unlike the earlier
[phase-transition experiment](../PlanarOwnership/README.md), this comparison
starts after that optimization and the history-memory change were merged.

`updatePeaksLocked()` currently traverses the checkout dictionary twice for
owner counts and once to create an identity array, then constructs a set from
that array. The candidate performs one traversal, counts the two independent
ownership lifetimes, and inserts live identities directly into a set reserved
to the checkout count. That count is an upper bound, not the distinct-buffer
result: multiple checkouts can share the same buffer. The set and the three
monotonic peak updates remain local to the same critical section.

The source-level change removes two dictionary traversals and an eager
intermediate array. A numeric allocation claim requires measurement; collection
allocation counts can depend on compiler and runtime behavior.
[Swift documents minimum-capacity set initialization](https://developer.apple.com/documentation/swift/set/init(minimumcapacity:))
as a way to avoid storage growth while inserting a known upper bound.

## Qualification

The existing [PlanarOwnership harness](../PlanarOwnership/README.md) compiles the
actual baseline and candidate production source with identical flags. Its
historical baseline defaults are preserved; both overrides below are required
together and must be full commit/blob SHAs. The runner verifies the source blob
before compiling and records source, harness and executable SHA-256 digests.

The debug and release differential traces each use five fixed seeds and 2,000
operations per seed, comparing every snapshot integer and flag. Clock values
are checked for validity and normalized. The traces include overlapping
identities, both release orders, stale callbacks, phase regressions, flushes,
and timeouts. macOS also executes the real CoreMedia/CoreVideo ownership tests
in debug and release, including a new mixed-owner peak regression.

Timing uses eight alternating AB/BA rounds in fresh processes, 10,000 warmup
services, and 100,000 timed services. Both `pipeline` and `lifecycle-mixed`
workloads run at occupancies 1, 7, 11, 16 and 32. Occupancy 11 is the earlier
source-motivated model of seven application owners plus four renderer owners;
it is not a new live-player observation. Occupancy 32 exceeds the normal pool
limit and is only an algorithmic stress case.

Linux/glibc allocation runs use the existing interposer in four separate
AB/BA rounds. Its counters are cumulative successful malloc/calloc/realloc
requests and requested bytes, not retained memory or RSS. Instrumented timings
are not used as native timing evidence.

## Reproduce

Follow the root `AGENTS.md` build coordination rule: use the shared Kyoto queue
when available. The hosted workflow checks that Kyoto is absent before using
serial builds in isolated directories.

```sh
python3 Benchmarks/PlanarOwnership/run.py --tests-only \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --baseline-blob e110a666400aa680a2d7b86ed4852c4fe05f08cc \
  --output /tmp/planar-peak-tests

python3 Benchmarks/PlanarOwnership/run.py \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --baseline-blob e110a666400aa680a2d7b86ed4852c4fe05f08cc \
  --rounds 8 --iterations 100000 --warmup 10000 \
  --output /tmp/planar-peak-timing

# Linux/glibc only; run separately from ordinary timing.
python3 Benchmarks/PlanarOwnership/run.py --allocations \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --baseline-blob e110a666400aa680a2d7b86ed4852c4fe05f08cc \
  --rounds 4 --iterations 100000 --warmup 10000 \
  --output /tmp/planar-peak-allocations
```

## Measured results

[Research workflow 40636421757](https://github.com/Jagalite/illiquid/actions/runs/40636421757)
tested implementation commit `823296f978a8bcc9e8fdab98137aeebcf610ee53`.
The [Linux job](https://github.com/Jagalite/illiquid/actions/runs/40636421757/job/122644317046)
passed on Ubuntu 24.04, runner image `20261023.334.3`, Swift 6.4, glibc 2.39,
AMD EPYC 7763. Baseline and candidate use the same toolchain and flags.

At the source-motivated occupancy of 11, **both complete-lifecycle workloads
reduce allocation requests from 12 to 4 per service (66.7%) and cumulative
requested bytes from 1,072 to 448 per service (58.2%)**.

| Workload | Occupancy | Baseline requests/service | Candidate requests/service | Fewer requests | Baseline requested bytes/service | Candidate requested bytes/service | Fewer requested bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| pipeline | 1 | 6 | 4 | 33.3% | 304 | 224 | 26.3% |
| pipeline | 7 | 10 | 4 | 60.0% | 784 | 448 | 42.9% |
| pipeline | 11 | 12 | 4 | 66.7% | 1,072 | 448 | 58.2% |
| pipeline | 16 | 13 | 4 | 69.2% | 1,600 | 704 | 56.0% |
| pipeline | 32 | 15 | 4 | 73.3% | 2,912 | 1,216 | 58.2% |
| lifecycle-mixed | 1 | 6 | 4 | 33.3% | 304 | 224 | 26.3% |
| lifecycle-mixed | 7 | 10 | 4 | 60.0% | 784 | 448 | 42.9% |
| lifecycle-mixed | 11 | 12 | 4 | 66.7% | 1,072 | 448 | 58.2% |
| lifecycle-mixed | 16 | 14 | 4 | 71.4% | 1,872 | 704 | 62.4% |
| lifecycle-mixed | 32 | 16 | 4 | 75.0% | 3,440 | 1,216 | 64.7% |

Values are the median counts divided by 100,000 timed services. All four
observations for each variant/case had identical allocation counts and bytes.
The reductions are `100 * (1 - candidate / baseline)`. All 80 raw observations
(40 pairs across 10 cases) are retained; every pair ended in identical semantic
snapshots. Initialization, warmup, snapshot serialization and teardown are
outside the measured interval.

These counters include the complete modeled ownership lifecycle, including
token and attachment allocation. The candidate still needs a temporary set.
The source change avoids the eager array and its growth, rather than eliminating
all per-service allocations.

### Correctness status

- **Passed:** actual baseline/candidate ledger compilation and deterministic
  differential checks in debug and release on Linux. Each configuration
  compared 10,005 snapshots (five seeds, 2,001 snapshots each), for 20,010
  snapshot comparisons in the dedicated correctness run.
- **Passed:** untimed workload controls for pipeline, mixed lifecycle, and phase
  behavior at all five occupancies, in debug and release.
- **Passed:** all measured baseline/candidate pairs ended in the same ownership
  state; an independent recalculation from raw rows matches the summaries.
- **Pending:** the native macOS job is queued. The new mixed-owner regression,
  existing CoreMedia/CoreVideo lifetime tests, and native timing have not yet
  executed. Do not infer native timing success from the Linux result.

The Linux harness substitutes only the CoreMedia/CoreVideo and signpost
boundaries. The ledger, Swift collections, locking, tokens, attachment owners
and ARC callbacks are actual production code. This is useful portable component
evidence, but native qualification remains a separate gate.

### Retained evidence

The [evidence index](evidence/index.json) records the originating run, job and
per-file SHA-256 values emitted by CI. The files are the unmodified text records
exported by the job:

- [Host and toolchain](evidence/linux/host.json).
- [Allocation manifest](evidence/linux/allocations/manifest.json),
  [raw observations](evidence/linux/allocations/measurements.jsonl), and
  [summary](evidence/linux/allocations/summary.json).
- [Debug differential receipts](evidence/linux/tests/differential-debug.json)
  and [release differential receipts](evidence/linux/tests/differential-release.json).
- [Compilation and test commands](evidence/linux/tests/commands.jsonl) and
  [measurement commands](evidence/linux/allocations/commands.jsonl).

The implementation and benchmark/test sources have not changed since the
measured commit; the subsequent evidence commit adds documentation and receipts.

### Limits

This is a successful reduction in transient allocation traffic for the measured
component workloads. It does not establish native elapsed-time improvement,
retained heap reduction, player RSS, decoding or rendering performance,
pixel-buffer/GPU memory, FPS, energy or responsiveness. The macOS job is
configured to collect native timing in eight AB/BA rounds; those results must be
reviewed before making a native speed claim. The runner reports percentage
change in variant medians, not the median of per-pair changes.
