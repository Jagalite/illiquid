# Episode folder-name recognition

## Scope

This experiment reduces repeated folder-title/year parsing in
`MediaNameRecognition.recognize(relativePath:)`. `MediaSidecarReader` invokes it
while recognizing local media, and `SourceTreeProjectionInput` uses it as a
fallback when Media-view rows have no recognized snapshot.

The original episode path parses a parent to decide whether it is named, parses
the chosen show string, and parses the folder again for title/year reconciliation.
The candidate parses the relevant folder once for bare episode names. For named
episodes, it parses folder evidence only when the filename has no year.

The original title/year precedence, localized spelling reconciliation, and even
the empty-title comparison for default-ignorable Unicode parent names are kept.
This change adds no persistent cache and does not change regexes or other media
classification paths. It is independent of the separate tag/date optimization
on `perf/media-name-recognition`.

Another branch, `perf/media-name-folder-parsing`, appeared during the investigation
with overlapping folder-result reuse. A second pinned reference at
`f8386f9be6636432c68a9ced7825544306560a60` measures the incremental difference:
this candidate also avoids folder parsing when the filename already supplies a
title and year. The reference retains two title/year parses in that case; the
candidate needs one. Both retain the original locale comparison behavior.

## Reproduction

Swift 6.1+ and Python 3 are required. Run from the repository root:

```sh
python3 Benchmarks/EpisodeNameRecognition/run.py test --implementation baseline --configuration debug --output /tmp/episode-baseline-debug
python3 Benchmarks/EpisodeNameRecognition/run.py test --implementation baseline --configuration release --output /tmp/episode-baseline-release
python3 Benchmarks/EpisodeNameRecognition/run.py test --configuration debug --output /tmp/episode-candidate-debug
python3 Benchmarks/EpisodeNameRecognition/run.py test --configuration release --output /tmp/episode-candidate-release
python3 Benchmarks/EpisodeNameRecognition/run.py differential --output /tmp/episode-differential
python3 Benchmarks/EpisodeNameRecognition/run.py differential --reference folder-reuse --output /tmp/episode-folder-reuse-differential
python3 Benchmarks/EpisodeNameRecognition/run.py benchmark --output /tmp/episode-benchmark
python3 Benchmarks/EpisodeNameRecognition/run.py benchmark --reference folder-reuse --scenarios named-episode-with-year named-episode-no-year bare-season-episode movie-controls --output /tmp/episode-folder-reuse-comparison
```

The test runner copies the exact source and existing/new Swift Testing suites to
a temporary standalone package without changing the app package or fetching
dependencies. The baseline file is retained verbatim from commit
`68274d1b09dcc866296321a5a8858efc297c4f19`; its receipt includes SHA-256 and Git blob
hashes. The benchmark compiles the candidate in place and renames only the two
top-level types in a disposable copy of the baseline so they can run together.

The differential corpus compares all result fields plus `seriesTitle`,
`displayName`, and `section`. It includes episode numbers and ranges, folder/year
precedence, Unicode/case/canonical-equivalence cases, invalid dates, tags, catalog
IDs, editions, extras, movies, and unclassified paths.

