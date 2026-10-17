# Empty external-subtitle association

This experiment measures the complete ExternalSubtitleMatcher.associate call.
When the subtitle list is empty, the dictionary initialized with each media URL
and an empty array is already the final result. The candidate checks cancellation
once more and returns that dictionary, skipping filename tokenization, token
index construction, and sorting empty association lists.

## Reproduce

Use one Swift 6.1+ toolchain for swift and swiftc, and Python 3.9+:

```sh
python3 Benchmarks/EmptySubtitleAssociation/run.py \
  --output /tmp/illiquid-empty-subtitle-association --pairs 6
```

The output directory must be empty. Use --mode tests for only regression tests
or --mode benchmark for full association parity and measurements. There are no
downloaded package dependencies. The native workflow uses macOS 26 / Xcode 26.6.

## What is measured

The baseline consists of the three exact production files at
68274d1b09dcc866296321a5a8858efc297c4f19. Their Git blob identities are checked
before compilation. The candidate uses the complete current production files.
Each variant is built as a separate optimized IlliquidCore library, and the
same driver is compiled separately against it. Both use
-swift-version 6 -O -whole-module-optimization.

One timed iteration runs a complete association call and consumes the result's
media-key count and total subtitle count. That consumption and loop overhead
are included. Fixture construction, full-result serialization, oracle checking,
warmup, and JSON encoding are excluded; nothing is subtracted from the timer.

The matrix covers zero, one, 16, 256, and 4,096 media URLs with an empty subtitle
array, including Unicode and longer path fixtures. Nonempty supported-subtitle
and unsupported-subtitle arrays at 16 and 256 media URLs are controls. Full
association records are compared between implementations before timing; empty
cases also have an independent dictionary-key/empty-array oracle.

Each scenario uses fresh baseline and candidate processes in six balanced AB/BA
pairs. Timing is serial. A baseline process-CPU pilot calibrates toward 150 ms;
both variants use identical iteration counts, rounded to multiples of 16.
Wall and process CPU times, all observations, paired ratios, and ranges are
retained. No timing outlier is discarded, and performance is not a flaky CI gate.

## Correctness

The isolated package runs the existing matcher suite and new empty-subtitle
regressions against baseline and candidate in both debug and release. The new
tests cover empty and duplicate input, preservation of unsupported media keys,
and cancellation before, during, and after dictionary initialization. Observed
cancellation must discard every association. Eliminating work intentionally
reduces the total number of cancellation polls; their exact count is not an API
guarantee.

Full association parity checks exact media URL keys and ordered subtitle arrays.
The measured count checksums must agree with preflight and the paired variant.
Counts alone are not the full correctness oracle.

## Evidence

The runner retains frozen and candidate sources, harness/test inputs, source
hashes, all four test logs, complete parity records, calibration, raw timings,
summaries, and command receipts. The workflow packages the entire result
directory as a ZIP, publishes its SHA-256, and uploads it as an artifact.
A portable copy is also emitted in chunked base64 in the qualification log so
the exact archive can be preserved without rebuilding or altering its contents.

The research report records the accepted native results and controls. These
component timings do not measure total folder-scan latency, filesystem I/O,
playback FPS, memory use, or battery life. The fast path remains linear because
the public API returns an entry for each distinct media URL.
