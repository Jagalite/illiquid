# External subtitle conversion performance

**Date:** October 17, 2026

**Baseline:** `68274d1b09dcc866296321a5a8858efc297c4f19`

**Scope:** Complete in-memory SRT/WebVTT-to-ASS conversion after text decoding.

## Decision

Keep a small ASCII fast path for cue escaping in
[`ExternalTextSubtitleConverter.swift`](../Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift).
It replaces three Foundation replacement passes per caption line and the intermediate
line array with a byte buffer that also inserts the ASS line separators. Any non-ASCII
payload byte restarts that cue through the exact previous Foundation implementation.
The timestamp parser, cue selection, WebVTT metadata handling, errors, and output
format are unchanged.

On the measured Linux host, ordinary 1,000–10,000-cue ASCII files take **21.3–26.7%
less conversion time** (1.270–1.364× throughput). The 10,000-cue SRT case falls from
207.2 ms to 151.9 ms, and WebVTT from 229.4 ms to 175.5 ms. The escape-dense stress
case improves 5.096×. Unicode controls, including a long ASCII prefix with Unicode
only at the end, have overlapping timing ranges; their medians range from 0.8%
slower to 0.5% faster.
These results support the focused change; they do not establish a playback FPS,
energy, file-opening, or renderer improvement.

## Why this work is on the import path

[`SubtitlePipeline.prepareExternalData`](../Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift)
passes decoded `.srt` and `.vtt` text through this converter before constructing the
ASS data. Both file input and converted output have the existing default 32 MiB
limit. The previous implementation escaped every cue line using successive
`replacingOccurrences` calls for backslash, opening brace, and closing brace,
then joined the resulting strings with `\N`. That work repeats with the number
and length of captions.

The benchmark measures the actual full converter, including newline normalization,
block parsing, timestamp parsing/formatting, text escaping, and output assembly.
It does not time an extracted escaper or substitute a simplified parser.

## Compatibility finding and rejected experiment

An initial unrestricted UTF-8 pass was rejected by the new tests before performance
measurement. For a left brace followed by U+0301 COMBINING ACUTE ACCENT, the old
Foundation replacement leaves the brace unescaped; an unconditional byte pass adds
a backslash. The 256-cue compatibility corpus produced 23,386 baseline bytes versus
23,424 candidate bytes, in both SRT and WebVTT.

Foundation's default search observes composed character sequences; replacing it
with byte matching would change existing behavior. See Apple's
[string-search documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Strings/Articles/SearchingStrings.html).
The accepted code therefore optimizes only entirely ASCII cues and preserves the
old Foundation operations for every cue containing non-ASCII text. This keeps
platform-specific Unicode search behavior with its existing implementation.

The [rejected patch](../Benchmarks/ExternalSubtitleConversion/experiments/rejected-unrestricted-utf8.patch)
applies to the frozen baseline; the [failure receipt](../Benchmarks/ExternalSubtitleConversion/experiments/rejected-unrestricted-utf8.json)
records the source/test hashes and the first mismatch. Do not apply that experiment
to production. The added regression corpus prevents it from being reintroduced.

## Final Linux measurements

Swift 6.3.2, `x86_64-unknown-linux-gnu`, Ubuntu 24.04, Intel Xeon Platinum 8573C.
Timed subprocesses were pinned to allowed CPU 0. Both source variants use the
same `-O -whole-module-optimization -swift-version 6` build and driver.

The table reports **milliseconds per complete conversion**, as median (minimum–maximum),
from six samples per variant. All completed observations are retained. Speedup is
the ratio of medians, not a per-sample maximum or a whole-application claim.

| Workload | Baseline ms | Candidate ms | Speedup |
| --- | ---: | ---: | ---: |
| `srt-short-1` | 0.0262 (0.0256–0.0266) | 0.0177 (0.0175–0.0184) | 1.478× |
| `srt-short-1000` | 20.2217 (19.6852–20.6024) | 15.1035 (14.6977–15.3002) | 1.339× |
| `srt-short-10000` | 207.1737 (203.3157–210.7351) | 151.9424 (151.1856–160.2496) | 1.364× |
| `vtt-short-1` | 0.0341 (0.0333–0.0351) | 0.0258 (0.0253–0.0262) | 1.324× |
| `vtt-short-1000` | 25.4367 (25.1442–26.1063) | 20.0268 (19.7592–20.7299) | 1.270× |
| `vtt-short-10000` | 229.4246 (227.5056–270.9479) | 175.4735 (173.4328–208.4115) | 1.307× |
| `srt-unicode-1000` | 57.5625 (56.8824–58.0266) | 58.0195 (57.2564–59.1449) | 0.992× |
| `vtt-unicode-1000` | 56.8887 (56.2694–57.3696) | 56.6198 (55.9415–58.4619) | 1.005× |
| `srt-long-128` | 190.9979 (189.4120–192.8188) | 118.2422 (116.3579–121.7319) | 1.615× |
| `srt-long-late-unicode-128` | 223.5057 (220.3539–228.3096) | 225.1440 (222.4411–236.9839) | 0.993× |
| `vtt-escape-dense-1000` | 413.4094 (401.5579–419.8353) | 81.1211 (79.7954–84.2649) | 5.096× |

