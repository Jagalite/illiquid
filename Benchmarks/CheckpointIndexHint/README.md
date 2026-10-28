# Verified checkpoint index: performance research

This experiment compares the complete `PlaybackCheckpoint.record()` operation
against the normalized membership scan introduced by [PR #124](https://github.com/Jagalite/illiquid/pull/124),
pinned at `9f21c84bbe097984642c8fc08b7c8c1fd31a6c41`.

The candidate treats the captured playlist index as a hint. It checks bounds
and normalized file identity before accepting it; otherwise it retains the
normalized scan. Session-record deduplication still runs, so complete construction
remains linear in playlist length. This is a follow-up to #124, not a duplicate
claim for skipping no-folder scans or hoisting source normalization.

## Reproduce

```sh
python3 Benchmarks/CheckpointIndexHint/run.py \
  --pairs 8 --target-ms 40 --output /tmp/checkpoint-index-hint
```

The output directory must be new or empty. `--tests-only` runs the four
baseline/candidate debug/release configurations without collecting timings.
Use a Swift toolchain supporting package tools 6.1 and bundled Testing.

Where Kyoto is available, submit this entire command through the shared queue
described in `AGENTS.md`, then inspect its show/logs/wait receipts. Hosted runners
have no Kyoto mount. The harness serializes builds in separate package directories.

## Method and scope

Both variants use the same six supporting production files. From
`PlaybackSessionStore.swift`, the harness retains the exact complete record and
storage-protocol declarations and excludes the unrelated atomic I/O store.
The declaration bodies and imports remain unchanged; the original full-file
hash and all compiled source hashes are recorded. No mock implementation
replaces a measured production method.

Each optimized driver calls the production checkpoint module across a compilation
boundary without cross-module optimization. Fixtures and record JSON encoding
run outside timing. A deterministic FNV-1a fingerprint compares each complete
warmup record after fixing only its timestamp. Every timed return contributes
to a checked checksum. The independent regression suite compares complete
records and JSON round trips with explicitly labeled identity expectations.

The 23 workloads cover empty/singleton controls, first/middle/last hits,
32/1,000/10,000 items, absent/stale/invalid hints, missing targets, no folder,
Unicode paths, duplicate metadata, remote sources, and unsupported local URLs.
Baseline calibration chooses a shared iteration count per workload. Eight
fresh-process pairs alternate baseline-first and candidate-first order.
All samples are retained; reports include medians, ranges, paired reductions,
and faster-pair counts. Tests and CI have no performance threshold.

Linux results are supplementary component measurements. Native macOS measurements
and the full application test graph are separate CI steps. Neither measurement
includes JSON encoding, disk writes, queue delay, UI latency, or playback FPS.

Raw observations, source/driver copies, compiler/host metadata, executable hashes,
and full command logs are retained in the workflow artifacts. Validated results
will be recorded here after execution.
