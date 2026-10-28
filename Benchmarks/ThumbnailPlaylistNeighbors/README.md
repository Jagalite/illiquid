# Thumbnail playlist neighbor qualification

This benchmark compares the production `ThumbnailPlaylistNeighbors` helper
with the original eager URL projection in the pinned background scheduler.
Read the [research report](../../Documentation/THUMBNAIL_PLAYLIST_NEIGHBOR_PERFORMANCE.md)
for the finding, measured results, exact behavior preserved, and limitations.

## Run

Requires Python 3 and Swift 6.1 or newer. Use a new or empty output directory.

```sh
# Debug/release correctness gates followed by a balanced timing campaign.
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-timing --pairs 6 --target-ms 100

# Correctness only: baseline/candidate, debug/release.
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-tests --tests-only

# Separate Linux/glibc allocation-request cohort.
python3 Benchmarks/ThumbnailPlaylistNeighbors/run.py \
  --output /tmp/thumbnail-neighbors-allocations \
  --allocations --skip-tests --pairs 2
```

Submit commands through the shared Kyoto queue when available as required by
`AGENTS.md`. If unavailable, record that limitation before direct builds and
serialize builds sharing a package directory. The runner itself builds its
isolated packages sequentially.

`--swift /path/to/swift` selects a compiler. `--case 10000/middle` selects one
case and may be repeated. `--sizes` changes the default sizes
`0,16,512,10000,100000`. Pair counts must be even and at least two.
`--iterations` forces a fixed iteration count for smoke checks; calibrated
timing is the default. Allocation cohorts use three operations per process
by default and must be run separately from timing.

## Method and receipts

The runner stages actual production sources and focused tests in isolated
Swift modules. It validates the frozen baseline's Git blob and SHA-256,
extracts the original projection statements, and wraps them behind the same
interface. The benchmark uses an opaque, non-inline invocation, consumes
results, and checks complete output against an independent oracle.

Fixtures, URL normalization, warmup, oracle validation, and serialization are
outside the measured operation. Each observation starts a fresh process.
Baseline/candidate order alternates in balanced AB/BA pairs. CPU and wall time
are normalized per operation, with independently calibrated iteration counts.

The output directory contains:

- `manifest.json`: sources, hashes, compiler, environment, builds, and test results.
- `commands.jsonl` and build/test logs.
- `verification.json`, `calibration.json`, and `iteration-counts.json`.
- `observations.jsonl`: individual process measurements and output receipts.
- `summary.json`: per-operation distributions and within-pair changes.
- `allocation-meter-control.json` for the allocation cohort.
- `completion.json`: successful completion and measurement count.

Allocation measurements count successful glibc malloc/calloc/realloc requests
and cumulative requested bytes, not live memory, peak footprint, or RSS.

## Published qualification

[Run 40634690101](https://github.com/Jagalite/illiquid/actions/runs/40634690101)
passed on Linux and Apple Silicon macOS. The [evidence index](evidence/ci-run-40634690101.json)
links the original artifacts and records their SHA-256 digests and expiration.
All three numeric summaries are retained in this repository. Full raw receipts
remain in the linked artifacts subject to GitHub retention.

The original Swift 6.4 manifest recorded only the final test process count
(6 instead of the combined 13 + 6). All tests passed; the current runner sums
the counts and requires each named suite. Historical receipts remain unchanged.
