# Media filename recognition: avoid repeated tag cleanup

## Outcome and scope

The candidate removes one redundant regular-expression replacement from
`titleAndYear`. In the initial native macOS cohort, named episodes, folder
episodes, movies, plain unknown names, and tagged / Unicode names show median
paired time reductions of **4.50–7.38%**, with the candidate faster in all six
pairs for each of those workloads. The short mixed-library observation is
inconclusive: its median paired estimate is **−1.17%**.

This is a component benchmark of complete filename recognition. It does not
measure directory scanning, library loading, playback, frame rate, or memory
use. All original measurements are retained, including the mixed-library result.

## Why this area

`MediaNameRecognition.recognize(relativePath:)` supplies the fallback identity
used by [MediaSidecarReader](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift)
and [SourceTreeProjectionInput](../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift).
It processes filenames and folder titles as metadata and media browser entries
are built.

The baseline `titleAndYear` first removes brace and bracket tags, then passes the
already-stripped string (or its title prefix) to `clean`, which runs the same tag
replacement again. The hypothesis is that avoiding the second pass reduces the
cost of recognition without changing any metadata.

The [production patch](../Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift)
adds a private `cleanTagless` helper containing the existing punctuation and
Unicode whitespace cleanup. `clean` removes tags once and delegates to that
helper. The two calls inside `titleAndYear` use the helper directly because
their input has already had tags removed.

The tag pattern consumes a complete `{...}` or `[...]` match. After all matches
have been removed, no surviving opener can have a corresponding surviving
closer: such a pair would have been matched in the first pass. Taking a prefix
also cannot create a pair. Malformed residual punctuation still goes through
the same final cleanup chain. No folder parsing, date parsing, regular-expression
patterns, public result fields, or heuristics were changed.

## Native validation

