# Checkpoint construction benchmark

Measures the complete `PlaybackCheckpoint.record()` operation, including
unchanged playlist deduplication and timestamp creation. It excludes JSON
encoding, file writes, task scheduling, and interactive playback.

The baseline checkpoint source is pinned to
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Both variants use the same eight
unmodified supporting production files and the same test and benchmark sources.
The harness creates separate Swift packages, with no source stubs or rewritten
imports. It runs the checkpoint, playlist mutation, deduplication, session-record,
and atomic session-store tests in debug and release for both variants.

## Run

Requires native macOS and an Xcode toolchain compatible with the app's macOS 26
deployment target.

```sh
python3 Benchmarks/CheckpointConstruction/run.py \
  --pairs 8 --target-ms 40 --output /tmp/checkpoint-construction
```

The output directory must be new or empty. Use `--tests-only` to run the four
test configurations without the timing campaign.

When the shared Kyoto queue is available, submit the entire harness through it:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/CheckpointConstruction/run.py \
  --pairs 8 --target-ms 40 --output /tmp/checkpoint-construction
```

Inspect the returned job with Kyoto's `show`, `logs`, and `wait` commands before
reporting success. Hosted CI has no Kyoto mount; the harness serializes its
builds and each variant owns a separate `.build` directory.

## Measurement protocol

The optimized driver calls the production method in a separately compiled
module; its body is not exported for inlining, and cross-module optimization is
not enabled. Fixture construction and a
checked warmup run before timing. Each returned record contributes to a checked
checksum. The complete warmup record is JSON-encoded outside timing with only its
timestamp fixed; SHA-256 digests must agree for both variants.

There are 23 workloads: empty and singleton controls; first, middle, and late
matches; small and large playlists; missing targets; absent, stale, negative,
and oversized index hints; no collection folder; Unicode paths; duplicates;
remote sources; unsupported file authorities; and unsupported playlist items.
The wrong-hint/first-hit and all-unsupported-item cases retain the potential
cost of checking the hint or preparing a source identity eagerly.

Each workload calibrates iterations using only the baseline (six attempts,
500,000-iteration ceiling, half-target stopping rule). Both variants then use
the same iteration count for eight alternating pairs of fresh processes. Every
sample is retained. Results include medians, ranges, median within-pair
percentage reductions, and the number of pairs in which the candidate is
faster. No timing threshold is used in tests or CI.

The output retains exact source/test/driver copies, source and executable
hashes, compiler and host information, full command logs, calibration records,
raw observations, and summaries. The workflow also compiles the full application
test graph and runs checkpoint, restore, failure, and shutdown integration
regressions.

These measurements qualify component construction on synthetic warm fixtures.
They do not measure disk latency, overall save latency, application CPU/energy,
or a change in live playback performance.
