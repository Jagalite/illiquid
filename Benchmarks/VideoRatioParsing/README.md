# Video aspect/crop ratio parsing experiment

[Research findings and qualification status](../../Documentation/VIDEO_RATIO_PARSING_PERFORMANCE.md).

This study compares `VideoPresentationGeometry.ratio` before and after replacing
the temporary `String.split` result array on ASCII input with borrowed substring fields. It
measures the parser directly and the complete geometry initializer that uses it.
Non-ASCII input retains the original Character-based splitting behavior.
It does not measure whole-player CPU, rendering latency, heap allocations, peak
memory, or RSS. Removing an explicit temporary array is a source-level change;
the measured outcomes here are elapsed time and process CPU time.

## Run on native macOS

```sh
python3 Benchmarks/VideoRatioParsing/run.py \
  --pairs 6 --target-ms 150 --minimum-ms 60 \
  --output /tmp/video-ratio-parsing
```

Use a new, empty output directory. Xcode's Swift compiler and native CoreGraphics
are required. The experiment does not resolve the application's dependencies or
require its FFmpeg SDK. On a host with the repository's shared Kyoto queue,
submit the whole command through that queue and add `--inside-kyoto`. The hosted
CI runner has no Kyoto queue; the script reports this before compiling its
isolated packages directly and serially.

`--prepare-only` works without macOS and stages the exact source/test packages
without claiming compilation, execution, or correctness qualification.

The CI workflow runs only on this study's `perf/video-ratio-parsing-*` branches
or manual dispatch. This is a frozen-baseline experiment, not a general PR gate:
future intentional changes to the pinned production sources require a reviewed
rebaseline before this experiment can compare them.

## Source and correctness controls

The frozen baseline is main revision
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. `baseline.json` pins SHA-256 hashes for
all six production files. The runner retrieves their full contents from Git;
the baseline commit must be available locally. Each variant compiles complete,
unmodified copies of `VideoPresentationGeometry`, `PlaybackModels`, `MediaSource`,
`PlaybackPhase`, `NormalizedFileURL`, and `PlaybackTimeInput`. There are no type
stubs or parser rewrites in the harness. All support files must be byte-identical
between variants, and the geometry file may differ only within the ratio
declaration. A changed dependency or pinned baseline causes a failure.

Each temporary Swift package runs the actual repository
`VideoRatioParsingTests.swift` and `PlaybackToolsTests.swift` in both debug and
release. These include authored coordinate expectations and a frozen reference
parser, malformed/Unicode inputs, and seeded mixed strings. The timed libraries
also produce full differential traces before measurements: optional ratio values
and all eight image/clip rectangle coordinates must match bit for bit. Inputs
and complete results are retained, including NaN/infinity representations encoded
as bit strings rather than lossy JSON numbers.

The trace corpus includes scalar and colon forms, signs, decimal/exponent/hex
spellings accepted or rejected by Swift's `Double`, overflow/underflow, zero,
whitespace, Unicode digits and colon lookalikes, combining characters, NULs,
extra fields, boundary-adjacent floating point values, and every Character-boundary
truncation of the ordinary spellings. Another 2,048 seeded mixed strings exercise
the ASCII/Unicode boundary without changing the timed input distribution.
Separate 4 KiB rejection probes are included
without a quadratic collection of their prefixes. Geometry comparisons exercise
both overrides independently and together, nil/fit/fill scale modes, and zero,
negative, nonfinite, subnormal, and extreme finite dimensions. Authored expectations
supplement differential equality so two equally wrong variants cannot satisfy
all checks merely by agreeing.

## Timing method

The driver is compiled separately from each optimized production dynamic library.
The public parser and initializer are not inlinable across that boundary. All
input strings, settings, and geometry fixtures are constructed before warm-up and
timing. Loops rotate 32 prepared inputs, and consume every optional ratio result
or every rectangle coordinate in a checksum. They allocate no result arrays.

Nine scenarios cover nil ratios, scalar ratios, colon ratios, malformed ratios,
and complete geometry with default settings, aspect only, crop only, both
overrides, or invalid overrides. Geometry fixtures mix realistic landscape and
portrait source sizes, varying window bounds, and nil/fit/fill modes. Nil/default
cases are controls: they already avoid splitting in the baseline.

Every calibration and recorded observation starts a fresh process. Both variants
are calibrated to at least the requested 100–150 ms target in **both** CPU and
wall time; the larger iteration count is then used for both. Six or more pairs
alternate baseline/candidate and candidate/baseline order. Both timings must
remain above the requested minimum, at least 60 ms. A short observation fails the
run rather than being silently omitted. Timed checksums must also match.

`summary.json` reports median and minimum/maximum nanoseconds per parser call or
complete geometry construction, plus ratios of the variant medians. CPU and wall
measurements are separate. There is no noisy performance threshold in CI.

The output retains source/test/harness snapshots, exact command arguments and
stdout/stderr receipts, compiler/SDK/platform information, baseline and candidate
traces, calibration observations, all paired measurements, binary hashes, and
the summary. A final stability check rejects changes to the inputs or compiled
artifacts during the experiment. `completion.json` distinguishes preparation
from a completed component qualification; this focused package does not build
or interact with the whole application.
