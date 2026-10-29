# External subtitle conversion benchmark

This benchmark measures complete SRT and WebVTT conversion through the real
`ExternalTextSubtitleConverter`. It compares the production source with the
frozen version from `main` at `68274d1b09dcc866296321a5a8858efc297c4f19`.
The baseline manifest records its original path, Git blob, and SHA-256.

For the incremental [newline normalization study](../../Documentation/SUBTITLE_NEWLINE_NORMALIZATION_PERFORMANCE.md),
select the current-main baseline explicitly:

```sh
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --rounds 8 --target-ms 120 --output /tmp/subtitle-newlines
```

The optional `--baseline-ref` resolves a Git revision once and records the exact
source bytes, commit, Git blob, and SHA-256. Omitting it preserves the frozen
historical comparison. To run the current tests against that same revision, pass
`--baseline-ref REVISION` as the first option to
`Scripts/test-external-subtitle-regressions.sh`, followed by the usual Swift test
options. The ordinary invocation tests the working-tree converter.

## Reproduce

Use a Swift 6.1-or-newer toolchain. The component is Foundation-only and needs
no FFmpeg, libass, renderer, media file, or application launch.

```sh
bash Scripts/test-external-subtitle-regressions.sh -c debug -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/ExternalSubtitleConversion/run.py verify --output /tmp/subtitle-verify
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --rounds 10 --target-ms 100 --output /tmp/subtitle-benchmark
python3 Benchmarks/ExternalSubtitleConversion/run.py summarize --output /tmp/subtitle-benchmark
```

Output directories for `verify` and `benchmark` must be new or empty.
`summarize` reads an existing completed cohort and revalidates its order and
receipts. `SWIFTC` or `--swiftc` selects the compiler. The test script uses
`swift` from PATH; select it from the same toolchain. Linux packages may need
their standard runtime library search path. On restricted Linux hosts the
test script accepts `--use-integrated-swift-driver` and SwiftPM cache paths.
The macOS workflow selects the same Xcode 26.6 environment as existing suites.

A quick exploratory run can select cases; these short runs do not establish a
performance result:

```sh
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --rounds 2 --target-ms 30 --case srt-2000-plain \
  --case srt-2000-unicode-escaped --output /tmp/subtitle-smoke
```

## Workloads and correctness

The 50 timed cases cover both formats, 1/100/2,000/10,000 cues, plain ASCII,
multilingual text, ASCII escapes, CRLF/CR/BOM handling, empty input, invalid
cues, and Unicode-plus-escape fallback controls. All fixtures are synthetic;
input construction is outside timing. A 2,000-cue fixture is useful for a
dialogue-heavy title; the 10,000-cue case exercises longer material. The current
matrix adds eight plain/multilingual CRLF cases at those sizes, two CR-only
2,000-cue cases, and four almost-ASCII CRLF cases whose first non-ASCII
character occurs at the end. Historical retained evidence uses the original 36 timed cases
and 1,698 differential cases; those results are unchanged.

Before timing, the runner compares full input/output UTF-8 bytes and exact
typed conversion errors in 5,222 cases. The original escaping corpus includes
every sequence of length zero through three over nine selected atoms in both
formats, plus Unicode/normalization edges, compatibility punctuation, NUL,
literal ASS commands, empty payloads, and trailing newlines. An additional
3,510 newline cases cover every sequence of length zero through three over
CR, LF, ASCII, combining marks, ZWJ, a variation selector, NUL, and non-ASCII
text in three placements and both formats. Their expected parsing outcome
comes from the separately compiled baseline; it is not guessed or obtained by
passing pre-normalized input through the candidate. Swift String equality is not
used for byte parity, since it accepts canonical equivalence.

The standalone script also runs the existing timestamp/parser tests and eight
independent escaping tests from the normal native test target. The tests cover
the established Foundation behavior around combining marks. A raw byte
replacement for every Unicode line is deliberately not used.

## Timing protocol

Each complete converter is compiled into a separately optimized module with
`-O -whole-module-optimization -swift-version 6 -warnings-as-errors`.
The same driver is then compiled against it through `@testable import`;
there is no cross-module optimization or replacement parser.

The runner calibrates one operation count per case using the baseline and
uses that count for both implementations. Ten fresh-process pairs alternate
AB and BA, with five of each order for every case. Case traversal reverses
each round. Measurements run serially. The incremental newline study uses
eight pairs (four AB and four BA) at a 120 ms calibration target. No
observations are removed. The saved-record recovery in the historical study
is documented separately in its original research report.

Each process prepares its fixture, converts it once for warmup and output
validation, then times complete conversions and consumption of the returned
UTF-8 byte count. Parsing, escaping, event construction, and output construction
are included. Input generation, full byte comparisons, hashing, and JSON
serialization are excluded. CPU time and monotonic elapsed time are recorded.
A checked iteration checksum consumes every result; complete outputs are
verified again after timing.

Summary generation validates all 1,000 observations in the default ten-pair
run (800 in the eight-pair newline study), exact pair order, operation
counts, checksums, output fingerprints, and durations. It retains individual
paired ratios and reports medians and ranges; shared-runner timings have no
hard CI speed threshold.

## Evidence and limits

The historical `evidence/linux` directory contains its final cohort, source and
compiler receipts, compressed full differential outputs, process command logs,
and passing baseline/candidate test logs. The exploratory cohort records the
initial version without the early exit from classification on Unicode fallback
lines; it does not supply headline numbers. Build products and caches are not
committed.

The incremental newline study retains its measurements, summaries, source
receipts, and verification receipts in `evidence/newline-normalization`.
The `subtitle-newline-normalization.yml` workflow tests both original and
candidate sources in debug and release, then runs full parity and paired
measurement on Linux and macOS. The linked newline report states which
platforms completed qualification; a queued job is not evidence of a pass.

The original dedicated macOS workflow runs the production tests and the complete paired
benchmark against native Foundation, uploading `external-subtitle-conversion-native`.
The repository's existing restoration workflow separately builds and tests the
full native app graph.

These measurements concern in-memory subtitle conversion during loading and
track changes. They exclude file I/O, text decoding, libass installation,
rendering, visible UI latency, playback frame rate, peak memory, and energy.
See [the research report](../../Documentation/EXTERNAL_SUBTITLE_CONVERSION_PERFORMANCE.md).
