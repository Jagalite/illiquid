# Audio format metadata preparation

The native macOS benchmark reduced median metadata-preparation time by **77.14–99.27% across 13 workloads**. Stable stereo changed from **2,617.4 ns to 19.0 ns per preparation**, saving about 2.60 microseconds within this small component. All selected native regression tests passed. These measurements do not establish a whole-player CPU, battery, or latency improvement.

## Question and scope

Can Illiquid avoid repeating channel-layout description and string formatting for every decoded audio frame while preserving its existing resampler identity and lifecycle?

This experiment measures metadata preparation in `AudioDecoder.convert`: source-field reads, layout-description preparation, signature construction/comparison, and the resulting format-change decision. It substitutes a supplied output-channel count for the device-capacity lookup. Compressed decoding, the capacity lock, resampling, PCM sanitization, queueing, renderer submission, and whole-player CPU or battery use are outside the timed region.

The baseline is commit `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`. The implementation and benchmark were introduced at `935a34fd60994f2ea5572f0e9bd3fc301092f183`; `c127a92f62dbec16d506a1e8a3d05e59402a799f` adds a missing native playback test fixture to the workflow without changing production code, tests, or the benchmark.

## Change

In [`AudioDecoder.convert`](../Sources/IlliquidNativePlayback/Media/AudioDecoder.swift), every converted frame previously allocated a 128-byte C-character buffer, asked FFmpeg to describe its channel layout, decoded that buffer into a Swift string, and interpolated a second string containing the source rate, channel count, layout description, sample format, and output channel count.

The implementation makes two changes:

1. [`AudioSourceFormat`](../Sources/IlliquidNativePlayback/Media/AudioSourceFormat.swift) holds those same five identity fields as an `Equatable` value.
2. `AudioChannelLayoutNameCache` reuses a successful description for native and unspecified layouts when the fields that determine their description are unchanged.

Native layouts use order, channel count, and mask as their key. Unspecified layouts use order and channel count; the inactive union is never consulted. Custom, ambisonic, unknown, and failing layouts continue through FFmpeg's description function. Custom channel IDs and names can change at the same address, so map pointer identity is not a valid cache key.

The signature continues to compare the resulting description string. For example, native stereo and an equivalent unnamed custom layout both describe themselves as `stereo` and retain the same format identity. The existing 128-byte buffer, truncated-success behavior, UTF-8 decoding, and `unknown` error fallback are preserved.

Output capacity is still evaluated for every frame. The ordering of old-format draining, resampler replacement, timing reset, and revision assignment is unchanged. Seeking keeps the existing format revision. The cache retains only scalar values and an owned Swift string.

## Method

The [runner](../Benchmarks/AudioFormatMetadata/run.py) extracts the baseline and candidate preparation blocks from their production source. It stages the unchanged metadata shim functions and C-string conversion helper and compiles the complete candidate helper. Both optimized executables use real FFmpeg `AVFrame` objects and the pinned `libavutil`; FFmpeg behavior is not simulated.

Before timing, a differential pass compares every returned metadata field, layout string, change flag, and cumulative revision across 13,355 preparations. This includes reusing one frame address while its layout changes.

Each of 13 workloads receives six balanced AB/BA pairs, with a fresh process for each observation. Both members use the same iteration count. Input allocation, warmup, and JSON encoding occur outside the timer. Both variants include the same harness loop, result construction, and checksum overhead. Every preparation contributes its source rate, source and output channel counts, revision, and change flag to a checksum; full metadata, including layout and sample format, is also compared in the trace and at the end of each timed pair.

Calibration targets 80 ms for the baseline and at least 5 ms for each variant, using two pilots per variant, the faster pilot rate, and a 2x margin for the minimum. Candidate pilots use 100,000 preparations. Iterations are capped at five million. Actual durations and any observations below the requested minimum are retained independently of the calibration estimate.

The reported values are medians of six wall-time measurements, expressed as nanoseconds per preparation. Ranges and per-pair ratios are retained with the raw samples. Timing is evidence for review rather than a noisy pass/fail speed threshold in CI.

## Native results

