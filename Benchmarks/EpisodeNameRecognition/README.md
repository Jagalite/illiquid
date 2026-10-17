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

## Reproduction

Swift 6.1+ and Python 3 are required. Run from the repository root:

```sh
python3 Benchmarks/EpisodeNameRecognition/run.py test --implementation baseline --configuration debug --output /tmp/episode-baseline-debug
python3 Benchmarks/EpisodeNameRecognition/run.py test --implementation baseline --configuration release --output /tmp/episode-baseline-release
python3 Benchmarks/EpisodeNameRecognition/run.py test --configuration debug --output /tmp/episode-candidate-debug
python3 Benchmarks/EpisodeNameRecognition/run.py test --configuration release --output /tmp/episode-candidate-release
python3 Benchmarks/EpisodeNameRecognition/run.py benchmark --output /tmp/episode-benchmark
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

## Results and limits

Native measurement results will be recorded after the research run completes.
The local editing environment has no Swift toolchain and insufficient disk space
to install one, so it is not a source of compiled or runtime qualification.

These measurements concern filename recognition used during media indexing and
fallback row preparation. They do not establish an end-to-end scan improvement,
cached-search speedup, lower playback CPU use, frame-rate change, or energy
savings. The real app and native playback dependencies are not built by this
component harness.
