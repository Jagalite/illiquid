# Planar ownership peak-bound experiment

This follow-up studies temporary allocation and CPU work in
`PlanarBufferOwnershipLedger.updatePeaksLocked()». It compares the actual
production source at main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72» (blob
`e110a666400aa680a2d7b86ed4852c4fe05f08cc») with the working candidate.
The earlier phase-transition and history-storage optimizations are already in
this baseline and must not be credited to this change.

## Change and correctness argument

Let N be the number of checkout records, K the number of distinct live buffer
identities, and P the historical known-buffer peak. K cannot exceed N, so when
N <= P, calculating K cannot change max(P, K). The candidate skips the temporary
compactMap array and Set only in that case. Above that bound it retains the
existing exact identity calculation, including overlapping checkouts.

The decision and mutations remain inside the same lock. Application-frame and
renderer-attachment peak calculations still run independently. There is no new
cached counter, change to token/attachment ownership, or change to snapshots.

## Experiment design

The reusable [PlanarOwnership harness](../PlanarOwnership/README.md) compiles
both production variants with identical Swift 6 flags. Overrides supply the
current baseline and its independently checked blob; the original historical
default remains available to reproduce the earlier research.

- Five seeded traces compare all integer counters and flags in debug and release.
  Clock values are checked for validity and compared by presence.
- Expanded native tests run against both variants in debug and release, including
  CoreVideo buffers and real CoreMedia sample attachments.
- Eight balanced fresh-process pairs measure uninstrumented optimized timing.
- A separate Linux-only allocation pass uses four balanced fresh-process pairs.
  It counts successful malloc/calloc/realloc requests and cumulative requested
  bytes. These are allocation traffic, not live heap, peak memory, or RSS.
- Primary workloads are full warmed frame service and alternating ownership
  release order, at occupancies 1, 7, 11, 16, and 32.
- The existing phase-only workload at occupancy 11 is an unaffected control.
- A new alias control keeps 11 checkout records for two buffer identities. It
  forces the candidate to perform the full identity calculation and exposes the
  cost of the guard when it cannot help. This deliberately represents diagnostic
  stress, not healthy pixel-buffer-pool reuse.
- Pixel-buffer construction, warmup, snapshots, output encoding, and teardown
  are outside the measured interval.

Occupancy 11 models seven application owners and four renderer-only owners;
it is an explicit source-allowance model, not an observed playback trace.
Occupancy 16 is a pool-pressure case; 32 deliberately exceeds the default
pool limit. Component lifecycle timings do not establish player throughput,
rendering latency, energy use, or user-visible responsiveness.

## Reproduction

Honor the repository's Kyoto build coordination in AGENTS.md. The dedicated
workflow uses Kyoto when present and announces its absence before isolated
direct compilation on hosted runners. Keep native test builds serialized.

Use fresh output directories. For native tests and differential traces:

~~~sh
python3 Benchmarks/PlanarOwnership/run.py \
  --baseline-commit ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --baseline-blob e110a666400aa680a2d7b86ed4852c4fe05f08cc \
  --tests-only --output /tmp/planar-peak-bound-tests
~~~

For timing:

~~~sh
python3 Benchmarks/PlanarOwnership/run.py \
  --baseline-commit ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --baseline-blob e110a666400aa680a2d7b86ed4852c4fe05f08cc \
  --rounds 8 --iterations 200000 --warmup 10000 \
  --occupancies 1,7,11,16,32 --workloads pipeline,lifecycle-mixed \
  --include-peak-controls --output /tmp/planar-peak-bound-timing
~~~

On Linux, use the same command with `--allocations --rounds 4 --iterations 20000
--warmup 2000» and another output directory for the independent allocation pass.
The native framework boundary is replaced only on Linux; this is not macOS
allocator evidence.

## Results

Pending execution. No measured improvement or full-player qualification is
claimed by this initial experiment commit. Source/harness/compiler/binary
hashes, raw observations, paired summaries, and native-test receipts will be
retained when the experiment completes.
