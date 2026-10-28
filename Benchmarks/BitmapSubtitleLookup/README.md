# Bitmap subtitle lookup and pruning

`BitmapSubtitleTimeline.prune(before:)` must retain the final display set at
or before the cutoff. If the timeline has fewer than two entries, or its second
entry is still after the cutoff, there is nothing to remove. Previously even
these no-op calls reverse-scanned the entire queue of future events.

The candidate checks that necessary removal condition first. No-op pruning is
constant time. Calls that remove entries retain the existing reverse search,
byte accounting and array mutation. Lookup is unchanged, as are generation,
revision, memory limits, leases and copy-on-write behavior.

## Experiment selection

An initial shared binary search for lookup and pruning passed all correctness
tests, but its small-window and near-tail controls regressed. At 128 entries,
first-event lookup improved from 69.30 to 32.41 ns, while penultimate lookup rose
from 11.76 to 31.68 ns. Latest-event lookup also regressed by roughly 1–2 ns.
The broader candidate was rejected; this PR retains only the no-op pruning
optimization. Timing, calibration, environment and test records for that run
are retained in [evidence/exploratory-binary](evidence/exploratory-binary).
Its candidate source and driver are pinned by commit
`6f9d096153d9085d7cc2b64ecd1ced145f3dda68` and the recorded SHA-256 hashes.

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

Twenty-eight workloads cover first, middle, penultimate, latest and missing
lookups at 1/8/32/128 entries; repeated no-op pruning before or within the first
event; and rolling prune/insert/query streams at 2/8/32/128 entries. Static lookup
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
