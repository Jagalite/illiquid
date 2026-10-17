# Bitmap subtitle timeline insertion

Every accepted bitmap subtitle event previously searched for a duplicate,
removed/reappended replacements, and sorted the timeline. The timeline is
already ordered and bounded to 128 events by default. The candidate appends
strictly newer timestamps directly and otherwise uses one lower-bound search
for ordered insertion or in-place replacement.

`SubtitlePipeline` performs this work under its lock. Main and Picture in Picture
pipelines each own a timeline. Timestamp lookup and pruning are unchanged.

## Reproduce

Requires macOS, Swift 6.1+ and Python 3.10+. The component harness needs no FFmpeg,
libass, media fixtures or application launch. Use an empty output directory per
attempt and run one benchmark at a time.

```sh
python3 Benchmarks/BitmapSubtitleTimeline/run.py --tests-only \
  --output /tmp/illiquid-timeline-tests
python3 Benchmarks/BitmapSubtitleTimeline/run.py \
  --pairs 8 --target-ms 80 --max-sample-ms 1500 \
  --output /tmp/illiquid-timeline-timing
```

The frozen baseline is the complete production timeline from main commit
`68274d1b09dcc866296321a5a8858efc297c4f19`. Its source hash is checked before
running. Both variants compile the entire timeline and memory-budget files plus
the complete, unchanged `ASSRenderedRegion` declaration extracted from
`LibassContext.swift`. Only the declaration's Foundation/CoreGraphics imports
are supplied by the harness. Geometry, `Data`, locks and memory leases use their
real types; there are no behavioral mocks.

The optimized production module is built separately from the driver, with
`-enable-testing` exposing the existing internal API to `@testable import`.
The compiler cannot specialize that module for the driver's known fixtures.

## Protocol

Twelve workloads cover chronological fills at 1, 8, 32 and 128 entries; reverse
and shuffled fills; replacements throughout full 32/128-entry windows; mixed
insert/query/prune streams; and rejected insertions at the entry limit. Event
payloads are prepared outside timing. Fills include resetting the timeline;
stream results include their declared queries/prunes. Results are reported per
attempted insertion, with operations per cycle recorded explicitly.

The driver warms each workload before timing and verifies complete timeline
receipts outside timing. Receipts capture presentation results, timestamp bit
patterns, generation, revision and retained bytes. Paired receipts and consumed
checksums must agree.

Eight fresh-process pairs alternate baseline/candidate order. Both variants use
the same iteration count and fixture seed within each pair. Calibration aims
for 80 ms on the faster variant, capped at an estimated 1.5 s on the slower
variant. These are calibration targets, not hard duration limits; every actual
sample is retained. No timing samples are discarded and no control is subtracted.

Raw observations, source/test/driver/executable hashes, compiler commands and
host information accompany the summaries. The same regression tests run against
baseline and candidate in debug and release with warnings treated as errors.
The tests cover ordering, replacement, signed zero, capacity/byte limits,
rejection atomicity, stale generations, clear/finite/indefinite events, pruning,
resetting, copy-on-write values and real memory-lease lifetimes.

## Interpretation

These are warm native component measurements. They do not measure the frequency
or occupancy of real subtitle traffic, pipeline-lock contention, decoding,
bitmap expansion, GPU work, frame rate, whole-player CPU, memory footprint or
energy. Payload preparation and full result serialization are outside timing.
Default timelines are bounded to 128 entries, so the absolute savings and
smaller-window controls matter alongside percentage reductions.

Native results will be recorded after branch validation completes.
