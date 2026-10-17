# External subtitle conversion performance

## Result and decision

The candidate avoids Foundation replacement work when external SRT/WebVTT text
does not contain characters that need replacing. On the recorded native macOS
experiment, the seven 1,500-cue plain, sparse-literal, and multilingual workloads
had **12.6–39.9% lower median paired conversion time**. The two 12,000-cue mixed
workloads had **31.6–34.7% lower median paired conversion time**, with the
candidate faster in all ten process pairs for each large workload.

This supports proposing the small converter change. It also has a cost: a line
that needs escaping first pays for a guard scan and then executes the existing
replacements. The long ASCII late-escape stress fixture recorded **5.9% more
time by the median paired statistic** in the final cohort. Dense CR text was
approximately unchanged; the long Unicode fallback fixture was too variable
to support a gain claim. Both favorable and unfavorable measurements are
retained below. These synthetic fixtures do not establish how frequently each
case occurs in users' subtitle files.

The measured operation is a complete in-memory `convert` call. The call occurs
in [`SubtitlePipeline.prepareExternalData`](../Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift)
when preparing external subtitles. It is not a per-frame operation. The result
does not measure player startup, track-switch latency, rendering, CPU time,
memory, allocations, or energy.

## Change and compatibility

The production change is confined to
[`ExternalTextSubtitleConverter.swift`](../Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift):

1. Check for a carriage-return byte before normalizing CRLF and CR to LF. If
   present, run the original two Foundation replacements in their original order.
2. Check each caption line for the ASCII bytes for backslash, opening brace, and
   closing brace. If absent, return `String(line)` directly. If present, run the
   original three Foundation replacements in their original order.

These bytes cannot be part of a multibyte UTF-8 scalar. The guards only decide
whether to skip no-op replacements; the fallback keeps Foundation's behavior,
including its handling of Unicode around escape characters. There is no custom
byte rewriting, new parsing algorithm, or change to timestamps or errors. The
pipeline's existing bounded input/output handling is outside this change.