The live corpus now contains **16,299 paths**, excluding only the truly empty
relative path from the original 16,300. The frozen baseline's Foundation path
decomposition was reported to trap on that input with Swift 6.2.4/Linux in
[PR #49's review](https://github.com/Jagalite/illiquid/pull/49#discussion_r4304671619).
The `.mkv` empty-basename fixture, its parent-prefixed variants, and all other
nonempty fixtures (including directory-only paths) remain. The driver checks
that no empty path exists and that `.mkv` is present before invoking either
recognizer. These invariants also run before every benchmark's differential.
The `differential` command compiles the same driver and compares the full corpus
without running timings; use it for correctness-only Linux qualification.
The archived 16,300-path macOS receipts and their source hashes below remain
unchanged and describe the original corpus, not the revised live driver.

The default timing run uses seven 64-path corpora, 12 fresh process pairs per
corpus, and 3 timed rounds of 128 complete scans per process. Baseline/candidate
order alternates between pairs. Each process warms its selected implementation
before timing. Input construction, regex initialization, full differential
checks, and output verification are outside the timer. A stable fingerprint of
the stored result fields is consumed inside the timed loop to keep the work
observable; these are recognition-plus-output-consumption timings.

Every sample is retained. The summary reports medians of per-process medians,
paired candidate/baseline ratios, and deterministic bootstrap intervals for the
paired median ratio. Repeated rounds in one process are not treated as independent
samples. There is no CI timing threshold.

The workflow runs the full experiment on this research branch and via manual
dispatch. Pull-request runs repeat correctness checks with a small timing smoke;
those two-pair results are not performance evidence.

## Native results

The [accepted macOS run](https://github.com/Jagalite/illiquid/actions/runs/39070382355)
completed successfully on 2026-10-17 at source revision
`458ca99746f6678c12272757a5df1bf63d469d90`. It used Apple Swift 6.3.3,
macOS 26.6.2, and an arm64 Apple M1 virtual machine with three reported CPUs.
Foundation reported locale `en_US` and preferred language `en-US`.

### Against original main

| Workload | Baseline median µs/file | Candidate median µs/file | Paired time reduction | 95% interval for reduction |
|---|---:|---:|---:|---:|
| Named episode, no filename year | 71.60 | 64.48 | 6.5% | 3.2% to 12.6% |
| Named episode with filename year | 72.95 | 54.07 | 27.9% | 15.8% to 32.2% |
| Bare episode under season folder | 54.92 | 42.54 | 22.7% | 5.2% to 28.0% |
| Bare episode under parent with year | 45.57 | 38.07 | 18.0% | 9.3% to 26.4% |
| Unclassified bare episode | 76.93 | 65.66 | 19.5% | 4.4% to 30.4% |
| Mixed library | 42.28 | 38.40 | 11.5% | 0.9% to 22.1% |
| Movie control | 33.36 | 34.99 | -1.2% | -12.1% to 5.2% |

The separate baseline/candidate time columns are medians of per-process medians.
The reduction column is the median of the twelve paired reductions; it is not
computed by dividing those two independently summarized time columns. Negative
reductions indicate longer candidate times. Intervals are the deterministic
10,000-resample paired-median bootstrap intervals described above, without a
multiple-comparison adjustment.

All six affected workloads have intervals below a candidate/baseline ratio of
one in this run. The movie control does not establish an improvement or a
regression: its interval crosses zero and is wide. These are component results
from a shared virtual runner, whose variability is visible in the raw pairs.

### Against the concurrent folder-reuse implementation

| Workload | Baseline median µs/file | Candidate median µs/file | Paired time reduction | 95% interval for reduction |
|---|---:|---:|---:|---:|
| Named episode with filename year | 46.73 | 42.37 | 9.7% | -0.6% to 19.6% |
| Named episode, no filename year | 42.42 | 43.86 | 1.2% | -11.7% to 7.4% |
| Bare episode under season folder | 32.70 | 31.04 | 5.2% | -3.4% to 9.8% |
| Movie control | 27.69 | 28.56 | -1.9% | -5.7% to 2.7% |

The explicit-filename-year workload has a 9.7% point estimate in favor of this
candidate, with 8 of 12 process pairs faster, but its interval crosses zero.
**This run does not conclusively establish an additional speedup over the
concurrent implementation.** Its controls also have intervals crossing zero.
The reduction from three title/year parses to one versus original main includes
work shared with that branch and must not be presented as an incremental win
over it. This candidate's additional structural difference is to skip folder
parsing entirely when the filename already supplies a title and year.

The concurrent implementation is proposed in [PR #47](https://github.com/Jagalite/illiquid/pull/47).
This proposal targets the original `main` as a measured alternative, with the
overlap disclosed so reviewers can choose one implementation. The reported
main-relative gains are not cumulative with #47. If that change lands first,
reassess the remaining diff and its performance evidence before merging this one.

### Correctness and retained evidence

- The original and candidate each passed **19 tests in 2 suites** in both debug
  and release, including the 10 added test methods covering 22 cases.
- All **16,300 paths** matched each reference in full stored/computed result
  snapshots and stored-field byte fingerprints: 32,600 reference/candidate
  comparisons across the two references.
- The run retains all **264 timed processes and 792 timed rounds**: 168 processes
  against original main and 96 against folder reuse. Each round recognizes 8,192
  prebuilt paths. There were no timing-based exclusions or acceptance thresholds.
- [macos-results.json](evidence/macos-results.json) retains every timing sample,
  paired execution order, checksums, environment, and source/test receipts.
- [macos-summary.json](evidence/macos-summary.json) retains the summarized results,
  test-run summaries, source hashes, run identity, and successful job conclusion.
- The workflow also uploaded the individual compiler/test/process logs. The
  checked-in evidence remains available after that temporary CI artifact expires.

The initial queued research run was superseded to add the concurrent-reference
comparison before it obtained a runner; it contributed no measurements. The
optional Linux fallback was prepared while the macOS runner was queued and was
never submitted or used as evidence. Local Python/YAML checks and independent
source/harness reviews passed; local Swift execution was unavailable.

## Limits

These measurements concern filename recognition used during media indexing and
fallback row preparation. They do not establish an end-to-end scan improvement,
cached-search speedup, lower playback CPU use, frame-rate change, or energy
savings. The real app and native playback dependencies are not built by this
component harness. Absolute times from the two comparison batches differ; only
within-batch pairs should be used to compare implementations.
