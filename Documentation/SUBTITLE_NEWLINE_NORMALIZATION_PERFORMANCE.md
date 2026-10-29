# External subtitle newline normalization performance

## Result and scope

The ASCII-only newline fast path reduces complete in-memory subtitle conversion
time by **23.7–30.3%** across eight ASCII CRLF/CR workloads on the Linux runner.
All eight measured pairs improve in every one of those workloads, and process
CPU time agrees with elapsed time. The four almost-ASCII Unicode fallback
controls show a **0.3–1.0%** median increase from the extra eligibility scan.
These are workload-specific measurements, not an application-wide speed claim.

Native macOS qualification is still queued as of 2026-10-28 05:14 UTC.
The Linux result does not establish native Foundation performance.

This study compares the actual production converter at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` with the candidate at
`5a2bd808140fe61abb525e54803846b88b4c8ef6`. The baseline already includes the
previous block-iteration and payload-escaping improvements. The earlier
[frozen-baseline study](EXTERNAL_SUBTITLE_CONVERSION_PERFORMANCE.md) is distinct;
its gains are not counted again here.

## Production change

[SubtitlePipeline.prepareExternalData](../Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift)
decodes external SRT/WebVTT text and calls
[ExternalTextSubtitleConverter.convert](../Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift)
before installing subtitle data.

When the source contains CR, the original converter makes two Foundation
replacement calls: CRLF to LF, then CR to LF. The candidate retains the existing
no-CR early exit. For a source whose UTF-8 bytes are all ASCII, it writes the
normalized result in one pass. A CR becomes LF; an LF immediately following CR
is skipped. Resetting that state on the skipped LF preserves CRLF followed by
another LF. All other bytes, including NUL and ASCII controls, are copied.

The destination capacity is the input's UTF-8 byte count. Each iteration writes
at most one byte, the skipped LF writes none, and only the initialized prefix
is returned. The normalized String is no longer than its input, and the loop does not
require contiguous source storage. This does not establish a measured memory
or allocation reduction.

Any non-ASCII source retains the exact original Foundation replacements.
That includes a BOM still present in the converter's String, such as
BOM-prefixed WebVTT. SRT decoding removes recognized BOM bytes before this
stage, so otherwise ASCII SRT can remain eligible. Curly punctuation,
multilingual text, and combining marks also select the compatibility path.

## Why the Unicode fallback is necessary

The first experiment attempted the byte loop for all UTF-8 inputs. Independent
comparison rejected it. On the tested Linux Foundation implementation,
CR followed by U+0301 or U+FE0F is left unchanged by the original nonliteral
replacement calls. A direct byte rewrite normalized that CR and changed the
complete ASS output.

The first test draft also incorrectly assumed that Foundation normalization
always removes CR; it failed against the original source. That assumption was
removed. The next experiment compares separately compiled, complete converters
on the original input, including exact output bytes and typed errors. It
caught the unrestricted rewrite at `newline-diff-srt-2-3-0` before timing.
The final ASCII gate preserves this Unicode behavior.

The [rejected unrestricted run](https://github.com/Jagalite/illiquid/actions/runs/40635265385)
and its source commit remain inspectable. The final evidence includes a raw
byte probe and a focused regression for CR followed by a combining acute
accent, variation selector, and zero-width joiner. The regression derives the
payload expectation from one application of the original Foundation behavior;
it does not pass a pre-normalized full file through the candidate converter.

## Correctness and measurement protocol

The [qualification run](https://github.com/Jagalite/illiquid/actions/runs/40635930545)
uses identical tests and driver code for both implementations.

- The focused suite contains **35 tests**. Baseline and candidate are each
  tested in debug and release, with compiler warnings treated as errors.
- Before timing, **5,222 cases** compare complete decoded input and output
  UTF-8 bytes, typed errors, cue metadata, and output fingerprints.
  Swift String equality is insufficient because it admits canonical equivalence.
- The 3,510 new newline differential cases enumerate every sequence of length
  zero through three over eight atoms: CR, LF, ASCII text, U+0301, ZWJ, U+FE0F,
  NUL, and non-ASCII text. Each appears in three placements in both formats.
  Malformed inputs use the separately compiled original as their behavior oracle.
- **50 timed cases** cover both formats, 1/100/2,000/10,000 cues, LF controls,
  plain and escaped ASCII, multilingual text, CRLF, CR, BOM, empty/error cases,
  and four files with the first non-ASCII character at the very end.
- Each complete converter is compiled into its own optimized dynamic module:
  `-O -whole-module-optimization -swift-version 6 -warnings-as-errors`.
  The same driver links against each module without cross-module optimization.
- Baseline calibration chooses one iteration count per case, used unchanged by
  both variants, targeting 120 ms. Each observation runs in a fresh process.
  Eight adjacent pairs alternate AB and BA, four of each per case. Case order
  reverses on alternate rounds. Measurements run serially.
- Input creation, one warmup, full output validation, hashing, and JSON
  serialization are outside timing. Complete parsing, payload escaping,
  event/output construction, and consumption of every result's byte count are
  inside timing. Both monotonic elapsed time and process CPU time are recorded.
- Every result contributes to a checked UInt64 checksum. Outputs are checked
  again after timing. Summary generation validates the complete ordered cohort,
  matching operation counts, fingerprints, and durations. **No observations
  are removed or recovered.**

The Linux cohort has **800 observations**. An independent recomputation of
the raw records confirmed exact pair order, checksums, metadata agreement,
per-operation medians, and paired ratios; the recomputation differences were
zero. Each of the four test runs reported 35 passing tests.

## Linux results

Environment: GitHub-hosted `ubuntu-24.04`, x86_64,
`Linux-6.17.0-1022-azure-x86_64-with-glibc2.39`,
Swift 6.4 (`swift-6.4-RELEASE`).
The [job completed successfully](https://github.com/Jagalite/illiquid/actions/runs/40635930545/job/122642777143).

Times below are median milliseconds per complete conversion. Changes are the
median of the eight within-pair candidate/baseline ratios, minus one; they
are not the ratio of the two independently calculated time medians.
Negative changes mean less time.

| Workload | Baseline ms | Candidate ms | Elapsed change | CPU change |
|---|---:|---:|---:|---:|
| srt-100-plain-crlf | 1.500 | 1.055 | -29.76% | -29.76% |
| srt-100-escaped-cr | 1.561 | 1.111 | -29.15% | -29.16% |
| srt-2000-plain-crlf | 30.344 | 21.156 | -30.28% | -30.29% |
| srt-10000-plain-crlf | 151.186 | 106.279 | -29.56% | -29.55% |
| srt-2000-plain-cr | 30.108 | 21.147 | -29.67% | -29.67% |
| vtt-2000-plain-crlf | 39.394 | 29.408 | -25.38% | -25.37% |
| vtt-10000-plain-crlf | 196.187 | 149.312 | -23.68% | -23.69% |
| vtt-2000-plain-cr | 39.330 | 29.573 | -25.19% | -25.18% |

For 10,000 plain ASCII cues with CRLF, the observed medians save approximately
45 ms for SRT and 47 ms for WebVTT. Both parsing and output construction remain
included, so these are complete-conversion gains rather than a normalization
microbenchmark.

The controls matter:

| Control group | Cases | Range of median paired elapsed changes |
|---|---:|---:|
| LF/no-CR, BOM, and error controls | 33 | -0.67% to +1.84% |
| Multilingual CRLF fallback | 5 | -0.12% to +0.63% |
| First non-ASCII character at end of CRLF input | 4 | +0.31% to +0.99% |

The late-Unicode cases deliberately scan almost the whole source before
falling back. Their extra work is visible; the result is not “zero overhead.”
The small control changes and occasional wider individual-pair excursions
remain in the complete table and raw records. Eight pairs on shared CI support
the reported observations, not a promise that every control is statistically
unchanged.

## macOS qualification

The [macOS 26 job](https://github.com/Jagalite/illiquid/actions/runs/40635930545/job/122642776837)
is queued. No macOS test or performance pass is claimed in this version of the
report. The same pinned baseline, candidate, tests, and complete paired
protocol are scheduled on the native runner.

## Reproduce

Use the candidate source and harness from the PR, or check out the measured
candidate commit. The converter is Foundation-only; these focused runs do not
require FFmpeg, libass, media files, or a UI session.

```sh
baseline=ea2ff568237e2667f7b1aeee67b11a44ebe95b72
for configuration in debug release; do
  bash Scripts/test-external-subtitle-regressions.sh --baseline-ref "$baseline" \
    -c "$configuration" -Xswiftc -warnings-as-errors
  bash Scripts/test-external-subtitle-regressions.sh \
    -c "$configuration" -Xswiftc -warnings-as-errors
