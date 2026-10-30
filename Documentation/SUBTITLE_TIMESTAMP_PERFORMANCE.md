# External subtitle timestamp performance

## Outcome and qualification

The fixed-width timestamp fast path reduces full in-memory SRT/WebVTT conversion
time in the completed Linux experiment. Against main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, the 24 ordinary timestamp workloads
(1/100/2,000/10,000 cues with plain, multilingual, or ASCII-escaped payloads)
improved by 8.83–15.23% in median paired wall time. The short WebVTT control
improved by 15.43%. Every timed result and all 13,942 differential cases preserved
exact output bytes and typed errors.

This is a component result on Linux x86_64, not a macOS performance qualification.
The [macOS run](https://github.com/Jagalite/illiquid/actions/runs/40634454540)
is queued at the time of this research checkpoint. The
[completed Linux run](https://github.com/Jagalite/illiquid/actions/runs/40635444010)
passed both debug and release regression tests and all measurements.

The small costs are retained in the results: unpadded SRT hours and large-hour
fallbacks are 1.00–1.09% slower (about 0.10–0.11 ms per 1,000 cues). Empty SRT and
WebVTT inputs are 3.59% and 3.81% slower, respectively, amounting to about 7 ns
and 22 ns per conversion. The empty-input paths do not parse timestamps; this
experiment does not establish the cause of those small binary-level differences.
No timing samples were discarded.

## Product path and change

`PreparedExternalSubtitle.prepare` calls
`SubtitlePipeline.prepareExternalData` for external text subtitles.
For SRT/VTT, that method reads a bounded file, decodes its text, invokes the
production `ExternalTextSubtitleConverter.convert`, checks the output size,
and materializes ASS data for libass. This work occurs during opening and
subtitle track changes.

The existing timestamp parser splits hours/minutes/seconds and fractions into
arrays for every cue endpoint. The change first tries these complete ASCII forms:

- SRT: `HH:MM:SS,mmm` and `HH:MM:SS.mmm`.
- WebVTT: `HH:MM:SS.mmm` and `MM:SS.mmm`.

The fast path reads available contiguous UTF-8 storage, validates every digit
and separator, checks minute/second bounds, and computes the existing integer
millisecond and rounded centisecond values. It allocates no split arrays.
The existing parser handles every input that does not successfully match.

The fallback is essential: the accepted SRT forms `0:00:00.0000` and
`000:00:00.00` also have 12 bytes. Length alone cannot determine validity.
Whitespace trimming and WebVTT settings extraction still happen before parsing.
Large hours, short/overlong SRT fractions, malformed fields, and representation
bounds continue through the general parser.

The production diff adds 42 lines. It introduces no persistent cache or dependency.

## Experimental design

- Baseline: main `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, source Git blob
  `db1fe944a1de9a4feac565aab4f3dbf6ec472292`.
- Candidate source: commit `87f34cfeefef5555c74e0e71c36cdd1f7d4d0418`.
  The measured Linux revision `44b5512556536145ed33f994eaa0b1e43af3bb6c`
  adds only the portable CI workflow to that source.
- Compiler: Swift 6.4, language mode 6, `-O -whole-module-optimization`,
  warnings treated as errors. Both variants use the same compiler and driver,
  as separately optimized modules without cross-module optimization.
- Host: Linux 6.17.0-1022-azure, x86_64, glibc 2.39.
- Workloads: the existing 36 cases plus short WebVTT timestamps, unpadded SRT
  hours, and large hours in each format.
- Timing: ten fresh-process pairs per case, alternating AB/BA and reversing
  case traversal. The baseline calibrates one iteration count per case used
  for both variants. All 800 observations are retained.
- Input construction, initial full-output checks, and warmup are outside timing.
  Parsing, escaping, event/output construction, and consumption of every
  returned result are inside. Full outputs are checked again after timing.

The runner's new `--baseline-ref` option resolves a revision to an immutable
commit, records its Git blob and SHA-256, and compiles the exact materialized
source. Omitting the option preserves the older frozen baseline used by previous
research. The timestamp results use current main, so earlier parsing/escaping
and memory improvements are not credited to this change.

The existing macOS workflow also runs a separate historical memory comparison.
That comparison has its own older baseline; any differences it reports are not
evidence of a timestamp-specific memory improvement.

## Complete Linux results

Times are medians per complete conversion in milliseconds. Percentages are the
median of the ten paired candidate/baseline changes, rather than a ratio of the
two displayed medians. Negative changes indicate less time. Per-pair values,
ranges, CPU times, and all raw observations are included in the evidence files.

| Case | Baseline ms | Candidate ms | Paired wall change | Paired CPU change |
| --- | ---: | ---: | ---: | ---: |
| `srt-1-plain` | 0.012088 | 0.010246 | -15.23% | -15.23% |
| `srt-100-plain` | 1.385614 | 1.196135 | -13.49% | -13.47% |
| `srt-2000-plain` | 27.792664 | 24.001765 | -13.55% | -13.57% |
| `srt-10000-plain` | 139.430220 | 121.014918 | -13.30% | -13.29% |
| `srt-1-multilingual` | 0.013623 | 0.011692 | -14.04% | -14.06% |
| `srt-100-multilingual` | 1.589263 | 1.394519 | -12.30% | -12.29% |
| `srt-2000-multilingual` | 31.910403 | 28.096606 | -11.93% | -11.94% |
| `srt-10000-multilingual` | 160.710873 | 142.015572 | -11.81% | -11.79% |
| `srt-1-escaped` | 0.012588 | 0.010723 | -14.79% | -14.79% |
| `srt-100-escaped` | 1.434065 | 1.249022 | -13.10% | -13.09% |
| `srt-2000-escaped` | 28.894696 | 25.107705 | -13.22% | -13.21% |
| `srt-10000-escaped` | 145.102985 | 126.492740 | -12.76% | -12.76% |
| `vtt-1-plain` | 0.019643 | 0.017718 | -9.83% | -9.83% |
| `vtt-100-plain` | 1.896130 | 1.709376 | -9.73% | -9.74% |
| `vtt-2000-plain` | 38.098013 | 34.390140 | -9.74% | -9.73% |
| `vtt-10000-plain` | 190.767567 | 172.403743 | -9.60% | -9.60% |
| `vtt-1-multilingual` | 0.021709 | 0.019795 | -8.86% | -8.85% |
| `vtt-100-multilingual` | 2.116125 | 1.920044 | -9.20% | -9.22% |
| `vtt-2000-multilingual` | 42.322263 | 38.620857 | -8.83% | -8.83% |
| `vtt-10000-multilingual` | 211.823153 | 193.374154 | -8.88% | -8.87% |
| `vtt-1-escaped` | 0.020214 | 0.018289 | -9.45% | -9.44% |
| `vtt-100-escaped` | 1.951708 | 1.771054 | -9.19% | -9.20% |
| `vtt-2000-escaped` | 39.349187 | 35.486707 | -9.67% | -9.65% |
| `vtt-10000-escaped` | 196.521228 | 177.654074 | -9.67% | -9.66% |
| `vtt-1000-short-timestamps` | 10.180531 | 8.636939 | -15.43% | -15.44% |
| `srt-1000-unpadded-hour` | 10.410890 | 10.513745 | 1.09% | 1.10% |
| `srt-1000-large-hour` | 11.038941 | 11.152505 | 1.00% | 0.98% |
| `vtt-1000-large-hour` | 11.801267 | 11.910745 | 1.01% | 1.02% |
| `srt-100-plain-crlf` | 1.977386 | 1.788390 | -9.56% | -9.54% |
| `vtt-100-multilingual-crlf` | 3.477635 | 3.287366 | -5.30% | -5.32% |
| `srt-100-escaped-cr` | 2.043887 | 1.854864 | -9.19% | -9.18% |
| `vtt-100-escaped-bom` | 1.968701 | 1.778538 | -9.60% | -9.59% |
| `srt-empty` | 0.000177 | 0.000184 | 3.59% | 3.60% |
| `vtt-empty` | 0.000641 | 0.000663 | 3.81% | 3.83% |
| `vtt-missing-signature` | 0.000501 | 0.000493 | -1.47% | -1.46% |
| `srt-no-valid-cues` | 0.011614 | 0.009880 | -14.80% | -14.78% |
| `srt-2000-unicode-escaped` | 78.096699 | 74.517536 | -4.79% | -4.78% |
| `srt-2000-combining-escaped` | 47.727767 | 44.095861 | -7.87% | -7.87% |
| `vtt-2000-unicode-escaped` | 88.930597 | 85.203081 | -4.24% | -4.24% |
| `vtt-2000-combining-escaped` | 58.774830 | 54.641087 | -7.09% | -7.07% |

For example, 2,000 plain SRT cues changed from 27.79 ms to 24.00 ms
(13.55% lower paired wall time), and 2,000 plain WebVTT cues changed from
38.10 ms to 34.39 ms (9.74% lower). The 10,000-cue plain cases saved about
18.4 ms per conversion. These are full converter timings, not isolated
timestamp-loop measurements.

## Correctness and evidence

The completed Linux job passed 36 parser/escaping tests in two suites in both
debug and release configurations with warnings treated as errors.
The added tests have explicit expected results for second/minute/hour rounding,
carry from 99 to 100 hours, short WebVTT timestamps and settings, Unicode
whitespace, and legacy SRT spellings.

The differential corpus checks 13,942 cases, including 12,240 timestamp
mutations: each position in four timestamp spellings is replaced with every
ASCII value, seven Unicode atoms, or an empty string, at both cue endpoints.
For these mutations the unchanged parser supplies the output/error oracle.
The benchmark does not contain a second parser predicting acceptance.
Comparisons use exact UTF-8 bytes, so canonical Unicode equivalence cannot
hide an output change.

Permanent evidence is in
[`Benchmarks/ExternalSubtitleConversion/evidence/timestamp-fast-path/linux`](../Benchmarks/ExternalSubtitleConversion/evidence/timestamp-fast-path/linux):

- `manifest.json`: compiler, flags, source/module/binary hashes, commands and revisions.
- `benchmark.json` and `calibration.json`: workload order and operation counts.
- `measurements.jsonl`: all 800 ordered observations.
- `summary.json`: complete paired wall/CPU statistics and individual ratios.
- `validation.json`: CI identity, test receipts and differential/cohort counts.

The CI artifact additionally contains source snapshots, build/process logs, and
compressed complete differential outputs. Artifact retention is 14 days; the
checked-in evidence and deterministic fixtures allow reproduction afterward.

## Reproduce

The converter is Foundation-only and does not require FFmpeg, libass, or an app
launch. Use Swift 6.1 or later. On macOS, use the repository's Xcode 26.6 setup;
the benchmark targets macOS 26. On a machine with the shared Kyoto queue,
submit build/test commands through it as required by `AGENTS.md`. Hosted CI
runners use direct, serial component builds.

```sh
bash Scripts/test-external-subtitle-regressions.sh -c debug -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/ExternalSubtitleConversion/run.py benchmark \
  --baseline-ref ea2ff568237e2667f7b1aeee67b11a44ebe95b72 \
  --rounds 10 --target-ms 100 --output /tmp/subtitle-timestamp-results
python3 Benchmarks/ExternalSubtitleConversion/run.py summarize \
  --output /tmp/subtitle-timestamp-results
```

Use a new or empty output directory. Run timings serially without concurrent
builds or other benchmarks. Source/compiler snapshots and hashes in the output
identify the exact cohort.

## Limits

These are warmed, synthetic, in-memory conversions on a shared CI runner.
The timing excludes file I/O, character decoding, libass installation,
rendering, visible subtitle-load latency, playback frame rate, and energy.
No full app build or live playback qualification is established by the
Foundation-only job. macOS results must be reported separately when available.