The [successful macOS run](https://github.com/Jagalite/illiquid/actions/runs/39070454942)
tested cleanup-only commit
[`9200ebe27542bfe2cf54d4ca7a0af7a182090336`](https://github.com/Jagalite/illiquid/commit/9200ebe27542bfe2cf54d4ca7a0af7a182090336).

- 20 filename recognition tests passed in debug and 20 in release, with
  compiler warnings treated as errors.
- 32 related metadata integration tests passed.
- 2,601 comparisons matched the frozen baseline exactly, including UTF-8 bytes
  for every string field and the derived series title, display name, and section.
- Every timed pair agreed on its operation count, warmup checksum, and checksum
  consuming the complete retained results.

The regression suite covers folder/year inference, insufficient episode
identity, yearless series folders, specials, mismatched and explicit prefix
years, nested/crossed/unclosed tags, generic movie filenames, emoji, Japanese
text, and decomposed combining marks. The differential corpus adds 2,000
deterministically generated paths and every timed input.

The unit test script builds the actual Foundation-only source in a temporary
Swift package. The existing NFO regression script covers related metadata
integration. These checks do not constitute a full application build or
playback test.

## Initial measurements

**Environment:** Apple M1 (Virtual), three logical CPUs, macOS 26.6.2 (25G83),
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), arm64 target macOS 26.0. Baseline and
candidate used the same optimized compiler flags and harness.

Each workload used **six fresh-process pairs**, with balanced baseline-first
and candidate-first order. Each process completed 16 passes over its workload,
or 512–1,792 recognitions. Two untimed passes warmed up Foundation and static
regular expressions. No observations were removed.

| Workload | Baseline median, µs/name | Candidate median, µs/name | Median paired time reduction | Candidate faster |
|---|---:|---:|---:|---:|
| Mixed library | 28.701 | 28.098 | -1.17% | 2/6 |
| Named episodes | 41.905 | 39.984 | 4.58% | 6/6 |
| Folder episodes | 29.910 | 28.137 | 7.38% | 6/6 |
| Movies | 22.440 | 21.173 | 4.50% | 6/6 |
| Dated episodes | 32.333 | 31.383 | 2.41% | 5/6 |
| Plain unknown names | 25.923 | 23.775 | 6.61% | 6/6 |
| Tagged / Unicode names | 32.938 | 31.091 | 5.67% | 6/6 |
| Long-name stress | 430.143 | 413.642 | 3.09% | 6/6 |

Positive paired reductions mean less elapsed time. The paired statistic is
`100 × (1 − median(candidate_elapsed / baseline_elapsed))`; it is not the ratio
of the two independent medians in the preceding columns. Consequently, the
mixed-library independent medians favor the candidate while its paired estimate
is slightly negative. Only two of its six pairs favor the candidate.

The mixed-library timed intervals were approximately 47–60 ms. Because this
short mixed sample was inconsistent while the other cases were mostly
consistent, a targeted follow-up was specified with the **same production
source and harness**, 12 balanced pairs, and 128 iterations per process. That
changes the observation size to 14,336 recognitions, approximately eight times
the initial duration. It is a separate cohort; the initial result is retained
and the two cohorts are not pooled.

## Longer mixed-library follow-up

Pending the targeted native run at
[39071610024](https://github.com/Jagalite/illiquid/actions/runs/39071610024),
commit `667dd24420504b4d9d5b4647bfe4a98ee950a04f`.
The full 2,601-path equivalence check still runs before timing the selected
workload. The new runner option only selects the timing cases.

## Measurement method and limits

The baseline source is frozen at main revision
[`68274d1b09dcc866296321a5a8858efc297c4f19`](https://github.com/Jagalite/illiquid/commit/68274d1b09dcc866296321a5a8858efc297c4f19).
The runner verifies its SHA-256 before building. For the correctness oracle,
it renames only the baseline enum declaration and shares the byte-identical
result type; it rejects any change to that result declaration.

Baseline and candidate each compile as a separate shared Swift module, using
`-swift-version 6 -O -whole-module-optimization -warnings-as-errors`. The
harness compiles separately and consumes every result. Input construction,
array capacity reservation, warmup, and the full-result checksum are outside
the timed interval. The interval includes recognition and appending results
to the reserved array. This common append/retention cost remains in both
variants.

The workloads are synthetic in-memory paths. Their frequency in a real
library is unknown. Long-name stress deliberately includes strings exceeding
real filesystem component limits and is not evidence for normal filename
prevalence. Warmup excludes initial regex compilation; the benchmark does not
measure first-use latency. It also excludes I/O, sidecars, UI projection and
rendering, decoding, playback, CPU utilization, resident memory, and energy.

A virtual hosted runner and a small number of pairs limit precision. Observed
minima and maxima in the raw summary are ranges, not confidence intervals.
Results support a small recognition optimization, not a claim about overall
player performance.

A separate Linux contingency passed the same 20 debug, 20 release, and 32
integration tests. Its [timing attempt](https://github.com/Jagalite/illiquid/actions/runs/39071166068)
failed before measurement when the **unmodified baseline** crashed in Linux
Foundation's path-component handling. It provides no Linux performance
estimate; no failed or partial Linux measurements are included above. The
Linux-only experiment workflow is not part of this change.

## Reproduce and inspect

See [the benchmark README](../Benchmarks/MediaNameRecognition/README.md) for
the complete protocol and retained artifact format.

```sh
bash Scripts/test-media-name-recognition.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-media-name-recognition.sh --jobs 2 -c release -Xswiftc -warnings-as-errors
bash Scripts/test-nfo-metadata-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors

# Reproduce the initial all-workload design.
python3 Benchmarks/MediaNameRecognition/run.py \
  --output /tmp/illiquid-recognition-all --rounds 6 --iterations 16

# Reproduce the longer mixed-library design.
python3 Benchmarks/MediaNameRecognition/run.py \
  --output /tmp/illiquid-recognition-mixed \
  --workloads mixed-library --rounds 12 --iterations 128
```

Use an absent or empty output directory each time. A Swift 6 toolchain and
Python 3 are required; the macOS native dependency SDK is not needed for this
isolated benchmark.

Committed [initial receipts](../Benchmarks/MediaNameRecognition/results/macos-initial/)
include the manifest, exact-output receipt, all 96 timed observations, summary,
and workflow provenance. They were restored from the successful workflow's
machine-readable log markers. The restored equivalence, JSONL measurements,
and summary match their original manifest-recorded SHA-256 hashes. The
[full original artifact](https://github.com/Jagalite/illiquid/actions/runs/39070454942/artifacts/12114943323)
also contains the fixture catalog, exact sources, commands, and process logs,
subject to GitHub's artifact retention period.

| Source identity | SHA-256 |
|---|---|
| Frozen baseline | `b9e75457eccae3c30e09817ce3520750429935b2af646532ac290b18e4aee8fb` |
| Cleanup-only candidate | `fd238cf9d682b42ad4deb1bd8e54dbf09a12fceb4aa3d4fabeb6f7bff3a1ee03` |
| Harness, both macOS cohorts | `90d9f13460e63148cadac6db33834e6aaaf093048047da83f4043050fb1df563` |
| Full fixture catalog | `413f9cb05d93e6a45dc601721e9fd4246793e72f46900a1437590f98beb5b452` |

Each manifest also identifies its runner version, compiler invocations, and
executable/library hashes. The initial runner is preserved in commit
`9200ebe27542bfe2cf54d4ca7a0af7a182090336`; the follow-up uses the optional
`--workloads` selection added in
`667dd24420504b4d9d5b4647bfe4a98ee950a04f`.
