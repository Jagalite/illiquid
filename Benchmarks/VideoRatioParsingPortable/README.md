# Portable video-ratio parser qualification

[Research findings and retained evidence](../../Documentation/VIDEO_RATIO_PARSING_PERFORMANCE.md).

The workflow runs on the study's `perf/video-ratio-parsing-*` branches or manual
dispatch. Its frozen source checks are specific to this experiment, so it is not
a gate for unrelated future pull requests.

This companion experiment measures only the production
`VideoPresentationGeometry.ratio` function on a host with Swift 6. It provides
parser evidence while native macOS runners are unavailable. It does not replace
the native [VideoRatioParsing](../VideoRatioParsing) experiment: no CoreGraphics
types are emulated, no geometry code is compiled, and no whole-application or
repository test-suite qualification is claimed.

```sh
python3 Benchmarks/VideoRatioParsingPortable/run.py \
  --pairs 6 --target-ms 150 --minimum-ms 60 \
  --output /tmp/video-ratio-parsing-portable
```

Use a fresh output directory. `swiftc` must be on `PATH`; Linux and macOS are
supported. `--prepare-only` stages and validates the source extractions without
compiling or executing anything. On a machine with the shared Kyoto queue,
submit the whole command through it and add `--inside-kyoto`. Other hosts report
the unavailable queue before serial, isolated compilation.

## Exact source subset

The complete old production file is retrieved from main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` and verified against
`../VideoRatioParsing/baseline.json`. The complete current file must match the old
file outside the ratio declaration. Unique ordered declaration boundaries select
the **verbatim** static function in each variant. The only wrapper is a public
`VideoPresentationGeometry` enum and `import Foundation`; the function body,
signature, arithmetic, and Swift `Double` calls are unchanged.

The native experiment's `Driver.swift` supplies verbatim excerpts containing its
scalar/colon/invalid fixtures, optional-value bit encoder and complete parser
corpus, ratio timing loop, and authored expected checks. Marker mismatches stop
the run. The portable client adds timing, invocation, and JSON output only.
Receipts retain hashes and snapshots of the full production files, full native
driver, exact extracted declarations/fragments, generated wrapper/support files,
and portable driver. No substring conversion or numeric grammar is replaced in
the measured function.

Before timing, baseline and candidate must produce identical complete optional
`Double` bit traces on the native study's parser corpus. This includes decimal,
exponent and hexadecimal spellings, malformed inputs, Unicode, embedded NULs,
ordinary-input truncations, extra fields, boundary-adjacent values, extreme
operands, and long rejection probes. The native study's authored parser
expectations also run in each binary. These are component checks, not execution
of the macOS geometry tests or the repository's Swift Testing suites.

## Measurements and limits

Each exact parser subset is built into a separate optimized dynamic library. The
driver is compiled separately without cross-module optimization, so the public
parser body is unavailable for caller inlining or input folding. All 32 inputs
for each scenario are prepared before warm-up/timing; every result contributes
its optional value's bits to the native study's checksum loop.

Four scenarios cover nil, scalar, colon, and malformed inputs. Nil is a control:
the previous implementation already skips splitting it. Each calibration and
observation starts a fresh process. Both variants calibrate to at least the
requested 100–150 ms target in CPU and wall time; the larger iteration count is
used for both. Six or more pairs alternate AB/BA order. Every observation must
exceed the requested minimum of at least 60 ms in both clocks, and paired
checksums must agree. All measurements are serial.

`summary.json` reports separate CPU/wall median and range in nanoseconds per call
and ratios of medians. The output also retains compiler/platform details,
complete verification traces, calibration, raw measurements, command outputs,
source and binary hashes, and a completion receipt. Inputs, generated sources,
and compiled artifacts are checked for changes before completion.

Results describe the recorded host and Swift toolchain's parser subset only.
They do not establish native macOS geometry performance, frame rate, whole-player
CPU savings, allocation counts, or RSS. Removing the temporary split-result array
from the ASCII path is a qualitative allocation change; non-ASCII input keeps
the original splitting behavior. This runner measures time.
