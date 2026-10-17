# External subtitle conversion research

This experiment compares **complete in-memory SRT/WebVTT-to-ASS conversion**
against `main` at `68274d1b09dcc866296321a5a8858efc297c4f19`. The frozen baseline
is the entire production `ExternalTextSubtitleConverter.swift` file, captured
without edits; `baseline-manifest.json` records its original path, commit,
byte count, and SHA-256. The candidate is the complete current production file,
or an explicit `--candidate-source` file supplied for an exploratory comparison.

## Reproduce

Requires Python 3.10+ and Swift 6.1+ with Foundation. There are no downloaded
dependencies, framework doubles, native playback SDKs, or package resolution.
The same driver supports macOS and Linux.

```sh
# Full exact-byte/error differential check, followed by the timed experiment.
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --samples 6 --iterations 3 --warmups 1 --random-cases 2000 \
  --output /tmp/subtitle-conversion

# Correctness only, with the same complete baseline and candidate sources.
python3 Benchmarks/ExternalSubtitleConversion/run.py verify \
  --output /tmp/subtitle-conversion-verify

# Short harness smoke check; do not quote these timings as a performance result.
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --samples 2 --iterations 1 --random-cases 100 \
  --output /tmp/subtitle-conversion-smoke

# Recompute summary statistics from the retained raw rows.
python3 Benchmarks/ExternalSubtitleConversion/run.py summarize \
  --output /tmp/subtitle-conversion
```

Use `--swiftc /path/to/swiftc` or `SWIFTC` to select a compiler. `--workloads`
accepts a space-separated subset of the workload names below. `--candidate-source`
selects another complete converter file; the runner snapshots it before building,
so later working-tree changes cannot alter an active cohort. Every new run
requires an empty output directory. `build` produces binaries and receipts
without executing the differential or timings.

The app's existing converter regression suite is independently runnable in both
configurations. These tests state expected behavior; the differential additionally
checks compatibility with the frozen implementation.

```sh
bash Scripts/test-external-subtitle-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh --jobs 2 -c release -Xswiftc -warnings-as-errors
```

## Workloads

All fixtures are deterministic synthetic captions, generated from a recorded
runtime seed. Each fixture and its converted result stays within the production
32 MiB byte limit. The complete input files and SHA-256 receipts are retained.

| Workload | Cues | Payload and line endings |
| --- | ---: | --- |
| `tiny_srt_ascii` | 2 | Plain ASCII, LF |
| `tiny_vtt_unicode` | 2 | Multilingual text, LF |
| `feature_srt_ascii` | 1,500 | Plain ASCII, LF |
| `feature_vtt_ascii` | 1,500 | Plain ASCII, LF |
| `feature_srt_unicode_crlf` | 1,500 | Multilingual text, CRLF |
| `feature_vtt_unicode` | 1,500 | Multilingual text, LF |
| `feature_srt_sparse` | 1,500 | Braces/backslashes in one of every eight primary payload lines, LF |
| `feature_vtt_sparse_crlf` | 1,500 | Sparse braces/backslashes, CRLF |
| `feature_srt_dense` | 1,500 | Dense braces/backslashes, LF |
| `feature_vtt_dense_cr` | 1,500 | Dense braces/backslashes, CR |
| `feature_srt_sparse_cr` | 1,500 | Mostly LF; one CR-bearing cue per 97 cues |
| `fallback_srt_late_ascii_crlf` | 1,500 | Every payload line is long ASCII with one final backslash, CRLF |
| `fallback_vtt_late_unicode_crlf` | 1,500 | Every payload line is long multilingual text with one final brace, CRLF |
| `large_srt_mixed` | 12,000 | Long multilingual text with occasional literals, LF |
| `large_vtt_mixed` | 12,000 | Long multilingual text with occasional literals, LF |

The late-escape workloads expose the cost of an unsuccessful payload guard: it
must scan each long caption before taking the original replacement path. CRLF
also requires normalization, preventing an LF normalization fast path from
masking that cost. They contain no extra escape-free caption lines. The sparse-CR
workload similarly prevents crediting all-LF normalization behavior to mixed input.

## Source and correctness controls

Each timed variant compiles its complete, unmodified converter into an optimized
`ConverterModule` dynamic library with `-enable-testing`. The separately compiled
driver uses `@testable import` to reach the existing internal type. Both compile
with `-O`, whole-module optimization, Swift 6 language mode, and warnings as
errors. **Cross-module optimization is not enabled.** The driver loads its input
from a file at runtime; the compiler cannot precompute conversion from fixture
constants or inspect the converter body across the module boundary.

The differential executable combines complete baseline and candidate files. Its
only baseline adaptation renames the enum declaration to
`BaselineExternalTextSubtitleConverter`; the exact one-line transformation and
both source hashes are recorded. No converter declaration is extracted or
rewritten for timing.

Correctness acceptance compares **full UTF-8 byte arrays**, not Swift `String`
equality, whose Unicode equivalence could conceal byte changes. Errors must have
the same typed case, format, and message bytes. Cases include ordinary and dense
literals; backslashes/braces followed by combining marks, variation selectors,
joiners and keycap marks; multilingual text; composed/decomposed accents; emoji;
NUL, tabs, Unicode separators and bidi controls; CR/LF/CRLF; malformed timestamps;
WebVTT signatures, comments and metadata; seeded randomized payload/block
variations; and all full-size performance fixtures. A mismatch emits the exact
input and both output/error byte sequences as base64 in the command's retained
stdout and aborts the campaign. The FNV receipts supplement this exact comparison;
digest equality alone does not pass the differential.

## Measurement protocol

Default measurement uses six fresh-process pairs per workload, three conversions
per process, and one warmup. Tiny inputs multiply the conversion count by 25.
Every workload receives three AB and three BA pairs, alternating order across
samples and also offsetting adjacent workloads. A process's arithmetic mean
conversion duration is the sample; individual conversions are not counted as
independent process replicates. The summary reports medians and ranges, plus the
median of paired candidate/baseline ratios. It does not estimate tail latency
from this small cohort.

`clock_gettime(CLOCK_MONOTONIC)` brackets **each full `convert` call**. Fixture
construction, file I/O, source/fixture hashing, warmup, output UTF-8 counting,
output checksum consumption, and returned-string destruction are outside the
timer. On macOS, each warmup and measured iteration runs inside an autorelease
pool, drained after consumption and after the conversion timer stops; Linux
executes the same body directly. This keeps temporary Foundation objects bounded
across repetitions. The timer includes both no-op guards and any fallback work.
Every output is fully consumed after timing; both members of each pair must agree
on output bytes/digest, input bytes, format and operation count.

The output directory records compiler/platform information, source/driver hashes,
unchanged source snapshots, generated fixtures and their SHA-256 values, command
arguments and logs, binary hashes, differential results, every raw timing row in
`measurements.jsonl`, and `summary.json`. Build products can be reproduced and
need not be committed.

This is converter elapsed latency on the recorded host. The monotonic clock
measures wall time, not process CPU time. It does not measure file
decoding, file access, libass rendering, player startup or track-switch latency,
visible output, peak/live memory, allocations, or energy. Linux results do not
qualify Foundation performance on macOS. macOS converter results still do not
establish a player-level performance gain. No numerical result is claimed by
the harness itself; publish only a completed cohort with its provenance and
remaining platform limitations.
