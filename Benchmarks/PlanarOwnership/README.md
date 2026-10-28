# Planar ownership transition research

This harness compares the actual `PlanarBufferOwnershipLedger` from pinned main
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548` with the current working source. It checks
the baseline Git blob, records SHA-256 hashes for source/harness/binaries, and
uses identical compiler flags. Production sources are copied into the output's
temporary build directory; no methods are reimplemented in the harness.

The proposed production change removes the `updatePeaksLocked()` call from
`transition(_:to:)`. A phase change cannot change which checkouts or ownership
references are alive. Peak scans remain at checkout and renderer attachment,
where the corresponding counts can increase.

## Scope

On macOS the runner builds the full ledger against actual CoreMedia/CoreVideo
and the production native signpost definition. Pixel buffers are tiny and
created before measurement. On Linux the runner removes exactly three framework
imports and adds `Platform.swift`: reference objects stand in for pixel buffer
identity, a retained field stands in for a sample attachment, and signposts are
inert. Foundation, locks, Swift collections, ARC, every ledger method, and
token/attachment deinitializers remain the production implementations.

Timed code calls `makeRendererSampleAttachment` directly. It measures ownership
bookkeeping, including reference lifetimes, rather than the platform attachment
API. The separate native regression suite exercises real CMSampleBuffer
attachment lifetime. No result measures decoding, pixel conversion, renderer
execution, queue blocking, playback CPU, energy, input latency, or resident RAM.

## Workloads

| Workload | Timed operations | Interpretation |
| --- | --- | --- |
| `pipeline` | Retire an older renderer owner; present a queued frame; attach renderer owner; mark submitted; release application owner; reuse the released buffer identity for checkout, waiting, and queued phases | Primary complete steady-state frame service, four phase attempts per service |
| `lifecycle-mixed` | Retire one survivor, checkout and advance all four phases, attach renderer ownership, then release one owner and retain the other until slot reuse | Complete lifecycle control alternating application-first and renderer-first release |
| `phase` | Repeat an accepted equal-phase transition over retained application owners | Optional method ablation; not a normal frame lifecycle |

`pipeline` has `Q=min(7,N)` queued application owners and `R=N-Q` retained
renderer-only owners. `N` is modeled known distinct buffer occupancy, not measured
current app occupancy. Default product source selects planar software output;
the software pool limit is 16 and default app pipeline capacity is 7. Source
qualification comments reserve an allowance for four known renderer attachments
and five buffers whose remaining platform retention cannot be observed. Those
comments motivate the `N=11` model (7+4); they are not a new playback measurement.

Occupancies 1 and 7 are lower-retention controls. 11 models the source allowance.
16 is pool-limit pressure; its `7+9` owner split is a stress model, not observed
renderer behavior. 32 deliberately exceeds the normal pool limit and is an
algorithmic stress case, not a claim about default playback. The mixed lifecycle
workload records its own survivor counts and alternates release ordering. All
fixtures use preallocated identity objects. They do not allocate fake pixel
surfaces per frame or reconstruct a ledger per transition.

## Correctness

The deterministic trace compares baseline and candidate snapshots after every
operation. It includes reused/overlapping identities, accepted/repeated/regressive
phase updates, stale release callbacks, actual ARC release in both orders,
generation-scoped flush request/completion, timeout snapshots, and missing IDs.
All snapshot integers and flags are compared. Elapsed clock values are excluded
from equality, but their presence and nonnegative finite values are checked.
The trace uses upper PRNG bits and multiple fixed seeds. This is a differential
oracle against existing behavior, including its last-checkout reuse semantics.

`--tests-only` compiles and runs debug and optimized traces. On macOS it also
builds a temporary SwiftPM package containing only the real production ledger,
native signposts, and `PlanarOwnershipTransitionTests.swift`, then executes that
native regression suite in debug and release. This bypasses unrelated FFmpeg
dependencies without substituting any tested production implementation.

## Reproduce

Run from any directory, with Swift available in PATH or supplied by `--swiftc`.
Use a fresh output directory for each invocation. The runner defaults to a new
temporary output directory and prints its path.

```sh
python3 Benchmarks/PlanarOwnership/run.py --tests-only --output /tmp/planar-tests
python3 Benchmarks/PlanarOwnership/run.py --output /tmp/planar-timing
python3 Benchmarks/PlanarOwnership/run.py --allocations --rounds 4 --output /tmp/planar-allocations
```

Normal timing uses `-O -whole-module-optimization` fresh processes in alternating AB/BA order for
each case, eight rounds, 10,000 warmup services, and 100,000 timed services.
Initialization, warmup, snapshot checking, serialization, and teardown are
outside measurement. Raw rows retain every completed observation; summary
contains medians and min/max. Allocation runs are separate and their instrumented
timings are not summarized as comparable CPU results.

`--allocations` reuses the repository's existing Linux/glibc `allocmeter.c`.
It counts successful malloc/calloc/realloc requests and cumulative requested
bytes only. It does not subtract frees or measure live bytes, RSS, physical
footprint, CoreVideo, or GPU memory. Locking/allocator behavior on Linux does not
establish macOS whole-player performance.

Outputs include `manifest.json`, `commands.jsonl`, differential receipts,
`measurements.jsonl`, and `summary.json`. Full traces are compared in memory;
successful traces are represented by their canonical digest and snapshot count
to keep evidence small. A failed comparison writes the first differing snapshot.
The temporary `build/` folder need not be committed or included with the report.

## Recorded result

See [the research report](../../Documentation/PLANAR_OWNERSHIP_PERFORMANCE.md)
for source rationale, the Linux timing/allocation results, qualification limits,
and links to retained raw evidence.

## Baseline overrides and peak-bound follow-up

The historical defaults above remain unchanged. Supply both
`--baseline-commit <full SHA>» and `--baseline-blob <full SHA>» to compare another
reviewed baseline. The runner verifies the blob before compiling and rejects
nonempty output directories so measurements from different runs cannot mix.

`--include-peak-controls» adds unchanged phase transitions and an intentionally
aliased two-identity/11-checkout workload. The latter keeps the known-buffer
upper-bound guard on its exact-count fallback path. It is a diagnostic stress
control, not an observed playback occupancy. Native tests now execute the same
test source against both baseline and candidate in debug and release.

See [the peak-bound experiment](../PlanarPeakBound/README.md) for the current-main
baseline, workload interpretation, results, and limits.