done
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --baseline-ref "$baseline" --rounds 8 --target-ms 120 \
  --output /tmp/illiquid-subtitle-newlines
```

The output directory must be new or empty. Re-running `summarize --output DIR`
revalidates a completed cohort. The runner's default, with no
`--baseline-ref`, still selects the historical frozen baseline
`68274d1b09dcc866296321a5a8858efc297c4f19`; use the explicit revision above for
this incremental study. The standalone test script accepts the same leading
baseline option and otherwise tests the working-tree converter.

The native workflow selects `/Applications/Xcode_26.6.app/Contents/Developer`
and targets macOS 26.0. The hosted runners do not have the repository's Kyoto
queue; the workflow records that fact and builds the isolated component
directly, serializing builds and measurements within each job.

## Retained evidence and source identity

The [evidence directory](../Benchmarks/ExternalSubtitleConversion/evidence/newline-normalization)
contains raw measurements, complete summaries, compiler/build commands, source
receipts, test and parity receipts, the normalization probe, and the CI artifact
identity. Measurements preserve the original emitted JSONL records. Other JSON
files are reformatted from structured CI log records; `receipt.json` labels
the original artifact-byte hashes separately.

The CI artifact also contains complete differential output archives, compiler
logs, test logs, source snapshots, and the runner snapshot. It has a 14-day
retention period; the checked-in measurements and receipts remain available,
and the command with the pinned baseline reproduces the full differential corpus.

| Input | SHA-256 |
|---|---|
| Baseline converter | `2a26e9951ac64921f398fc5f23c5d81c6c319952bfe02d9b2b3a0b4a765fdc28` |
| Candidate converter | `a44e219880da9cef6f3e84cdc6b221cadaa0fa9772e8042ad47ab82b504801c0` |
| Benchmark driver | `66f647de4d077bf8caa77c5d79ee8efe7d4b65c46a421d97041e59b6137ca54f` |
| Benchmark runner | `df34630d66de98a455662122f47c1b3ee977b75193371af11034922ac3b6a81b` |

The final documentation/evidence commit does not change those measured source
or harness bytes. The temporary branch push trigger used for research is
removed; the focused workflow remains available for relevant pull requests
and manual runs. No wall-time threshold is imposed on shared CI.

## Limits

These synthetic measurements cover already-decoded, in-memory SRT/WebVTT
conversion during external subtitle preparation. They exclude disk I/O, text
decoding, final Data conversion, libass installation, rendering, visible UI
latency, playback frame rate, peak RSS, allocation counts, and energy.
No user-library distribution was sampled, so the fraction of real files that
qualify for the ASCII path is unknown.

The production change is restricted to newline normalization. The focused
component tests do not establish a pass for the entire playback application
or UI test graph.

## Complete Linux workload table

Times are microseconds per conversion. Paired ranges retain all eight pairs.

| Workload | Baseline μs | Candidate μs | Elapsed change | CPU change | Elapsed pair range |
|---|---:|---:|---:|---:|---:|
| srt-1-plain | 9.408 | 9.384 | -0.06% | -0.05% | -3.93% to +0.96% |
| srt-100-plain | 1051.854 | 1058.876 | +0.71% | +0.71% | -0.48% to +3.90% |
| srt-2000-plain | 20657.201 | 20644.179 | +0.28% | +0.28% | -0.84% to +1.06% |
| srt-10000-plain | 103868.432 | 104073.791 | +0.18% | +0.18% | -1.74% to +2.32% |
| srt-1-multilingual | 10.295 | 10.350 | +0.41% | +0.43% | -2.29% to +6.12% |
| srt-100-multilingual | 1188.522 | 1211.051 | +1.75% | +1.75% | -0.22% to +2.75% |
| srt-2000-multilingual | 23745.499 | 23875.279 | +0.52% | +0.52% | -2.56% to +2.59% |
| srt-10000-multilingual | 117827.004 | 118013.674 | +0.52% | +0.52% | -0.72% to +2.06% |
| srt-1-escaped | 9.800 | 9.820 | +0.30% | +0.31% | -5.69% to +1.32% |
| srt-100-escaped | 1088.667 | 1106.193 | +1.81% | +1.80% | -0.64% to +11.36% |
| srt-2000-escaped | 21692.234 | 21586.436 | +0.30% | +0.32% | -3.30% to +1.15% |
| srt-10000-escaped | 108196.188 | 107382.504 | -0.67% | -0.67% | -2.02% to +0.99% |
| vtt-1-plain | 15.310 | 15.262 | -0.11% | -0.09% | -1.48% to +4.36% |
| vtt-100-plain | 1458.784 | 1477.857 | +1.52% | +1.52% | -1.90% to +3.01% |
| vtt-2000-plain | 28946.968 | 29322.188 | +0.87% | +0.89% | -1.05% to +3.53% |
| vtt-10000-plain | 145156.780 | 144242.257 | -0.09% | -0.08% | -2.09% to +3.51% |
| vtt-1-multilingual | 16.878 | 16.870 | +0.56% | +0.56% | -0.60% to +1.70% |
| vtt-100-multilingual | 1625.873 | 1650.655 | +1.05% | +1.05% | +0.09% to +6.37% |
| vtt-2000-multilingual | 32453.156 | 32341.141 | +0.03% | +0.03% | -4.59% to +1.79% |
| vtt-10000-multilingual | 162311.587 | 161772.776 | -0.67% | -0.68% | -2.62% to +2.52% |
| vtt-1-escaped | 15.626 | 15.750 | +0.85% | +0.87% | -0.49% to +4.04% |
| vtt-100-escaped | 1502.603 | 1531.700 | +1.84% | +1.84% | -1.02% to +2.82% |
| vtt-2000-escaped | 29950.544 | 29990.483 | +0.01% | +0.02% | -3.53% to +2.41% |
| vtt-10000-escaped | 149271.211 | 148946.705 | -0.23% | -0.23% | -1.54% to +1.52% |
| srt-100-plain-crlf | 1500.234 | 1054.846 | -29.76% | -29.76% | -30.09% to -28.94% |
| vtt-100-multilingual-crlf | 2588.198 | 2587.300 | -0.12% | -0.12% | -0.39% to +0.58% |
| srt-100-escaped-cr | 1561.256 | 1110.886 | -29.15% | -29.16% | -30.26% to -28.08% |
| srt-2000-plain-crlf | 30343.622 | 21155.622 | -30.28% | -30.29% | -32.76% to -28.44% |
| srt-2000-multilingual-crlf | 41935.804 | 42085.251 | +0.63% | +0.63% | -0.59% to +7.39% |
| srt-10000-plain-crlf | 151186.484 | 106279.182 | -29.56% | -29.55% | -30.21% to -26.97% |
| srt-10000-multilingual-crlf | 208811.313 | 208498.333 | -0.07% | -0.08% | -1.48% to +1.93% |
| srt-2000-plain-cr | 30108.326 | 21146.639 | -29.67% | -29.67% | -31.38% to -28.49% |
| vtt-2000-plain-crlf | 39394.436 | 29407.782 | -25.38% | -25.37% | -26.37% to -23.61% |
| vtt-2000-multilingual-crlf | 51543.113 | 51533.469 | +0.63% | +0.64% | -1.53% to +1.41% |
| vtt-10000-plain-crlf | 196186.590 | 149311.866 | -23.68% | -23.69% | -25.00% to -19.86% |
| vtt-10000-multilingual-crlf | 255673.233 | 256510.149 | +0.17% | +0.17% | -0.82% to +1.50% |
| vtt-2000-plain-cr | 39330.479 | 29572.635 | -25.19% | -25.18% | -30.88% to -22.79% |
| srt-2000-late-unicode-crlf | 33511.186 | 33866.151 | +0.99% | +0.99% | -2.14% to +2.92% |
| srt-10000-late-unicode-crlf | 167497.911 | 168271.950 | +0.50% | +0.49% | +0.02% to +12.27% |
| vtt-2000-late-unicode-crlf | 43866.361 | 43755.909 | +0.31% | +0.33% | -0.64% to +3.10% |
| vtt-10000-late-unicode-crlf | 215054.981 | 217455.043 | +0.95% | +0.97% | -0.14% to +7.67% |
| vtt-100-escaped-bom | 1547.833 | 1544.455 | -0.09% | -0.07% | -3.24% to +1.49% |
| srt-empty | 0.143 | 0.144 | +1.11% | +1.11% | -0.75% to +2.81% |
| vtt-empty | 0.506 | 0.512 | +1.55% | +1.54% | +0.61% to +5.85% |
| vtt-missing-signature | 0.370 | 0.376 | +1.46% | +1.48% | -4.87% to +2.61% |
| srt-no-valid-cues | 8.919 | 8.938 | +0.57% | +0.56% | -1.62% to +1.55% |
| srt-2000-unicode-escaped | 56059.919 | 55981.628 | -0.03% | -0.01% | -3.78% to +0.82% |
| srt-2000-combining-escaped | 34272.715 | 34656.559 | +1.32% | +1.32% | -12.87% to +4.87% |
| vtt-2000-unicode-escaped | 64268.738 | 64517.526 | -0.12% | -0.11% | -1.71% to +1.92% |
| vtt-2000-combining-escaped | 42464.564 | 42856.409 | +0.13% | +0.13% | -3.64% to +3.47% |


