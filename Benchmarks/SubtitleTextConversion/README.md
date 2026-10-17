# External text subtitle conversion performance

## Scope and change

`SubtitlePipeline.prepareExternalData` converts decoded SRT and WebVTT text to
ASS through `ExternalTextSubtitleConverter.convert`. The original converter ran
three Foundation `replacingOccurrences` operations on every caption line to
escape backslashes and braces, including ordinary dialogue with nothing to
escape. This experiment changes only that per-line escaping work.

The replacement has three paths:

- Lines without an escape character return their text directly, including
  ordinary Unicode captions.
- ASCII lines containing backslashes or braces construct the escaped output in
  one pass, escaping each original special byte once.
- Non-ASCII lines containing escape characters retain the original Foundation
  replacement chain.

The third path protects a compatibility detail discovered during review.
Foundation's nonliteral search leaves some punctuation-plus-combining-mark
sequences unchanged. For example, the original backslash followed by U+0301
stays at UTF-8 bytes `[92, 204, 129]`. An initial universal byte scanner inserted
an extra backslash; a focused 54-case probe found 30 differences. That version
was rejected before the accepted timing experiment. The final implementation
preserves the old behavior instead of changing subtitle interpretation during
a performance optimization.

No parser, timestamp validation, cue ordering, error type, encoding policy,
line-break joining, file limit, or libass behavior is intentionally changed.

## Correctness qualification

The existing isolated runner compiles the actual production converter and its
Swift Testing suite. The final baseline passes all 18 tests in debug; the final
candidate passes the same 18 tests in debug and release, with compiler warnings
treated as errors. Three added tests cover adjacent/repeated escapes, literal
ASS-like sequences, Unicode and control bytes, empty/trailing caption lines,
both formats, and all three newline conventions.

An independently written differential harness also compares the complete
converted ASS bytes or typed conversion errors across **18,779 generated
whole-file cases**. There are **zero differences**: 18,536 successful outputs,
58 missing-WebVTT-signature errors, 87 invalid-SRT errors, and 98 invalid-WebVTT
errors. Coverage includes exhaustive short payloads, 2,040 Unicode adjacency
cases, 420 newline-boundary cases, malformed timestamps and signatures, metadata
recovery, 1,200 deterministic mutations, and long payloads. Byte equality is
deliberate: Swift String equality can consider different Unicode encodings
equivalent.

The differential baseline is the complete original source with only its enum
namespace renamed so both versions can link into one verifier. Timing builds
do not rename or rewrite either production source. Independent review found no
remaining correctness issue in the final production diff.

## Timing method

The pinned baseline is commit
`68274d1b09dcc866296321a5a8858efc297c4f19`. Both versions compile the complete
converter with the same frozen driver using Swift 6.3.2,
`swiftc -O -swift-version 6`, on x86_64 Linux. macOS runs additionally target the
application's macOS 26 deployment version.

The timer encloses **one complete in-memory conversion**. Input loading,
fixture construction, one warmup per process, full output-byte verification,
and JSON serialization occur outside the measured interval. Every emitted
fixture must contain the requested number of cues; every timed conversion must
match the full original output byte for byte.

The default matrix contains 36 workloads: three cue counts, six caption
scenarios, and both SRT and WebVTT. Each workload runs eight fresh-process pairs
with baseline/candidate order alternating AB/BA, and three timed conversions
per process. That gives **576 measured processes and 1,728 timed conversions**.
The reported value is the median of the eight per-process medians, not an
individual-call percentile. The raw evidence retains all rounds, process order,
process-median ranges, commands, input/output hashes, source/compiler/executable
receipts, and source-stability checks. No timing threshold is a test assertion.

| Scenario | Caption content |
|---|---|
| `ascii` | One line of ordinary English dialogue |
| `unicode` | Accented/decomposed text, CJK, Korean, Arabic, and emoji without escapes |
| `multiline` | Two lines of ordinary dialogue |
| `mixed` | Ordinary dialogue; every tenth cue contains literal paths/braces and a second line |
| `escape-dense` | ASCII stress control with repeated backslashes, braces, and ASS-like text |
| `unicode-escaped` | Unicode plus escapes and combining sequences; exercises the compatibility fallback |

