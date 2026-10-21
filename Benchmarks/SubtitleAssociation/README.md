# External subtitle association

This benchmark measures the complete ExternalSubtitleMatcher.associate call.
URLs are prepared in memory; no media files are opened. The frozen baseline is
main at a2de305c8dbcaa81aac1477df7c9a0017c14eae3.

## Reproduce

Use Python 3.9+ and matching Swift 6.1+ swift/swiftc tools.

    python3 Benchmarks/SubtitleAssociation/run.py \
      --output /tmp/illiquid-subtitle-association --pairs 8 --target-ms 100

The output directory must be empty. --mode tests selects isolated debug/release
tests for both implementations; --mode benchmark selects parity and timing.
Use --pairs 2 --target-ms 30 for exploration. --cases accepts comma-separated
timing cases while correctness still checks every fixture.
--candidate-matcher supplies an alternate Swift file for controlled experiments;
ordinary qualification uses the production file from the current checkout.

The isolated guard, prefix-slice, and combined alternatives can be regenerated
from the frozen baseline without changing the production file:

    python3 Benchmarks/SubtitleAssociation/explore.py \
      --output /tmp/illiquid-subtitle-alternatives --pairs 4 --target-ms 75

These shorter exploratory campaigns are separate from final qualification.

## Workloads

| Cases | Media URLs | Subtitle input |
| --- | ---: | --- |
| one_to_one_1/16/256/1024 | 1, 16, 256, 1,024 | One exact episode subtitle each |
| two_subtitles_16/256 | 16, 256 | Main and forced subtitles, exercising the two-element sorter |
| multilingual_16/256 | 16, 256 | Six language/forced subtitles each, deliberately unsorted |
| sparse_1024 | 1,024 | Eight subtitles |
| unrelated_1024 | 1,024 | 1,024 unrelated supported subtitles |
| unsupported_1024 | 1,024 | 1,024 unsupported text files |
| empty_0/16/1024 | 0, 16, 1,024 | Empty subtitle array |
| broad_prefix_256/1024 | 256, 1,024 | Eight generic subtitles, all ambiguous |
| unicode_256 | 256 | Decomposed accents and Japanese title text |

Normal folder discovery prefilters unsupported extensions; that case tests the
public API. The frequency of large and broad-prefix inventories is unknown.

## Method and correctness

Each implementation is compiled into a separate optimized production library,
using the complete matcher and its real helpers. The separately compiled driver
cannot inline the matching implementation. One iteration includes association,
result-count consumption, and result destruction. Fixture creation, warmup,
full-output verification, and serialization are outside timing. Nothing is
subtracted from measurements.

Every timed fixture and nine edge fixtures has an independently constructed
expected URL-to-subtitle mapping. The ordering oracle implements the public
Foundation comparison contract without calling the production sorting helper.
All 26 fixtures also run with reversed input arrays: 52 complete output records
are checked for each implementation and compared across implementations.
Count checksums are only an additional timed-consumption check.

Tests include ambiguity, Unicode specificity, duplicate inputs, release and
language qualifiers, original URL keys, natural ordering, task cancellation,
and a checkpoint-by-checkpoint cancellation sweep over mixed empty, singleton,
and multiple-subtitle results.

Measurements use fresh processes, serial balanced AB/BA pairs, four warmup calls,
and the same iteration count within each pair. A baseline CPU-time pilot
calibrates work toward --target-ms; faster candidates can have shorter intervals.
Both elapsed and process CPU time are recorded. Summaries retain paired ratios,
ranges, and faster-pair counts; no sample is discarded and timing percentages
are not a CI pass/fail threshold.

## Evidence and limits

All compiled sources, tests, and drivers are staged before use. Receipts include
source hashes, compiler/platform metadata, compiler and build-product hashes,
commands, test/build logs, complete association outputs, calibration results,
every raw measurement, and summary JSON. Each measurement records Swift's locale.
Keep the complete output directory or CI artifact when reporting a campaign.

These measurements cover in-memory subtitle association after URL preparation.
They do not establish total folder-open latency, filesystem I/O, playback CPU,
frame rate, memory use, or battery life. The macOS workflow supplies target-platform
component evidence; the separate complete-app CI suite supplies integration checks.
