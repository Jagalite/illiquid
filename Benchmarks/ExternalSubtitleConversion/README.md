# External subtitle conversion benchmark

This benchmark measures complete SRT and WebVTT conversion through the real
`ExternalTextSubtitleConverter`. It compares the production source with the
frozen version from `main` at `68274d1b09dcc866296321a5a8858efc297c4f19`.
The baseline manifest records its original path, Git blob, and SHA-256.
Use `--baseline-ref REVISION` to compare an incremental change against a specific
Git revision instead; the runner resolves it to an immutable commit and records
the exact source blob, SHA-256, and source snapshot. The macOS workflow compares
PRs with their base commit and uses `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`
for the timestamp research branch and manual runs.

## Reproduce

Use a Swift 6.1-or-newer toolchain. The component is Foundation-only and needs
no FFmpeg, libass, renderer, media file, or application launch.

```sh
bash Scripts/test-external-subtitle-regressions.sh -c debug -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/ExternalSubtitleConversion/run.py verify --output /tmp/subtitle-verify
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --rounds 10 --target-ms 100 --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --output /tmp/subtitle-benchmark
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

The original 36 timed cases cover both formats, 1/100/2,000/10,000 cues, plain ASCII,
multilingual text, ASCII escapes, CRLF/CR/BOM handling, empty input, invalid
cues, and Unicode-plus-escape fallback controls. All fixtures are synthetic;
input construction is outside timing. A 2,000-cue fixture is useful for a
dialogue-heavy title; the 10,000-cue case exercises longer material.
Four additional timed cases cover short WebVTT timestamps, unpadded SRT hours,
and large hours in both formats, bringing the current workload set to 40.

Before timing, the runner compares full input/output UTF-8 bytes and exact
typed conversion errors in 13,942 cases. These include every sequence of length
zero through three over nine selected atoms in both formats, additional
Unicode/normalization edges, compatibility punctuation, NUL, literal ASS
commands, empty payloads, and trailing newlines. Swift String equality is not
used for byte parity, since it accepts canonical equivalence.

The timestamp corpus replaces every position in all four fixed-width spellings
with all 128 ASCII values, seven Unicode atoms, or an empty string, testing both
cue endpoints (12,240 mutations). The unchanged baseline supplies the expected
output/error for this corpus; the harness does not duplicate timestamp parsing
rules. Independent regression tests retain explicit expected outputs for
rounding carries, whitespace, malformed inputs, and noncanonical SRT fallbacks.

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
each round. Measurements run serially. The saved-record recovery of one incomplete pair
is documented in the research report; all complete pairs are retained.

Each process prepares its fixture, converts it once for warmup and output
validation, then times complete conversions and consumption of the returned
UTF-8 byte count. Parsing, escaping, event construction, and output construction
are included. Input generation, full byte comparisons, hashing, and JSON
serialization are excluded. CPU time and monotonic elapsed time are recorded.
A checked iteration checksum consumes every result; complete outputs are
verified again after timing.

Summary generation validates all 800 observations, exact pair order, operation
counts, checksums, output fingerprints, and durations. It retains individual
paired ratios and reports medians and ranges; shared-runner timings have no
hard CI speed threshold.

## Evidence and limits

The checked-in `evidence/linux` directory contains the original 36-case cohort, source and
compiler receipts, compressed full differential outputs, process command logs,
and passing baseline/candidate test logs. The exploratory cohort records the
initial version without the early exit from classification on Unicode fallback
lines; it does not supply headline numbers. Build products and caches are not
committed.

The dedicated macOS workflow runs the production tests and the complete paired
benchmark against native Foundation, uploading `external-subtitle-conversion-native`.
The repository's existing restoration workflow separately builds and tests the
full native app graph.

These measurements concern in-memory subtitle conversion during loading and
track changes. They exclude file I/O, text decoding, libass installation,
rendering, visible UI latency, playback frame rate, peak memory, and energy.
See [the research report](../../Documentation/EXTERNAL_SUBTITLE_CONVERSION_PERFORMANCE.md).

The incremental fixed-width timestamp experiment uses current main as its
baseline; see [the timestamp report](../../Documentation/SUBTITLE_TIMESTAMP_PERFORMANCE.md).
The portable timestamp workflow also runs the complete component tests and
paired benchmark on Ubuntu, with Linux and macOS results reported separately.