The cue counts are 50, 1,500, and 10,000. At the generated 2.5-second spacing,
1,500 cues span about 63 minutes; 10,000 cues are a roughly seven-hour stress
input. All fixtures are synthetic. An earlier concurrent smoke run used the
rejected first candidate and is excluded from accepted results. Environment
setup failures are also excluded rather than reported as passing checks.

## Results

The optimization is supported by the larger ordinary-caption workloads. For
1,500 cues, median within-pair reductions are **21.2–33.7%** across ASCII,
Unicode, multiline, and mixed captions in both formats. ASCII-only escape-dense
stress inputs improve by **55.2–64.3%**. At 10,000 cues, the corresponding
ordinary-caption range is **21.4–37.5%**. These are descriptive results from
this host, not statistical confidence bounds or a guarantee for every file.

The Unicode-with-escapes fallback has no consistent measured gain: its paired
reductions range from **-0.6% to -0.1%** at 1,500 cues and **-2.0% to +1.5%**
at 10,000 cues. It deliberately retains the original work plus a small scan.
No reliable small-file performance claim is made from the 50-cue measurements.

Cloud timings varied substantially, including periods with two distinct timing
levels. After observing this in the unchanged-work control, we added an
independent analysis of **every** already recorded pair. The table retains the
original absolute medians and their derived percentage beside the median of
within-pair candidate/baseline ratios. No observations were dropped or timings
rerun. For example, the 10,000-cue Unicode-with-escapes SRT control has a 19.6%
slowdown from independent variant medians but a 2.0% median paired slowdown;
this illustrates why neither aggregate should be presented as precise Mac
application latency. The analyzer validates the full workload matrix and
actual recorded AB/BA process/command order before producing paired results.

Negative reductions mean slower measurements. “Faster pairs” counts how often
the candidate's per-process median was below its matched baseline.

| Cues | Scenario | Format | Baseline ms | Candidate ms | Reduction from medians | Paired reduction | Faster pairs |
|---:|---|---|---:|---:|---:|---:|---:|
| 50 | ascii | srt | 1.468 | 1.387 | 5.5% | 21.9% | 6/8 |
| 50 | ascii | webvtt | 2.651 | 1.991 | 24.9% | 24.9% | 7/8 |
| 50 | unicode | srt | 2.035 | 1.763 | 13.4% | 15.9% | 7/8 |
| 50 | unicode | webvtt | 2.329 | 2.514 | -7.9% | 17.3% | 6/8 |
| 50 | multiline | srt | 2.274 | 1.062 | 53.3% | 36.9% | 8/8 |
| 50 | multiline | webvtt | 2.251 | 2.316 | -2.9% | 23.1% | 5/8 |
| 50 | mixed | srt | 2.108 | 0.973 | 53.8% | 32.6% | 7/8 |
| 50 | mixed | webvtt | 1.533 | 1.201 | 21.7% | 21.8% | 6/8 |
| 50 | escape-dense | srt | 3.195 | 2.135 | 33.2% | 34.6% | 8/8 |
| 50 | escape-dense | webvtt | 6.003 | 2.101 | 65.0% | 62.4% | 8/8 |
| 50 | unicode-escaped | srt | 2.364 | 1.690 | 28.5% | 3.7% | 6/8 |
| 50 | unicode-escaped | webvtt | 1.895 | 2.019 | -6.6% | -5.8% | 1/8 |
| 1,500 | ascii | srt | 37.127 | 26.942 | 27.4% | 27.2% | 8/8 |
| 1,500 | ascii | webvtt | 46.499 | 36.318 | 21.9% | 21.2% | 8/8 |
| 1,500 | unicode | srt | 51.467 | 46.853 | 9.0% | 28.8% | 6/8 |
| 1,500 | unicode | webvtt | 59.806 | 43.391 | 27.4% | 27.7% | 8/8 |
| 1,500 | multiline | srt | 49.661 | 33.103 | 33.3% | 33.7% | 8/8 |
| 1,500 | multiline | webvtt | 59.600 | 43.363 | 27.2% | 30.0% | 7/8 |
| 1,500 | mixed | srt | 38.607 | 27.358 | 29.1% | 29.3% | 8/8 |
| 1,500 | mixed | webvtt | 47.762 | 36.399 | 23.8% | 24.0% | 8/8 |
| 1,500 | escape-dense | srt | 106.526 | 37.746 | 64.6% | 64.3% | 8/8 |
| 1,500 | escape-dense | webvtt | 106.484 | 47.859 | 55.1% | 55.2% | 8/8 |
| 1,500 | unicode-escaped | srt | 48.589 | 48.877 | -0.6% | -0.1% | 4/8 |
| 1,500 | unicode-escaped | webvtt | 57.763 | 58.324 | -1.0% | -0.6% | 2/8 |
| 10,000 | ascii | srt | 239.021 | 175.674 | 26.5% | 26.5% | 8/8 |
| 10,000 | ascii | webvtt | 301.197 | 236.645 | 21.4% | 21.4% | 8/8 |
| 10,000 | unicode | srt | 348.405 | 232.898 | 33.2% | 35.7% | 8/8 |
| 10,000 | unicode | webvtt | 412.463 | 299.490 | 27.4% | 27.2% | 8/8 |
| 10,000 | multiline | srt | 343.141 | 223.362 | 34.9% | 34.8% | 7/8 |
| 10,000 | multiline | webvtt | 512.451 | 299.573 | 41.5% | 29.1% | 8/8 |
| 10,000 | mixed | srt | 411.996 | 233.696 | 43.3% | 32.9% | 7/8 |
| 10,000 | mixed | webvtt | 415.301 | 245.141 | 41.0% | 37.5% | 6/8 |
| 10,000 | escape-dense | srt | 787.262 | 273.419 | 65.3% | 62.6% | 8/8 |
| 10,000 | escape-dense | webvtt | 1108.140 | 371.938 | 66.4% | 61.0% | 8/8 |
| 10,000 | unicode-escaped | srt | 341.884 | 408.860 | -19.6% | -2.0% | 3/8 |
| 10,000 | unicode-escaped | webvtt | 439.202 | 405.670 | 7.6% | 1.5% | 4/8 |

