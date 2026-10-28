# Subtitle timestamp preprocessing performance

## Result and qualification

The ASCII preprocessing bypass reduced measured complete-conversion time on Linux
beyond the fixed-width timestamp parser proposed in [PR #134](https://github.com/Jagalite/illiquid/pull/134).
All 15 ordinary workloads improved in all 150 paired comparisons. Their median
paired wall-time reductions range from **14.77% to 34.15%**. The 2,000-cue plain
SRT and WebVTT cases improve by **23.08%** and **29.72%**, respectively.

**Native macOS qualification is pending.** The macOS job is queued at the time
this report was written. These are Linux component results, not measured Mac
startup, playback, rendering, frame-rate, or energy improvements. Keep the
follow-up PR in draft until its native results have been assessed.

- Immutable baseline: `4b95487493766f627af6b14338613e02dd466b88`, the head of PR #134.
- Measured candidate: `d0e72cc1965603f7cf67cd94c59e7468b77a1293`.
- [Workflow run](https://github.com/Jagalite/illiquid/actions/runs/40638190530).
- [Successful Linux job](https://github.com/Jagalite/illiquid/actions/runs/40638190530/job/122649943872).
- Host: Ubuntu 24.04, x86_64, AMD EPYC 9V45, four exposed logical CPUs.
- Compiler: Swift 6.4.1, release `-O -whole-module-optimization -swift-version 6`.

The comparison measures only the additional preprocessing change. It does not
attribute PR #134's earlier parsing gains to this follow-up.

## Why this work

Every valid cue parses two endpoints. PR #134 removes the split arrays used for
fixed-width numeric fields, but still reaches that helper after Foundation
whitespace trimming and, for WebVTT end timestamps, Character-based settings
splitting. Ordinary authored timestamps use spaces/tabs and ASCII punctuation,
so that preprocessing can also take a direct path.

The production delta is 28 added lines: an early call and a small wrapper. It
examines the entire contiguous UTF-8 value, trims only ASCII space/tab, selects
the first settings-delimited token only for a WebVTT end timestamp, and passes
the resulting buffer to the existing fixed-width parser. The buffer remains
inside the storage closure. No numeric parser or rounding logic is duplicated.

The complete-value ASCII check is intentional. For example, a space followed by
a combining accent is one Swift Character and is not equivalent to the plain
space used by the legacy settings split. Non-ASCII input, noncanonical widths,
unsupported whitespace, malformed values, and unavailable contiguous storage
fall through to PR #134's existing implementation. Removing the wrapper and its
early call reproduces the inherited converter byte for byte.

## Correctness and execution evidence

The same actual production files and golden tests were compiled for both
baseline and candidate, in debug and release, with warnings treated as errors.
All **39 tests in two suites passed in each of four runs**.

Full differential verification covered **14,225 cases per build**, and the
debug/release records matched exactly:

- The 13,942 inherited cases remain intact, including the earlier timestamp
  mutations, parsing/error coverage, and Unicode/escaping corpus.
- 280 additional probes exercise leading/trailing whitespace, settings
  delimiters, Unicode whitespace, combining marks attached to separators, and
  Unicode settings, at both endpoints and in both formats.
- Three timed controls exercise Unicode settings and malformed minute fields.
- New golden tests cover ASCII and Unicode edge trimming, WebVTT settings
  Character boundaries, and positive millisecond intervals whose ASS endpoints
  both round to the same centisecond.

The differential comparison checks exact UTF-8 bytes and exact error outcomes,
rather than Swift String equality or cue counts alone. The saved verification
records have the same SHA-256 in debug and release:
`43946a7edbb0ccf1d35c0a78eb926b507f90760d7f43b2054d6e99c4a5650cd5`.

## Measurement method

The benchmark compiles each whole converter as a separate module, then links the
same driver without cross-module optimization. Input construction and full
output verification are outside timing; parsing, escaping, ASS output
construction, and result consumption are inside. Each sample performs an
untimed warm-up, consumes every returned result with an independently checked
UInt64 checksum, and rechecks complete output after timing.

There are **21 workloads × 10 AB/BA pairs × 2 variants = 420 observations**.
Each observation runs in a fresh process. Variant order alternates, case order
reverses on alternate rounds, and operation counts are identical within each
workload. Both elapsed time and process CPU time are retained. Every sample and
outlier is included.

The requested 350 ms duration is calibrated against the baseline; it is not a
minimum for the faster candidate. The shortest actual observation is
**221.171 ms**, which is retained in the completion receipt.
This is a single hosted-runner experiment; it does not establish a cross-machine
performance distribution.

### All measured workloads

Times below are marginal median milliseconds per complete conversion. Changes
are medians of the ten paired candidate/baseline ratios; they need not equal the
ratio of the displayed marginal medians.

| Workload | Baseline ms | Candidate ms | Paired wall change | Paired CPU change |
| --- | ---: | ---: | ---: | ---: |
| `srt-1-plain` | 0.005756 | 0.004151 | -27.79% | -27.78% |
| `vtt-1-plain` | 0.009809 | 0.007017 | -28.44% | -28.45% |
| `srt-100-plain` | 0.663924 | 0.511202 | -23.65% | -23.65% |
| `vtt-100-plain` | 0.952964 | 0.666986 | -29.98% | -29.98% |
| `srt-2000-plain` | 13.420 | 10.299 | -23.08% | -23.05% |
| `vtt-2000-plain` | 19.193 | 13.498 | -29.72% | -29.72% |
| `srt-10000-plain` | 67.897 | 52.134 | -23.74% | -23.74% |
| `vtt-10000-plain` | 96.162 | 67.300 | -30.02% | -30.02% |
| `srt-2000-multilingual` | 15.738 | 12.630 | -19.88% | -19.88% |
| `vtt-2000-multilingual` | 21.415 | 15.828 | -26.31% | -26.31% |
| `srt-2000-escaped` | 14.105 | 11.052 | -21.71% | -21.70% |
| `vtt-2000-escaped` | 19.697 | 14.027 | -28.85% | -28.84% |
| `srt-100-plain-crlf` | 1.049 | 0.892712 | -15.13% | -15.13% |
| `vtt-100-multilingual-crlf` | 1.824 | 1.554 | -14.77% | -14.77% |
| `vtt-1000-short-timestamps` | 4.761 | 3.147 | -34.15% | -34.15% |
| `srt-1000-unpadded-hour` | 5.833 | 5.881 | 0.61% | 0.61% |
| `srt-1000-large-hour` | 6.229 | 6.225 | 0.36% | 0.37% |
| `vtt-1000-large-hour` | 6.634 | 6.603 | -0.07% | -0.07% |
| `preprocess-control-vtt-2000-unicode-settings` | 17.050 | 15.378 | -9.47% | -9.46% |
| `preprocess-control-srt-2000-malformed` | 8.062 | 8.122 | 0.94% | 0.94% |
| `preprocess-control-vtt-2000-malformed` | 11.262 | 11.278 | 1.00% | 1.00% |

### Fallback costs and limits

The unpadded-hour SRT and large-hour SRT controls have median paired wall changes
of +0.61% and +0.36%, corresponding to median paired increases of 0.036 ms and
0.022 ms per 1,000-cue conversion. Large-hour WebVTT is effectively unchanged
(−0.07%, −0.005 ms). These controls include mixed pair directions and noise;
their small differences should not be described as dependable speedups.

The malformed SRT/WebVTT controls are +0.94%/+1.00%, or median paired increases
of 0.075 ms/0.112 ms per 2,000-cue conversion. The added attempted fast path can
impose work before falling back, so the report retains these tradeoffs.

WebVTT with Unicode settings improves by 9.47%. Only its end timestamp falls
back; its ordinary ASCII start timestamp still benefits. This is not evidence
that fully non-ASCII preprocessing became faster.

The measured operation is warmed complete in-memory subtitle conversion.
Filesystem access, character decoding, libass installation, subtitle rendering,
visible loading latency, the full app graph, and live playback are outside
this qualification. Native macOS behavior and timing must be assessed in the
queued macOS job before promoting the draft.

## Reproduce

From the repository root on an idle Linux or macOS host:

```sh
python3 Benchmarks/SubtitleTimestampPreprocessing/run.py \
  --baseline-ref 4b95487493766f627af6b14338613e02dd466b88 \
  --output /tmp/illiquid-subtitle-preprocessing \
  --pairs 10 --target-ms 350
```

Use a new or empty output directory. The wrapper builds and tests serially.
When Kyoto is available, submit the complete command through the shared queue,
then inspect its show, wait, and logs outcomes as required by AGENTS.md. The
workflow follows that policy and explicitly reports the hosted-runner fallback
when Kyoto is absent.

## Retained evidence

[Raw evidence](evidence/linux/) contains the environment, source/compiler
manifest, golden-test receipts, verification hashes, calibration, complete raw
measurements, ordered cohort configuration, command receipts, summary, and
independent audit. Full differential traces and build/test logs are also in the
workflow's uploaded artifact. The committed compact records preserve the
results after the temporary CI artifact expires.

The baseline and candidate source SHA-256 values are respectively
`307daf66e795d5238d7f28372d350abe3ab260f5a760760ca77a185202cbd12f` and
`4b81ba891e5b140e855df70b3517aee2370fc132f6ca6f92ba54846ff2a8498d`. The final evidence-only commit does not
change the measured production source, tests, driver, runner, or workflow.