The successful [native run](https://github.com/Jagalite/illiquid/actions/runs/39669696852) used macOS 26.6.2 (25G83), an Apple M1 virtual machine, Apple Swift 6.3.3, and the reviewed FFmpeg 8.1.2 SDK with libavutil 60.26.102. Both executables used `-O -whole-module-optimization -swift-version 6`.

| Workload | Baseline (ns/preparation) | Candidate (ns/preparation) | Reduction |
|---|---:|---:|---:|
| Stable mono | 2,554.9 | 18.8 | 99.27% |
| Stable stereo | 2,617.4 | 19.0 | 99.27% |
| Stable 5.1 | 2,405.6 | 18.7 | 99.22% |
| Stable 7.1 | 2,409.0 | 19.0 | 99.21% |
| Stable unspecified layout | 2,421.6 | 18.4 | 99.24% |
| Stable custom layout (uncached) | 3,126.5 | 695.7 | 77.75% |
| Stable ambisonic layout (uncached) | 2,797.8 | 430.5 | 84.61% |
| Sample rate changes | 2,517.4 | 19.4 | 99.23% |
| Sample format changes | 2,438.2 | 18.6 | 99.24% |
| Output channel count changes | 2,405.2 | 18.7 | 99.22% |
| Same-count layout changes | 2,304.5 | 19.3 | 99.16% |
| Native layout changes every frame | 2,318.1 | 237.7 | 89.75% |
| Custom layout changes every frame | 2,881.5 | 658.7 | 77.14% |

All 78 pairs favored the candidate. All 156 observations exceeded the requested 5 ms minimum; the shortest was 9.217 ms. Ordinary change workloads switch every 256 preparations; the two every-frame controls deliberately force frequent misses. The full observed ranges, each paired ratio, calibration pilots, and raw wall/CPU timings are in [the native evidence](../Benchmarks/AudioFormatMetadata/evidence/macos/benchmark/).

An earlier native cohort on the same platform measured 77.72–99.25% reductions, also with all 78 pairs favoring the candidate and all durations above 5 ms. Its benchmark completed, but its later integration-test step exposed an incomplete fixture setup. That [initial run](https://github.com/Jagalite/illiquid/actions/runs/39667422173) is retained separately in [the initial evidence](../Benchmarks/AudioFormatMetadata/evidence/macos-initial/), without pooling the two cohorts.

A supplementary [Linux cohort](../Benchmarks/AudioFormatMetadata/evidence/linux/) used Swift 6.3.2 on x86_64 with the same FFmpeg version and identical production, extracted-block, harness, and runner hashes. It passed parity and helper tests and showed the same direction in all 78 pairs. Two candidate observations were slightly shorter than requested: stable 7.1, pair 5, at 4.967160 ms; and stable custom, pair 4, at 4.932050 ms. The completion receipt flags this; these samples were retained without rerunning the cohort. Native timings are the headline evidence.

## Correctness and native qualification

The successful native job provides the following qualification:

- Exact agreement for all metadata fields, layout strings, format-change flags, and revisions across 13,355 preparations.
- All 10 metadata regression tests pass in both debug and release against real libavutil.
- The complete native app/test graph builds in release, and all 36 selected tests in seven suites pass.
- Decoder/resampler coverage includes EOF draining at 32, 44.1, 48, and 96 kHz; old-format tail preservation during output-channel changes; format revision preservation across seeking; continuous output clocks and real gaps; exact seek trimming; PCM sanitization; and canonical six/eight-channel buffer preservation.
- Multichannel qualification includes paused/muted playback of the generated 7.1 FLAC fixture and route-capacity change revision behavior. Audio-delay tests use the generated H.264/AAC fixture, including extreme offsets, seeking, replacement, and stop behavior.

The metadata regression cases exercise native mask/count invalidation, unspecified layouts without reading their inactive union, custom IDs/names mutating at the same pointer, equivalent native/custom stereo descriptions, 128-byte truncation, ambisonic and invalid-order fallback, string ownership after a frame is freed, and every signature field.

The first workflow generated only `audio-7.1.flac`. `AudioDelayTests` also loads `h264-aac.mp4`: one case returned early when it was absent, while `runtimeDelayReplacementPublishesCommittedValueAndStopWins` failed three expectations while waiting for playback events. Commit `c127a92` adds and verifies the standard H.264/AAC fixture using the existing fixture script's recipe. In the successful rerun, the two fixture-dependent delay cases execute in 0.662 s and 1.036 s and pass. Production code, tests, and benchmark source are unchanged between those native runs. Both logs and qualification receipts are retained.

These are selected regression tests, not the entire repository test suite. Independent source review found no blocking issues and verified that decoder code outside its properties and metadata preparation block is unchanged from the baseline.

## Interpretation

The combined change reduces repeated work within audio metadata preparation. Its contribution to total playback cost depends on frame frequency and the rest of the decoding and rendering pipeline; this experiment does not establish an end-to-end player speedup.

The custom and ambisonic workloads exercise the uncached description path. The every-frame layout-change workloads exercise frequent cache misses. These controls help assess whether the value-type signature remains beneficial when layout descriptions cannot be reused.

## Reproduction

See [the benchmark instructions](../Benchmarks/AudioFormatMetadata/README.md) for prerequisites, commands, workload definitions, and output files. The [native workflow](../.github/workflows/audio-format-metadata.yml) installs the reviewed SDK, runs helper tests in debug and release, executes the paired benchmark, generates real 7.1-channel FLAC and H.264/AAC fixtures, and builds/tests the native app graph.

[Retained evidence](../Benchmarks/AudioFormatMetadata/evidence/) includes raw observations, calibration, source/binary/library hashes, compiler flags, commands, host receipts, and test logs for both native runs and the supplementary Linux run. The full baseline and candidate metadata traces are byte-identical across all three cohorts and are retained once as [`metadata-trace.json.gz`](../Benchmarks/AudioFormatMetadata/evidence/metadata-trace.json.gz), with an uncompressed SHA-256 in [`trace-receipt.json`](../Benchmarks/AudioFormatMetadata/evidence/trace-receipt.json).

The Actions artifacts additionally contain source snapshots, compiled harnesses, and generated media; those artifacts expire after 14 days. The committed evidence and pinned source revisions remain sufficient to inspect the measurements and reproduce the experiment.