Full, unfiltered raw observations and receipts are in
[`RESULTS-linux.json.gz`](RESULTS-linux.json.gz). All paired observations and
derived summaries are in [`PAIRED-linux.json.gz`](PAIRED-linux.json.gz).
[`VALIDATION-linux.json`](VALIDATION-linux.json) records source hashes,
regression-log receipts, and the complete differential report/manifest. The
three checked-in `*.log.gz` files contain the verbatim successful component
test output; the receipt includes both compressed and original-byte hashes.
Gzip stores the evidence compactly without changing its contents; the runners
emit ordinary JSON.


These are warmed, in-memory converter wall times. They do not measure first-use
Foundation initialization, file reads, encoding detection, complete subtitle
selection latency, decoder throughput, rendering, frame rate, memory footprint,
or energy. Linux Foundation and the cloud CPU are not a substitute for target
Mac measurements. The focused macOS workflow repeats output/error verification,
debug/release tests, and the 50/1,500-cue timing matrix; the repository's existing
restoration workflow also builds the native app graph and runs its release
suite. Check the PR's macOS results before making application-level claims.

## Reproduce

Use Python 3.10 or newer, Swift 6.1 or newer, and a checkout containing the pinned
baseline commit above. A shallow clone may need that history fetched first.
All output directories must be new or empty. Run only one measurement driver
at a time and finish other builds/tests before collecting timings.

```sh
bash Scripts/test-external-subtitle-regressions.sh -Xswiftc -warnings-as-errors
bash Scripts/test-external-subtitle-regressions.sh -c release -Xswiftc -warnings-as-errors
python3 Benchmarks/SubtitleTextConversion/verify.py \
  --output /tmp/subtitle-conversion-verification
python3 Benchmarks/SubtitleTextConversion/run.py \
  --output /tmp/subtitle-conversion-timing
python3 Benchmarks/SubtitleTextConversion/analyze.py \
  --input /tmp/subtitle-conversion-timing/results.json \
  --output /tmp/subtitle-conversion-timing/paired.json

# Quick correctness/runner smoke; two pairs are not a performance result.
python3 Benchmarks/SubtitleTextConversion/run.py \
  --sizes 50 --repeats 2 --rounds 1 --output /tmp/subtitle-conversion-smoke
```

The runners use `git show` locally to read the baseline and do not fetch
dependencies or build the macOS playback adapters. No model stubs, renderer
replacement, instrumentation in production, or persistent cache is added.
