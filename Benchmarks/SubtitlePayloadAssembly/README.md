# Subtitle payload assembly research

## Result and qualification

**A modest Linux component improvement, pending native macOS qualification.**
The first completed cohort shows 0.59–2.36% lower median paired CPU time across
the eight ordinary 2,000-cue workloads. Candidate conversions were faster in
59 of those 64 pairs; every ordinary workload also favors the candidate when
AB and BA orders are summarized separately. This supports a small simplification
to payload assembly, not a claim about visible player latency.

The evidence comes from the
[successful Linux job](https://github.com/Jagalite/illiquid/actions/runs/40639731826/job/122654818114)
at commit `3fab422b5832bcd8dd44655a78b3f72df7568b06`. Native macOS
qualification has not completed: its runner remained queued and the run was
superseded by the evidence-upload fix. The subsequent workflow changes leave
the measured production source, tests, driver, and shared runner unchanged.
The overall run's cancelled status does not replace the Linux job's successful
conclusion; inspect the job link and preserved receipts.

This is one hosted x86_64 Linux machine with Swift 6.3.2, optimized separate
modules, and no cross-module optimization. We have not measured native
Foundation behavior, end-to-end player latency, memory usage, allocation
counts, or libass rendering performance. Keep the PR in draft until native
qualification is available.

## Candidate

The external SRT/WebVTT converter currently maps every accepted cue's payload
lines to escaped strings, joins them into a second string, and interpolates the
joined payload into the final ASS output. The candidate appends the existing
escaped lines directly to that final output, with the same ASS line-break
separator between lines.

This removes the per-cue escaped-line array and joined-payload temporary. It
does not change block parsing, timestamps, cue admission, escaping, or newline
normalization. Empty payloads, empty final lines, and Unicode matching must
retain their exact output bytes. Any benefit must be established by measuring
complete conversions; removing an intermediate allocation alone is not a
player-wide performance result.

## Baseline and protocol

The baseline is the exact converter from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, after the earlier block-traversal
and escaping improvements. Its Git blob and SHA-256 are recorded in
[baseline/manifest.json](baseline/manifest.json). This isolates payload
assembly from the timestamp-parsing and newline experiments on other branches.

The small `run.py` entry point reuses
`Benchmarks/ExternalSubtitleConversion/run.py` without changing that
experiment's historical defaults. Both variants are built as separate
optimized production modules, then linked to the same driver. The runner
checks complete output UTF-8 bytes and exact errors before timing, validates
result receipts, retains source/compiler/binary hashes and raw observations,
and alternates fresh-process AB/BA pairs. No timing outliers are discarded.

The driver retains the existing converter corpus and adds single-line cues
and bounded 32/256-line payload stress cases. The full differential corpus
contains 1,722 cases; 60 workloads are available for timing. Ordinary fixtures
cover SRT/WebVTT, plain text, multilingual text, literal ASS metacharacters,
CRLF/CR, BOM, empty inputs, and invalid inputs.

Input construction, full-output verification, and warmup are outside the
timed region. Parsing, escaping, output assembly, result consumption, and
result destruction are timed together. These are warm component timings;
they exclude file decoding/I/O, libass rendering, and live player interaction.

## Measurements

Values below are medians in milliseconds per complete conversion. Percentage
changes are **medians of paired candidate/baseline ratios**, not ratios of the
two independently reported medians. Negative percentages mean less time.

| Workload | Baseline ms | Candidate ms | Paired wall change | Paired CPU change | Faster CPU pairs |
|---|---:|---:|---:|---:|---:|
| `srt-1-plain` | 0.012 | 0.012 | 0.09% | 0.09% | 3/8 |
| `vtt-1-plain` | 0.020 | 0.019 | -0.26% | -0.27% | 5/8 |
| `srt-2000-plain` | 27.559 | 27.066 | -1.34% | -1.32% | 8/8 |
| `vtt-2000-plain` | 37.871 | 37.355 | -1.34% | -1.35% | 8/8 |
| `srt-2000-multilingual` | 32.163 | 31.489 | -2.13% | -2.12% | 8/8 |
| `vtt-2000-multilingual` | 42.579 | 42.146 | -0.91% | -0.91% | 6/8 |
| `srt-2000-escaped` | 28.722 | 28.164 | -2.37% | -2.36% | 8/8 |
| `vtt-2000-escaped` | 39.100 | 38.764 | -0.88% | -0.88% | 6/8 |
| `srt-2000-single-line-plain` | 23.671 | 23.329 | -1.43% | -1.42% | 7/8 |
| `vtt-2000-single-line-plain` | 33.944 | 33.784 | -0.61% | -0.59% | 8/8 |
| `srt-100-payload-32-lines-plain` | 7.907 | 7.729 | -2.25% | -2.24% | 8/8 |
| `vtt-100-payload-32-lines-plain` | 8.457 | 8.267 | -2.07% | -2.08% | 8/8 |
| `srt-100-payload-256-lines-escaped` | 89.922 | 89.248 | -0.68% | -0.67% | 6/8 |
| `vtt-100-payload-256-lines-escaped` | 90.534 | 89.735 | -0.54% | -0.53% | 8/8 |
| `srt-empty` | 0.000182 | 0.000183 | 0.37% | 0.38% | 4/8 |
| `vtt-missing-signature` | 0.000501 | 0.000534 | 6.37% | 6.37% | 0/8 |

The 32- and 256-line payload cases are bounded stress workloads, not typical
cue shapes. Ordinary workloads include both the existing two-line fixtures and
new single-line fixtures. The useful gains are small: the independently
reported ordinary-case medians differ by roughly 0.16–0.67 ms per conversion.

The one-cue and empty-input controls are mixed. The missing-WebVTT-signature
control is slower in all eight pairs: +6.37% paired CPU time, about 33 ns by
difference of CPU medians (roughly 501 ns to 534 ns). The changed loop is not
reached for this input; the cause of that measured binary-level difference
has not been isolated. It is retained as a regression rather than explained
away. The largest retained outlier is a +19.93% CPU pair for the escaped
WebVTT workload. No samples were removed or replaced.

The cohort has 256 observations: 16 cases, eight adjacent fresh-process pairs
per case, with four AB and four BA orders. Case traversal also reverses each
round. All timed samples span 145.5–190.2 ms. This is an internally consistent
single-run result; cross-machine and native reproducibility remain open.

## Correctness and evidence

The existing regression script passed **36 tests in two suites** on each of
baseline debug, candidate debug, baseline release, and candidate release
with warnings treated as errors. These are four executions of the same suite,
not 144 unique tests. New tests specify exact expected ASS bytes for empty
and whitespace cues around rejected cues, Unicode combining marks, literal
versus inserted line-break escapes, trailing LF, and up to 4,096 payload lines.

Before timing, the runner compared complete UTF-8 output bytes and exact
errors for **1,722 differential cases**. It then validated every timed sample
against those verified records, including output fingerprints, iteration
counts, and result-consumption checksums.

Preserved evidence:

- [Source/compiler/binary manifest](evidence/linux-20261028-0548/manifest.json)
- [Benchmark configuration](evidence/linux-20261028-0548/benchmark.json) and [calibration](evidence/linux-20261028-0548/calibration.json)
- [All 256 raw observations](evidence/linux-20261028-0548/measurements.jsonl) and [computed summary](evidence/linux-20261028-0548/summary.json)
- [Independent audit](evidence/linux-20261028-0548/audit.json), including exact per-order results
- [Four test logs](evidence/linux-20261028-0548/tests) and [CI provenance](evidence/linux-20261028-0548/provenance.json)

The independent audit recalculated the summary exactly, checked every ordered
pair, validated checksum tokens from the driver's contract, and matched
baseline/candidate source, driver, and shared-runner hashes.

There is an evidence-retention limitation for this first cohort: the artifact
uploader used a host temporary path while the benchmark ran under a container
path, so its ZIP retained only the test logs. The timing/configuration files
above were recovered from the successful job's explicit log receipt blocks.
The log reports the full differential pass and verification-index SHA-256,
but the full verification index and output vectors were not recovered. The
independent audit therefore cannot repeat those full byte comparisons from
this saved cohort alone. The workflow now stages all evidence relative to
the workspace, including verification files, for subsequent runs.

The first setup attempt ran the test suites successfully but could not start
the benchmark because Python was absent from the Swift container. It produced
no timing cohort. The workflow now installs Python. Neither that setup failure
nor a queued job is counted as a performance result.

## Reproduce

Use Swift 6.1 or later. Follow the repository's AGENTS.md build coordination:
use Kyoto when available; otherwise explain the absence and serialize builds.
Kyoto was unavailable in the hosted runner, so this qualification serialized
builds in isolated temporary packages. It did not build the full player or
perform live UI validation.

Run the candidate regression suite:

```sh
bash Scripts/test-external-subtitle-regressions.sh -c debug --jobs 2 --no-parallel -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release --jobs 2 --no-parallel -Xswiftc -warnings-as-errors
```

The focused workflow additionally stages the frozen baseline and runs the
same test files against it in both configurations. To reproduce the exact
timed case selection locally:

```sh
python3 Benchmarks/SubtitlePayloadAssembly/run.py benchmark \
  --rounds 8 --target-ms 150 \
  --output /tmp/illiquid-subtitle-payload-results \
  --case srt-1-plain \
  --case vtt-1-plain \
  --case srt-2000-plain \
  --case vtt-2000-plain \
  --case srt-2000-multilingual \
  --case vtt-2000-multilingual \
  --case srt-2000-escaped \
  --case vtt-2000-escaped \
  --case srt-2000-single-line-plain \
  --case vtt-2000-single-line-plain \
  --case srt-100-payload-32-lines-plain \
  --case vtt-100-payload-32-lines-plain \
  --case srt-100-payload-256-lines-escaped \
  --case vtt-100-payload-256-lines-escaped \
  --case srt-empty \
  --case vtt-missing-signature
```

The output directory must be new or empty. Omit the `--case` arguments to
measure all 60 available workloads. The runner always verifies the full
1,722-case corpus before measuring the selected cases. Keep raw results from
every complete run; do not select a favorable subset.

For a newly generated output directory with its verification index retained:

```sh
python3 Benchmarks/SubtitlePayloadAssembly/run.py summarize \
  --output /tmp/illiquid-subtitle-payload-results
```
