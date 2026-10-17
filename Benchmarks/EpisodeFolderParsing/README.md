# Episode folder parsing performance

This experiment measures the complete filename recognizer used by source scans
and media-browser projection. It compares the exact production source with a
frozen copy from main at `68274d1b09dcc866296321a5a8858efc297c4f19`.

The candidate parses the relevant episode folder title once and reuses the
result. Recognition rules, title/year parsing, metadata, and display formatting
are unchanged. There is no persistent cache or new dependency.

## Reproduce

Requires Python 3.10+ and Swift 6.1+ with Swift Testing. The runner creates a
temporary standalone package from the actual production source; it does not
build the macOS player or require its native dependencies.

```sh
python3 Benchmarks/EpisodeFolderParsing/run.py \
  --output /tmp/illiquid-media-name-results --pairs 6 --target-ms 200
```

The output directory must not already exist. `--mode test` runs only the
regressions; `--mode benchmark` runs exact-output comparisons and timings.
Run the complete benchmark on macOS, the player's supported platform. A
supplementary Linux attempt passed the regression tests, then the frozen
baseline trapped in Foundation path handling during the full corpus dump.
Linux is therefore not qualified for this benchmark; the corpus is preserved
without filtering those edge paths.

The workflow also runs the existing sidecar/NFO integration regressions:

```sh
bash Scripts/test-nfo-metadata-regressions.sh -c debug
bash Scripts/test-nfo-metadata-regressions.sh -c release
```

## Correctness

Both the frozen baseline and candidate run the existing recognition tests and
the new expected-output regressions in debug and release. `Corpus.swift`
provides 7,936 deterministic synthetic paths, including all timed inputs,
prefix/folder/year combinations, ambiguous and empty titles, specials,
alternate episode markers, tags, numeric titles, and byte-distinct Unicode.

The optimized executables serialize every stored field and the computed
`seriesTitle`, `displayName`, and `section`. String fields are UTF-8 byte arrays;
the runner compares the complete serialized receipts byte for byte. Swift's
canonical-equivalence string comparison is deliberately not the oracle.
The same input corpus is used for both sources, with no expected results
derived from the candidate. The new tests also assert independent expectations.

## Timing method and scope

Both sources are compiled with `swiftc -swift-version 6 -O`, using the same
driver and corpus. Each observation starts a fresh process, creates its input
array outside the timer, and performs two untimed traversals to initialize
static regexes and warm the component. A baseline-only calibration chooses
the same traversal count for both variants, targeting 200 ms per observation.
Six pairs alternate baseline/candidate and candidate/baseline execution order.

The timer covers complete recognition plus a lightweight, non-inlined result
consumer. On macOS an autorelease pool bounds transient Objective-C objects to
one 128-path traversal. Corpus construction, JSON serialization, exact-output
comparison, and computed UI strings are outside the timer. Checksums must match
across all observations; full equality is established separately by receipts.

There are twelve 128-path workloads. Seven exercise episode naming; movies,
dates, and extras exercise unchanged branches. `unknown` includes bare episode
markers that reach the optimized branch before staying unclassified, so it is
not a pure unchanged-code control. `mixed` interleaves the eleven families with
a fixed synthetic distribution. None of these frequencies is measured user
traffic. No control time is subtracted from results.

The measurements concern warm filename recognition. They do not establish
filesystem scan latency, full sidebar latency, playback CPU, memory use,
frame rate, or energy savings. Allocator counts are not measured.

## Evidence

The runner retains source, driver, corpus, and test snapshots; source and
executable digests; environment and command records; all raw timings; exact
receipts; test logs; and summaries. A failure writes `failure.json` and leaves
the completed evidence intact. `summary.json` reports medians, observed ranges,
and every paired percentage change rather than a machine-dependent pass/fail
performance threshold. `build/` contains reproducible intermediate binaries
and packages and is excluded from CI artifacts.

Research results and retained evidence are recorded in
[`Documentation/EPISODE_FOLDER_PARSING_PERFORMANCE.md`](../../Documentation/EPISODE_FOLDER_PARSING_PERFORMANCE.md).
The first native run passed all correctness checks and found approximately
27–28% less median recognition time for bare-season and specials/multi-episode
workloads. The report includes every workload and discusses control variability.
