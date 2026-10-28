# Bitmap subtitle lookup and pruning

The bitmap subtitle timeline is already sorted and bounded to 128 entries by
default. Playback rendering selects the last display set at or before the
current timestamp. Pruning performs the same search to retain the final
preceding set. Both operations previously scanned backward past future entries.

The candidate shares a binary upper-bound search for those two operations.
The newest entry retains a constant-time fast path. Insertion, replacement,
duration expiry, clear events, generation fences, capacity, and lease ownership
are unchanged.

## Reproduce

Requires macOS, Swift 6.1+ and Python 3.10+. Follow the root AGENTS.md requirement
to submit builds through the shared Kyoto queue when it is available.
GitHub-hosted macOS runners lack that queue and execute these isolated builds
serially. Run only one benchmark at a time and use a new output directory.

~~~sh
python3 Benchmarks/BitmapSubtitleLookup/run.py --tests-only \
  --output /tmp/illiquid-subtitle-lookup-tests
python3 Benchmarks/BitmapSubtitleLookup/run.py \
  --pairs 12 --target-ms 40 --max-sample-ms 800 \
  --output /tmp/illiquid-subtitle-lookup-timing
~~~

This reuses the native build and measurement machinery in
`Benchmarks/BitmapSubtitleTimeline/run.py`. The frozen baseline is the complete,
unmodified timeline from main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its SHA-256 is checked before running.

Both variants compile the full timeline and memory-budget sources plus the
complete, unchanged `ASSRenderedRegion` declaration extracted from
`LibassContext.swift`. Only its Foundation/CoreGraphics imports are supplied.
There are no behavioral mocks. The optimized production module is compiled
separately from the driver with `-enable-testing`. The driver cannot specialize
the search for its known fixture timestamps.

## Workloads and checks

| Workload | What it checks |
| --- | --- |
| Empty and newest-entry lookups at 1, 8, 32, 128 entries | Fixed overhead and existing best case |
| Second-newest lookups at 8, 32, 128 entries | Near-tail control where a reverse scan is short |
| Oldest-entry lookups at 8, 32, 128 entries | Lookup across future display sets |
| Middle and before-first lookups at 128 entries | Search boundaries |
| Distributed lookups at 8, 32, 128 entries | Mixed positions, clear sets, and finite-duration expiry |
| No-op pruning at 8, 32, 128 entries | Repeated pruning while future events remain queued |
| Streaming at 8, 32, 128 entries | Prune, insert one future set, and query at fixed occupancy |

A pure lookup iteration performs 64 queries; a pruning iteration performs
64 calls. A streaming iteration advances by its window size, with each step
performing one prune, one insertion, and one query. Summaries report nanoseconds
per query, prune, or complete streaming step respectively. Do not compare these
different operation units as if they were equivalent.

Small immutable bitmap payloads and timelines are constructed outside timing.
Each process warms up three times. Twelve fresh-process pairs alternate AB/BA
order, with the same iteration count and fixture seed in each pair. Calibration
targets 40 ms on the faster variant, bounded at an estimated 800 ms on the slower
one. These are calibration targets; all actual samples are retained. No control
overhead is subtracted.

Before and after timing, complete output receipts are compared with an
independent reverse-scan oracle. They include exact timestamp bits, pixel data,
region geometry, duration, generation, revision, and retained byte counts.
Consumed timed results are also checked. Complete decoded receipts must match
across paired variants. Raw samples, calibration, commands, compiler and host
details, and source/driver/test hashes accompany the results.

The same regression suites run against baseline and candidate in debug and
release with warnings treated as errors. Existing tests cover insertion order,
replacement, duration expiry without resurrecting earlier displays, clears,
signed zero, pruning, invalid input, capacity bounds, copy-on-write behavior, and
real memory-lease lifetime. Additional tests exercise timestamp-search
boundaries across empty, singleton, power-of-two, and non-power-of-two windows.

## Scope

These are warm native component measurements, including the real timeline,
geometry, Data, locks, and memory leases. They do not establish how often a real
file fills the timeline, pipeline-lock contention, full-player CPU use, frame
rate, playback latency, or energy savings. The default 128-entry limit makes
absolute timings and small-window controls essential to interpreting the gain.

## Results

Results will be recorded after native qualification completes.
