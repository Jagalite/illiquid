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

## Results

Qualification is pending on the research branch. No runtime improvement is
claimed until the matched tests and measurements complete.

This experiment measures ownership bookkeeping. It does not measure decoding,
rendering, pixel-buffer memory, player RSS, FPS, energy or responsiveness.