The short-caption cases use synthetic ordinary English text. The Unicode cases
include accents, decomposed marks, Japanese, Arabic, emoji, paths, and ASS-looking
literals. `srt-long-128` has about 8 KB of ASCII per cue; the late-Unicode control
adds `é` at the end of each long line. The escape-dense case deliberately contains
many braces and backslashes and is a stress case, not a representative subtitle
mix. Its larger result must not stand in for ordinary caption performance.

Process CPU time agrees with wall time: ordinary 1,000–10,000-cue cases improve
1.274–1.363×, and the escape-dense case improves 5.094×. Unicode controls are
approximately 0.992–1.005× in wall time; their overlapping ranges do not establish
an improvement. A preliminary two-sample run had small Unicode slowdowns of about
1–2%; that exploratory run was not used for the table.

An earlier six-round cohort was excluded in full after independent review found
two missing records in its saved measurements and command receipts. The cause was
not established, and no missing values were reconstructed. The
[incomplete evidence and original runner](../Benchmarks/ExternalSubtitleConversion/experiments/incomplete-linux/)
are retained separately. The table above uses a fresh complete cohort collected
after adding atomic finalization and saved-record integrity checks.

## Correctness and measurement protocol

Both the frozen baseline and accepted candidate pass all **19 regression test
functions in debug and release** (four passing runs), with warnings treated as
errors. The existing parameterized cases exercise malformed timestamps, numeric
bounds, signatures, comments, metadata identifiers, line endings, and cue recovery.
Four added test groups cover exact delimiter escaping, empty/trailing line behavior,
Unicode byte preservation, and the deterministic 256-cue compatibility corpus in
both formats. Tests compare UTF-8 bytes where normal Swift String equality could
hide normalization differences.

The separate driver compares full successful output bytes and typed errors for
**411 fixtures: 383 successful conversions and 28 expected errors**. These include
all 11 timed workloads and 400 additional authored/generated fixtures. Both
verification receipts are byte-identical, including their input bytes.

For timing, input generation, process startup, verification, warmup, and JSON output
are outside both clocks. A non-inlined conversion function observes each returned
String's UTF-8 count and first/last byte; its sink is printed and compared between
variants. String lifetime and that small sink are inside the measurement. Iteration
counts are calibrated with the baseline and shared by both variants. Fresh process
pairs alternate AB/BA over six rounds, while workload order rotates. This gives
three pairs in each order for every workload. There is no flaky timing threshold.

Before writing the final summary, the runner atomically writes and rereads the
complete measurement and command receipts. It checks every expected
case/round/variant/order identity, matches measurement rows to command output, and
compares paired iteration counts, inputs, and sinks. This run retains **132
measurements and 152 command receipts**; the summary records SHA-256 hashes of
both receipt files. Independent review also recomputes the reported medians.

The [committed evidence](../Benchmarks/ExternalSubtitleConversion/evidence/linux/)
includes source/driver/executable hashes, compiler and environment details, raw measurements,
commands, calibration, exact-output receipts, summaries, and four passing test logs.
The retained baseline has both its original Git blob and SHA-256 checked before
each run. The accepted source and test hashes match the recorded measured/tested
inputs. The two complete verification receipts were identical, so only the baseline
copy is committed; both original receipt hashes remain in `verification.json`.

## Reproduce and qualify on macOS

```sh
# Existing isolated tests compile the actual converter without native SDK dependencies.
bash Scripts/test-external-subtitle-regressions.sh --jobs 2 --no-parallel -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh --jobs 2 --no-parallel -c release -Xswiftc -warnings-as-errors

# Exact-output verification and balanced before/after measurements.
python3 Benchmarks/ExternalSubtitleConversion/run.py \
  --output /tmp/illiquid-external-subtitle-results --samples 6
```

Use `--swiftc /path/to/swiftc` for an explicit compiler and `--cpu N` for optional
Linux affinity. Output directories must be new or empty. The benchmark requires
Swift 6.1+ with Foundation and Python 3.10+, and performs no network downloads.
See the [benchmark README](../Benchmarks/ExternalSubtitleConversion/README.md).

The new [macOS workflow](../.github/workflows/external-subtitle-performance.yml)
runs the actual converter tests in debug/release and the same complete comparison
on `macos-26` with the repository's pinned Xcode 26.6 path. The existing restoration
workflow also exercises the converter and runs the native release suite on PRs.
Native CI results are reported in the pull request; the table above is Linux data.

No full macOS application was executed locally. These component measurements do
not cover disk I/O, encoding detection, libass loading/rendering, visible playback,
allocation counts, or peak memory. Unicode fallback may perform some discarded
ASCII-buffer work before encountering its first non-ASCII byte; the late-Unicode
timing control covers that latency shape, not every possible file or memory peak.
