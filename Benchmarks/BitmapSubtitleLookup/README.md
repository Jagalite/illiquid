# Bitmap subtitle lookup and pruning

`BitmapSubtitleTimeline` stores sorted, distinct finite event timestamps, but
`composition(at:)` and the cutoff selection in `prune(before:)` reverse-scanned
the array. A queued future display set is visited on every lookup until the
current display is found, even when the resulting subtitle image has not changed.

The candidate shares an upper-bound search between those operations. It checks
the newest entry first to preserve constant-time selection of the latest display
and the common one-entry timeline. The remaining search is logarithmic. Removing
old entries and updating retained-byte accounting still take linear work when
pruning actually removes entries; this change only reduces the cutoff search.

No new index, cache or mutable state is introduced. Selection still happens
before expiration checking, so an expired display or an empty clear event cannot
resurrect an older caption. Generation, revision, byte limits, memory leases and
copy-on-write behavior are unchanged.

## Production context

`SubtitlePipeline.renderedFrame` looks up bitmap events under its lock after its
same-millisecond/geometry cache check. `MediaSession.subtitleDemuxLoop` prunes
main and Picture in Picture pipelines before processing each selected subtitle
packet. Bitmap pruning has no extra five-second throttle. The default read-ahead
window is 30 seconds, and the pruning cutoff is 30 seconds behind playback.
Consequently a timeline may contain both recent history and future events.

The hard limits are 128 events and 32 MiB of pixel data per timeline. The benchmark
occupancies are synthetic coverage of that range; they are not measurements of
typical subtitle traffic. A 128-entry window is possible only while its payloads
also fit the byte limit.

## Reproduce

Requires macOS, Swift 6.1+ and Python 3.10+. No FFmpeg, libass, media fixtures or
application launch is needed. Follow the repository's Kyoto build coordination
when that queue is available. The isolated GitHub-hosted macOS runner has no
Kyoto project and compiles these components directly.

```sh
python3 Benchmarks/BitmapSubtitleLookup/run.py --tests-only \
  --output /tmp/illiquid-bitmap-lookup-tests
python3 Benchmarks/BitmapSubtitleLookup/run.py \
  --pairs 8 --target-ms 80 --max-sample-ms 1500 \
  --output /tmp/illiquid-bitmap-lookup-timing
```

Use an empty output directory per attempt and run one benchmark at a time.

The frozen baseline is the complete production timeline from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, including the earlier insertion
optimization. Its SHA-256 is verified before building. Both variants compile the
complete timeline and memory-budget sources and the exact `ASSRenderedRegion`
declaration extracted from `LibassContext.swift`. Geometry, `Data` and leases use
their real types. The optimized production module is compiled separately from
the benchmark driver, so its implementation cannot specialize to fixture values.

## Protocol and validation

Twenty-seven workloads cover first, middle, penultimate, latest and missing
lookups at 1/8/32/128 entries; repeated no-op pruning before or within the first
event; and rolling prune/insert/query streams at 8/32/128 entries. Static lookup
and prune cases perform 32 operations per iteration. Stream results are per
transition, including one prune, insertion and lookup. The receipt records those
operation counts explicitly. Timestamp spacing is 30 seconds divided by window
size, keeping a filled window within the default look-ahead span. The first
event starts at 60 seconds so missing-event and prune cutoffs remain positive.
Penultimate lookup deliberately selects an empty clear event. The stream's
operation ratio is synthetic and does not model rendering or packet cadence.

The same driver exercises both variants. Payload setup and complete result
verification occur outside timing. It consumes timed results in a checksum and
checks complete timeline receipts, including timestamp bit patterns, payloads,
generation, revision and retained bytes. Baseline and candidate receipts and
checksums must agree for every pair.

Eight fresh-process pairs alternate baseline/candidate order. Each pair uses
the same iteration count and fixture seed. Calibration targets 80 ms on the
faster variant, bounded by an estimated 1.5 seconds on the slower variant.
Every actual timing sample is retained. No control time is subtracted.

The output includes raw measurements, calibration records, test logs, source and
binary hashes, compiler commands, and host details. The workflow also uploads
the complete output as an artifact and emits an exact compressed bundle in the
job log for durable review capture.

The same ordering and memory-budget tests run against both sources in debug and
release with compiler warnings treated as errors. Added boundary tests cover
empty and 1/2/3/8/32/127/128-entry windows; every event's immediately preceding,
exact, and immediately following representable timestamps; NaN and infinities;
pruning from pristine value copies; finite, indefinite and clear events. Existing
tests cover independent randomized oracle comparisons, signed zero, out-of-order
delivery, replacement, capacity, stale generations and real lease lifetimes.

## Results and limits

Native results will be recorded after branch qualification completes.

These are warm component measurements. They do not measure subtitle traffic
frequency, lock contention, decoding, GPU rendering, frame rate, whole-player CPU,
memory footprint or energy. Absolute timings and newest/near-tail controls matter
alongside percentage improvements in large queued windows.