The experiment compares the complete production source at base commit
[`68274d1b09dcc866296321a5a8858efc297c4f19`](https://github.com/Jagalite/illiquid/commit/68274d1b09dcc866296321a5a8858efc297c4f19)
against the complete candidate at measured commit
[`de1b4be4906c9a0446476b39993c4c75168263b7`](https://github.com/Jagalite/illiquid/commit/de1b4be4906c9a0446476b39993c4c75168263b7).
The final documentation/evidence commit does not change the measured converter,
tests, or benchmark code.

| Source | Bytes | SHA-256 |
| --- | ---: | --- |
| Frozen baseline | 9,298 | `1f858588bd87afd61b0f8a091fc74f950f06a0299c62b38255b25f148ce30899` |
| Candidate | 9,738 | `6381061d8a35e94b33755cadb283a306d9aaa1eadb7a7653ef9711db595d6b8d` |

## Final native measurement

The final cohort is [Actions run 39067528346](https://github.com/Jagalite/illiquid/actions/runs/39067528346),
job `117498173448`, measured on 2026-10-17. Its
[manifest](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/manifest.json)
and [environment receipt](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/environment.txt)
record an **Apple M1 (Virtual), arm64, macOS 26.6.2 (25G83), Xcode 26.6 (17F113),
and Apple Swift 6.3.3**. This is one hosted runner environment, with visible
timing variation, rather than a dedicated physical-machine comparison.

Each workload has ten fresh-process baseline/candidate pairs, balanced five AB
and five BA. A process performs two warmups and five measured conversions;
tiny inputs use 125 measured conversions. The process mean is one observation,
giving 300 observations across 15 workloads. Repeated calls inside a process
are not counted as independent process samples.

For every call, the driver decodes a fresh `String` from preloaded fixture
`Data` before starting the timer. It keeps that input alive through output
consumption and drains an autorelease pool after timing. This preserves a
newly decoded input for each conversion while warming code and the runtime.
The interval brackets only the complete conversion; decoding, I/O, checksums,
output consumption, and returned-string destruction are excluded. Full
converter sources compile into separate optimized dynamic modules, with no
cross-module optimization, to keep the driver from precomputing the result.
See the [method and reproduction guide](../Benchmarks/ExternalSubtitleConversion/README.md)
for the complete protocol and fixture definitions.

### Paired results for every workload

For each pair, let `B` and `C` be the baseline and candidate process means.
**Paired reduction = `100 × (1 − median(C / B))`.** Positive values mean less
conversion time; negative values mean more. “Faster pairs” counts pairs with
`C < B`. These are descriptive measurements, without a confidence interval or
tail-latency claim. The
[original summary](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/summary.json)
also retains every paired ratio and each variant's median and range.

| Workload | Cues | Median paired reduction | Faster pairs |
| --- | ---: | ---: | ---: |
| `feature_srt_ascii` | 1,500 | +29.8% | 10/10 |
| `feature_vtt_ascii` | 1,500 | +24.7% | 9/10 |
| `feature_srt_unicode_crlf` | 1,500 | +24.8% | 10/10 |
| `feature_vtt_unicode` | 1,500 | +39.9% | 10/10 |
| `feature_srt_sparse` | 1,500 | +35.6% | 10/10 |
| `feature_vtt_sparse_crlf` | 1,500 | +12.6% | 8/10 |
| `feature_srt_sparse_cr` | 1,500 | +24.3% | 10/10 |
| `feature_srt_dense` | 1,500 | +9.1% | 8/10 |
| `feature_vtt_dense_cr` | 1,500 | −0.1% | 5/10 |
| `fallback_srt_late_ascii_crlf` | 1,500 | −5.9% | 4/10 |
| `fallback_vtt_late_unicode_crlf` | 1,500 | +3.2% | 6/10 |
| `large_srt_mixed` | 12,000 | +34.7% | 10/10 |
| `large_vtt_mixed` | 12,000 | +31.6% | 10/10 |
| `tiny_srt_ascii` | 2 | +27.1% | 6/10 |
| `tiny_vtt_unicode` | 2 | +47.9% | 9/10 |

For the scale of the improvement, these are the **independently computed
medians** of the ten process means for selected workloads:

| Workload | Input bytes | Baseline median | Candidate median |
| --- | ---: | ---: | ---: |
| Plain SRT, 1,500 cues | 149,529 | 26.450 ms | 19.759 ms |
| Plain WebVTT, 1,500 cues | 157,062 | 28.182 ms | 22.234 ms |
| Sparse-literal SRT, 1,500 cues | 159,792 | 29.338 ms | 20.044 ms |
| Multilingual WebVTT, 1,500 cues | 202,062 | 41.392 ms | 23.866 ms |
| Mixed SRT, 12,000 cues | 5,618,673 | 823.857 ms | 532.164 ms |
| Mixed WebVTT, 12,000 cues | 5,678,706 | 757.398 ms | 522.331 ms |

The paired percentages are not calculated by dividing the two independently
computed medians. The two statistics can even disagree in direction when
timings vary substantially. For example, the ASCII fallback has independent
medians of 169.535 ms and 160.113 ms, while its paired ratio is 1.059 and six
of ten candidate runs are slower. The Unicode fallback has independent
medians of 408.779 ms and 427.139 ms, but a paired ratio of 0.968. Neither
independent-median comparison should replace the paired result to choose a
more favorable interpretation.

The fallback fixtures put a single escaping character at the end of every
long payload line and require CRLF normalization. They force the guard to
scan the full line before doing the old replacement work, with no additional
escape-free lines to mask the cost. The fresh ASCII paired ratios range from
0.859 to 1.306; the Unicode ratios range from 0.874 to 1.618. Consequently,
the observed 5.9% ASCII cost is a sample statistic, not an upper bound, and
the mixed Unicode result is not evidence of a reliable fallback gain.

Tiny-input medians are below 0.1 ms, with mixed pairs and an outlier in the
Unicode case. Their percentages are retained for completeness but are not
the basis for the performance decision. The two large cases improve in all
pairs, including both execution orders, and the 1,500-cue ordinary payloads
provide a useful result beyond just the largest stress inputs.

## Correctness and review

The [debug](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/tests/debug.txt)
and [release](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/tests/release.txt)
native regression logs each report **17 tests passed**, compiled with warnings
as errors. Two added tests independently specify exact UTF-8 output for plain
Unicode/control characters and for mixed plain/escaped caption lines.

The [differential receipt](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/verification.json)
reports **5,761 exact compatibility checks passed**: 4,411 successful conversions
and 1,350 matching typed errors. This includes 5,000 seeded randomized cases,
targeted line-ending, WebVTT, malformed timestamp, Unicode/grapheme, literal
escaping, and control-character cases, plus all 15 full performance fixtures.
Successful outputs are compared as complete UTF-8 arrays; errors are compared
by typed case and message bytes. Swift's Unicode-equivalent `String` equality
and digest equality are not used as substitutes for the exact comparison.

The timed candidate's source hash matches the proposed production file. A
separate audit of the retained receipts checks the fixture/source hashes,
complete balanced pairs, raw conversion durations, summaries, and successful
command exits. These checks cover the converter and research harness; they
do not constitute a full playback or UI integration test.

## Earlier exploratory cohort

[Actions run 39067042202](https://github.com/Jagalite/illiquid/actions/runs/39067042202)
at commit `1c9d3b763c1c6f4e12126fdc553bf3c2ba9edd0a` measured the same production
candidate but reused one decoded input string within each process. Its
[complete evidence](../Benchmarks/ExternalSubtitleConversion/evidence/macos-exploratory/README.md)
is preserved separately. It also passed both 17-test configurations and all
5,761 exact compatibility checks.

The final harness changed only input lifetime and its associated metadata:
each conversion now receives a newly decoded string. Production decodes an
external subtitle before conversion, so this is a closer match to that input
lifetime. Both experiments support gains on ordinary and large fixtures.
The first experiment recorded a 3.7% median paired time increase for the
ASCII fallback and a 1.4% increase for the Unicode fallback. The cohorts must
not be pooled: they are separate hosted runs with different input-lifetime
protocols. Their differences cannot establish what effect was caused by input
reuse or by host variation. The final cohort supplies the headline numbers.

## Reproduce and inspect the evidence

Run the recorded campaign from the repository root on a Swift-capable machine:

```sh
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --samples 10 --iterations 5 --warmups 2 --random-cases 5000 \
  --output /tmp/subtitle-conversion-fresh
```

The [dedicated macOS workflow](../.github/workflows/external-subtitle-conversion-performance.yml)
runs the expected-output tests in debug and release, then the complete
differential and paired release experiment. It runs for relevant pull-request
paths or by manual dispatch, with read-only repository permissions. Correctness
and command failures fail the run; timing noise is not turned into a brittle
automatic performance threshold.

The [final evidence package](../Benchmarks/ExternalSubtitleConversion/evidence/macos-fresh-input/README.md)
retains the original JSON summaries, manifest, environment, regression logs,
every raw timing row, all input fixtures, exact source snapshots, and all
command/stdout/stderr receipts. Compressed receipts keep the permanent record
small; no build products are committed. Packaging provenance includes the
downloaded artifact's SHA-256 and verification of the preserved bytes, so the
research remains inspectable after the hosted artifact expires.
