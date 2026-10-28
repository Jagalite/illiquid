# Episode display formatting in media-row construction

This compares production code with `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Only `MediaNameRecognition.swift` may differ. The existing source-tree snapshot
helper supplies complete production files and guarded verbatim model declarations;
source and extraction hashes identify every compiled byte. There are no model
stubs. macOS uses unchanged sources and native Foundation. Linux changes only the
Darwin and FoundationXML imports in sidecar support code and records those changes.

```sh
python3 Benchmarks/MediaDisplayNameProjection/run.py \
  --output /tmp/media-display-projection --pairs 10 --target-ms 100
```

Follow the repository's Kyoto build coordination when its queue is available.
Use an empty output directory. `--verify-only` compiles both variants and compares
complete output without timing. `--cases` and `--sizes` select explicitly reported
workloads; defaults are all five cases at 100 and 1,000 input files. Swift 6.1 or
newer is required, without media dependencies or network downloads.

## Boundaries

The principal interval calls complete `SourceTreeProjectionInput.rows()`,
including production date sorting, path processing, context labels, display
strings and row allocation. It excludes directory enumeration, sidecar reads,
file opening, SwiftUI work and playback. Fixture creation, a full warmup,
complete output encoding and validation occur outside the timer. The previous
result stays alive until its replacement returns, as in a caller still displaying
old rows. Wall and process CPU time are both recorded.

- `precomputed_episodes` supplies recognized metadata before timing, matching
  the recursive metadata loader's handoff to row construction.
- `unprepared_episodes` leaves recognition to the production row builder, so
  recognition and display formatting are both timed.
- `mixed_library` supplies precomputed episodes, movies, dated episodes, extras
  and unknown files.
- `movies_control` exercises row construction without episode formatting.
- `cached_projection_control` primes a real `SourceBrowserFilter` actor and
  measures repeated complete `project(input:)` calls with unchanged input.
  Its counters must remain at one tree/visibility build. This path reuses the
  display names, so the change is not expected to improve it.

The row cases use the production default sorting configuration: creation date
descending, with name and type sorting off. Each timed process validates its
full final result against the baseline trace, including exact UTF-8 bytes,
metadata, IDs, order, visibility and projection outputs. The runner uses balanced
AB/BA pairs with fresh processes, calibrates equal iteration counts against the
faster variant, and retains every pilot and final observation. The summary reports
all paired changes and absolute timing ranges. These synthetic component timings
do not measure whole-sidebar or player latency.

## Evidence

`environment.json`, both source manifests, snapshots, compiler/process logs,
complete verification traces, calibration, measurements, summary and completion
receipt are retained under the output directory. Production, staged and driver
source hashes and binary hashes are rechecked before success. The script performs
no tests of its own; run the [display-name qualification](../MediaDisplayName/README.md)
and existing browser/metadata regressions alongside this comparison.
