# Singleton thumbnail neighborhood preparation

## Scope

This is a focused follow-up to [PR #132](https://github.com/Jagalite/illiquid/pull/132)
at `8637a8d2c6a628699d5a552a55061b4e0bfc6f10`. That change removes the full-playlist
URL projection from optional background/library thumbnail scheduling, but its
research records extra overhead for a single-item playlist. A separate
concurrent study, [PR #135](https://github.com/Jagalite/illiquid/pull/135), reports
the same small-input tradeoff.

The benchmark compares #132's already-bounded helper with the singleton change,
isolating the remaining construction overhead. Automatic current-video-only
preparation uses a separate scheduler path.

## Change

After the existing search confirms a match, a singleton is handled directly.
The stored URL produces one URL and its zero distance through collection
literals. This avoids range, reservation, and append-loop setup for a result
whose complete shape is already known. The original search and its nil/missing
return path remain in place.

The returned URL and dictionary key come from the playlist item, preserving its
representation even if the query compares equal. The general path continues to
use the first matching URL, ordered bounded window, and last-write distance
semantics for duplicates.

Both baseline and candidate already retain at most nine URLs and nine distances.
This experiment measures construction overhead. It does not establish an
additional asymptotic memory improvement, allocator delta, process RSS reduction,
or playback-frame benefit.

## Regression coverage

The isolated test slice compiles unmodified production support sources and runs
both the pinned bounded helper and the candidate in debug and release. The
existing six test functions include 5,465 generated small-playlist cases per
configuration, clipped boundaries, duplicate distances, raw URL equality, and a
10,000-item playlist.

The added regression checks decoded single-item file, remote, relative,
percent-escaped, and Unicode URL representations. It compares the returned
`absoluteString`, `relativeString`, and `baseURL`, including the dictionary key,
and covers matching, absent, standardized, absolute, and nil queries.

## Benchmark method

Both complete helper sources are compiled as a separate optimized `IlliquidApp`
module with identical `IlliquidCore` support and an identical driver. There are
no baseline source rewrites. The driver consumes result counts inside each timed
loop; exact URLs and distances are checked before and after timing and across
variants. Input construction and URL normalization remain outside timing.

The workload includes matching, missing, and nil singletons plus 2-, 8-, 32-,
and 10,000-item controls. Repeated positions that are identical for singletons
are omitted. Eight balanced AB/BA pairs run in fresh processes for each workload.
Calibration uses up to four retained trials per variant to reach at least 80%
of a 50 ms target, with a five-million-call cap. All calibration records and
all accepted timing samples are retained; the runner has no automatic pass/fail threshold based on timing.

The measurements describe repeated synchronous preparation throughput on the
reported host, including result count consumption and destruction. They do not
include actor scheduling, candidate ranking, native decoding, or presentation.
Cross-platform results are reported separately.

## Reproduce

Follow `AGENTS.md` and submit compilation through Kyoto when it is available.
Hosted workflows verify its absence before building serially in isolated
checkouts.

```sh
git fetch --no-tags origin 8637a8d2c6a628699d5a552a55061b4e0bfc6f10
ILLIQUID_SINGLETON_HELPER_REF=8637a8d2c6a628699d5a552a55061b4e0bfc6f10 \
  bash Scripts/test-thumbnail-singleton.sh --jobs 2 --no-parallel
bash Scripts/test-thumbnail-singleton.sh --jobs 2 --no-parallel
python3 Benchmarks/ThumbnailSingleton/run.py \
  --rounds 8 --target-ms 50 --counts 1,2,8,32,10000 \
  --output /tmp/thumbnail-singleton-results.json
```

The portable workflow pins the official Swift 6.3.3 Noble image by its observed
digest. The inherited native workflow also measures this comparison and includes
the new regression when compiling/testing the full app graph.

## Results and decision

**The final candidate reproduced the singleton preparation improvement in two
Linux cohorts. This is a draft follow-up to #132; native macOS performance and
full app qualification remain pending.**

The baseline is #132 at `8637a8d2c6a628699d5a552a55061b4e0bfc6f10`.
The final candidate is `9acae3a8a5a4330067233b53ab011ee0b36faed2`.
Both final cohorts compiled the same candidate helper with SHA-256
`1ce29bcd4c39ec7dbf1424a4d6913a634255b668ff01f4d57352a19e8ccfc90d`.

Each time below is the median of eight observations. The paired percentage is
the median of eight `(candidate / baseline - 1) * 100` values, computed separately;
it is not obtained by dividing the two displayed medians. Negative percentages
mean faster. No cohorts, versions, or workloads are pooled.

### Matching singleton target

| Cohort | Baseline ns/call | Candidate ns/call | Median paired change | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| V1 (discarded) | 292.15 | 216.94 | -26.20% | 8/8 |
| V2 first | 295.29 | 247.10 | -17.04% | 8/8 |
| V2 confirmation | 294.86 | 246.54 | -16.08% | 8/8 |

The final candidate saves about **48 ns (0.048 microseconds) per matching-singleton
helper call** by the difference between each cohort's variant medians. This
component effect is small in absolute terms; the experiment does not establish
a perceptible player improvement.

V1 placed the singleton shortcut before the existing search. It had a larger
target improvement, but its eight-item front and last controls were slower
(+8.00% and +5.45% paired changes). V1 was discarded. V2 inserts only the direct
result construction after the original search guard; its production change
adds eight lines.

### Review rule and confirmation

The review rule was recorded at 2026-10-28 06:05:02 UTC, before inspecting V2
results. The first V2 run had already completed at that point, so this is not a
pre-run registration. The rule required at least a 10% median paired target
reduction and at least 7/8 faster pairs. A control triggered one fixed, complete
confirmation if its median paired slowdown was at least 5% **and** the difference
between its candidate and baseline medians was at least 10 ns. These are
engineering review thresholds, not statistical significance tests.

The first V2 cohort triggered that confirmation: the two-item front case was
**+9.61%** paired, with medians **368.07 → 407.53 ns**, and 7/8 pairs slower.
In the unchanged-code confirmation, it measured **−0.13%** paired, with medians
**367.88 → 366.86 ns**, and 5/8 pairs faster. The original slowdown remains
unexplained. Its absence in the second cohort does not prove that every control
is regression-free.

Both final cohorts passed the target rule. No confirmation control crossed both
thresholds. The highest positive confirmation paired change was the 32-item
front case, +4.13% with a +7.78 ns difference between medians. There were no
additional confirmation reruns and no rejected timing samples.

### Complete workload matrix

The table preserves every workload, including unfavorable measurements.
Full per-variant times, all paired samples, calibration trials, output receipts,
environment details, and source hashes are retained in the evidence files.

| Count/position | V1 paired change | V2 first paired change | V2 confirmation paired change |
| --- | ---: | ---: | ---: |
| 1/nil | -7.56% | -0.67% | +0.43% |
| 1/front | -26.20% | -17.04% | -16.08% |
| 1/absent | -7.73% | +0.26% | +2.11% |
| 2/nil | -6.83% | -1.22% | -1.50% |
| 2/front | -0.41% | +9.61% | -0.13% |
| 2/last | +0.50% | -2.24% | +0.96% |
| 2/absent | +0.75% | -0.99% | +0.26% |
| 8/nil | -6.93% | -0.17% | +0.18% |
| 8/front | +8.00% | -0.50% | -0.67% |
| 8/middle | +2.32% | +1.74% | -4.71% |
| 8/last | +5.45% | -0.18% | -0.83% |
| 8/absent | +0.03% | -1.38% | -2.24% |
| 32/nil | -6.79% | +0.15% | -0.56% |
| 32/front | -1.86% | -0.06% | +4.13% |
| 32/middle | -1.13% | -2.36% | +0.14% |
| 32/last | +2.29% | +1.02% | -1.75% |
| 32/absent | +0.79% | -0.25% | -0.07% |
| 10000/nil | -8.08% | -1.66% | -1.30% |
| 10000/front | -5.43% | +2.71% | -0.47% |
| 10000/middle | -1.18% | +1.70% | +0.91% |
| 10000/last | +1.68% | -0.96% | +1.95% |
| 10000/absent | +0.59% | -0.01% | -0.23% |

### Environment and validation

All three cohorts used Swift 6.3.3 on Linux x86-64, glibc 2.39, four logical CPUs,
and Python 3.12.3. The specific CPU model was not captured. The official Noble
image is pinned in the workflow; complete environment strings are in each JSON.

Each cohort contains **22 workloads × eight pairs × two variants = 352 timed
process observations**. Calibration is separate. Observed timed intervals were:

| Cohort | Minimum ms | Maximum ms |
| --- | ---: | ---: |
| V1 (discarded) | 39.63 | 65.51 |
| V2 first | 41.31 | 66.25 |
| V2 confirmation | 38.08 | 63.94 |

The target interval is a calibration goal; individual measurements can be
shorter or longer. No samples were filtered based on interval or speed.

Seven distinct test functions passed for each of baseline debug, baseline
release, candidate debug, and candidate release: **28 test executions per
cohort**. All exact benchmark output receipts matched. These are component
tests using unmodified production sources, not a successful full macOS app
build. Native workflows are configured for the PR and remain outstanding qualification.

## Permanent evidence

| Cohort | GitHub Actions | Raw timings and provenance | Extracted test output |
| --- | --- | --- | --- |
| V1 (discarded) | [run 40640558185, attempt 1](https://github.com/Jagalite/illiquid/actions/runs/40640558185/job/122657450523) | [v1-before-search.json](../Benchmarks/ThumbnailSingleton/evidence/v1-before-search.json) | [tests](../Benchmarks/ThumbnailSingleton/evidence/v1-before-search-tests.json) |
| V2 first | [run 40641048888, attempt 1](https://github.com/Jagalite/illiquid/actions/runs/40641048888/job/122659022272) | [v2-first.json](../Benchmarks/ThumbnailSingleton/evidence/v2-first.json) | [tests](../Benchmarks/ThumbnailSingleton/evidence/v2-first-tests.json) |
| V2 confirmation | [run 40641048888, attempt 2](https://github.com/Jagalite/illiquid/actions/runs/40641048888/job/122661904725) | [v2-confirmation.json](../Benchmarks/ThumbnailSingleton/evidence/v2-confirmation.json) | [tests](../Benchmarks/ThumbnailSingleton/evidence/v2-confirmation-tests.json) |

[Machine-readable summary](../Benchmarks/ThumbnailSingleton/evidence/summary.json)
includes all workload medians, paired changes, faster-pair counts, review flags,
source revisions, and the recorded evaluation policy. Raw evidence is committed
so it does not depend on Actions artifact retention.

## Remaining qualification

The current evidence supports a portable construction-time optimization only.
Before marking the stacked PR ready, run the configured native component
comparison and full app regression job on macOS, inspect control results there,
and check the optional background/library thumbnail path interactively.
No claim is made about allocator counts, process RSS, frame pacing, or power.
The general bounded-memory improvement belongs to #132.
