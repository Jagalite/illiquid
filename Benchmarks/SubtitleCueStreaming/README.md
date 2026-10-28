# Subtitle cue streaming

This experiment measures full SRT and WebVTT conversion to ASS. The candidate
streams the lines of each cue and appends escaped payloads directly to the final
output. It removes the per-cue line array, escaped-string array, joined payload,
and interpolated full Dialogue temporary. Newline normalization, block boundaries,
timestamp parsing, escaping, and the emitted format retain their existing rules.

## Reproduce

On macOS or Linux with Swift 6.1 or newer:

    python3 Benchmarks/SubtitleCueStreaming/run.py \
      --pairs 8 --target-ms 150 --output /tmp/subtitle-cue-streaming

Use a new output directory each time. The runner checks for Kyoto and explains
direct compilation when the shared queue is unavailable. When Kyoto is available,
submit the whole serial runner through that queue as described by its diagnostic.
The benchmark uses only the real Foundation converter; it does not need FFmpeg,
libass, a media fixture, or the player UI.

## Qualification

The baseline is commit ea2ff568237e2667f7b1aeee67b11a44ebe95b72. The runner
retrieves its complete converter from Git and compiles baseline and candidate
production sources with the same driver, in debug and optimized release modes.
All four builds must emit identical complete ASS outputs and typed errors over
the differential corpus. The existing converter and escaping test suites, plus
the cue streaming regressions, run against both variants in debug and release.

Timing uses eight balanced AB/BA pairs in fresh processes. Each variant is
independently calibrated to at least 150 ms of CPU and wall time; every final
sample must exceed 60 ms. Times are normalized per complete conversion, and
fixture/output receipts and consumed checksums must match. The workloads cover
ordinary SRT and WebVTT cues with LF and CRLF newlines, multiline cues, dense line counts, a long single
line, and invalid preambles. Input construction and warmup are outside timing.

Dedicated fresh-process runs measure peak resident memory for dense and
long-line inputs. These are whole-process high-water marks, not allocation
counts or retained-memory claims. Raw measurements, compiler and machine
information, source and binary hashes, exact source snapshots, test logs, and
full correctness traces are retained in separate CI artifacts for each platform. Linux results are preliminary
component evidence; they do not qualify macOS Foundation performance.

## Results: Linux component benchmark

The [successful CI run](https://github.com/Jagalite/illiquid/actions/runs/40641953950)
tested candidate commit `2a1e8ce47fa284be29d6ec05f565db36134af3b6` against the
baseline above on an Ubuntu 24.04 runner, x86_64 AMD EPYC 7763 (four logical CPUs),
with Swift 6.4 release and glibc 2.39. The release driver used
`-O -whole-module-optimization`.

These are median milliseconds per **complete conversion** after two warmup
conversions in each process. Each workload has eight fresh-process AB/BA pairs.
Every final sample exceeded 166 ms of both elapsed and process CPU time; no
observations were excluded. The candidate won all eight pairs for both metrics
on every workload (64 paired comparisons per metric).

| Workload | Baseline ms | Candidate ms | Elapsed time reduction | CPU time reduction |
| --- | ---: | ---: | ---: | ---: |
| 128 ordinary SRT cues (LF) | 1.509 | 1.207 | 20.0% | 20.0% |
| 128 two-line WebVTT cues (LF) | 2.698 | 1.975 | 26.8% | 26.8% |
| 128 ordinary SRT cues (CRLF) | 2.041 | 1.738 | 14.8% | 14.8% |
| 128 two-line WebVTT cues (CRLF) | 4.013 | 3.312 | 17.5% | 17.5% |
| 32 SRT cues × 64 escaped Unicode lines | 27.839 | 24.185 | 13.1% | 13.1% |
| One SRT cue × 65,536 short lines | 20.367 | 11.727 | 42.4% | 42.4% |
| One SRT cue with a 1 MiB payload line | 32.747 | 9.210 | 71.9% | 71.9% |
| 8,192 untimed lines followed by one valid cue | 16.796 | 9.038 | 46.2% | 46.2% |

The ordinary caption workloads improved by 14.8–26.8% in elapsed time. Their
absolute improvements were approximately 0.30–0.72 ms per 128-cue conversion.
Dense, long-line, and invalid-preamble inputs are stress cases, not a claim about
typical subtitle files. The Unicode escaping-heavy multiline case also improved.

All 264 complete input/output/error records matched across baseline/candidate
debug/release builds. This corpus includes 64 authored cases, 192 generated cases,
and the eight exact timed workloads. All 45 focused regression tests passed in
each of the four configurations (180 test executions); twelve are new cue-line
boundary regressions.

### Memory result: inconclusive

All sixteen dedicated memory observations reported the same pre-existing
63,057,920-byte process high-water mark (60.14 MiB), before fixture construction,
before conversion, and after conversion. This measurement did not resolve a
difference. It establishes neither a memory saving nor memory non-regression.
The source removes intermediate collections and strings, but no measured memory
saving is claimed.

### Native qualification and scope

The [macOS run](https://github.com/Jagalite/illiquid/actions/runs/40641953933)
was still queued when these Linux results were recorded. The change is submitted
as a draft pending native qualification. Linux Foundation results do not establish
macOS Foundation timing or memory behavior.

This benchmark excludes disk reads, decoding, libass parsing/rendering, playback,
and the player UI. Repeated warm conversions are not a measurement of first file
open, playback startup, or frame rate. The full native application build and live
playback were not exercised by the portable component run.

## Reviewable evidence

The [Linux evidence directory](evidence/linux) contains the inspected numerical
receipts: provenance and source/binary hashes, full calibration and timing
observations, memory observations, parity and test summaries, and independently
recomputed paired results. Hardware provenance retains architecture, CPU count,
and model; the full command output remains in the CI artifact.

- [Provenance](evidence/linux/provenance.json)
- [Exact-output parity receipt](evidence/linux/parity.json)
- [Regression test results](evidence/linux/tests.json)
- [Raw timing samples](evidence/linux/measurements.jsonl)
- [Raw memory samples](evidence/linux/memory.jsonl)
- [Summary](evidence/linux/summary.json)
- [Independent paired audit](evidence/linux/paired-audit.json)
- [Completion and binary hashes](evidence/linux/completion.json)

The CI artifact retains the exact source snapshots, complete differential traces,
command receipts, and test logs for fourteen days. Those large logs and trace
payloads are not copied into this repository. The tested source and harness
remain reproducible from the candidate commit recorded above.

### Experiment history

The first [portable attempt](https://github.com/Jagalite/illiquid/actions/runs/40640188031)
passed all 262 then-current differential records but failed a new test on the
unchanged baseline: the test's mixed CR/LF generator accidentally collapsed a
blank delimiter. The fixture was corrected, and ordinary CRLF timing workloads
were added. A [second attempt](https://github.com/Jagalite/illiquid/actions/runs/40641204725)
stopped before comparison because those new workload IDs duplicated authored
correctness-case IDs. Timing fixtures now have a distinct verification-ID prefix.
Neither correction changed production code. The successful run above contains
the complete timing cohort; results from the failed attempts were not combined
with it.
