# Episode filename recognition: reuse parsed folder evidence

The native component experiment supports this small optimization: median
recognition time fell **27.98% for bare episode names under season folders**
and **27.03% for specials/multiple-episode names**, with improvement in all six
pairs for each workload. Complete outputs were identical.

[Native run 39069954591](https://github.com/Jagalite/illiquid/actions/runs/39069954591)
tested `f8386f9be6636432c68a9ced7825544306560a60` on an Apple M1 virtual machine,
macOS 26.6.2, Apple Swift 6.3.3. The frozen baseline is main at
`68274d1b09dcc866296321a5a8858efc297c4f19`.

## Why this area

[`MediaSidecarReader.recognize`](../Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift)
recognizes filenames before applying local metadata and can repeat recognition
for synthesized hint names.
[`SourceTreeProjectionInput.makeFlatFileRows`](../Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift)
also recognizes entries lacking a previous result in media view. Repeated parsing
therefore accumulates across files.

The [earlier investigation](NONDECODING_PERFORMANCE_INVESTIGATION.md) already
identified compiled-once regexes; this change removes subsequent duplicate work.
A concurrent
[`perf/media-name-episode-recognition-20261017` branch](https://github.com/Jagalite/illiquid/tree/perf/media-name-episode-recognition-20261017)
offers a larger alternative overlapping this production region. These are
alternative implementations to coordinate during review. This experiment uses
distinct benchmark paths to avoid file collisions with other recognition work.

## Change and result equivalence

The original episode branch calls `titleAndYear` three times: for the parent,
chosen show title, and folder enrichment. It computes unused parent evidence
for prefixed filenames and reparses the same folder for bare names.

The candidate computes `folderShow = titleAndYear(showFolder ?? parent)` once
and reuses it when eligible. Helper calls fall **from three to two for prefixed
episodes, and three to one for bare episodes**. Result selection is equivalent:

| Existing evidence | Show value before enrichment, in both variants |
|---|---|
| Nonempty cleaned filename prefix | `titleAndYear(prefixTitle)` |
| Empty prefix with a show folder above a season/specials folder | `titleAndYear(showFolder)` |
| Empty prefix, ordinary parent with a parsed year | `titleAndYear(parent)` |
| Empty prefix, ordinary parent without a parsed year | Empty title and nil year |

The unchanged case-insensitive enrichment condition supplies a matching folder's
spelling/year only when the filename lacks a year. Explicit filename years remain
authoritative. A parent `(2020)` supplies no parsed year because it lacks a title;
through a season folder it remains the numeric show title `2020`, with nil year.
No cache, schema, dependency, regex, calendar, or formatting changes are involved.

## Method and correctness

The runner at [`Benchmarks/EpisodeFolderParsing/run.py`](../Benchmarks/EpisodeFolderParsing/run.py)
compiles both complete recognizers with the same driver/corpus and
`swiftc -swift-version 6 -O`. There are twelve workloads of 128 synthetic paths.
Each fresh process constructs inputs before timing, performs two untimed warmup
traversals, then uses equal baseline-calibrated traversal counts targeting
200 ms. Six pairs alternate execution order, producing **144 timing observations**.

The timer includes full recognition, a lightweight non-inlined result consumer,
and a macOS autorelease pool per traversal. Input construction, JSON serialization,
and computed UI strings are outside timing. No control time is subtracted.

Both optimized executables produced byte-identical receipts for **7,936 inputs**.
Receipts include every stored field plus `seriesTitle`, `displayName`, and
`section`; strings use UTF-8 byte arrays to expose canonically equivalent but
byte-distinct spellings. Timing checksums also matched. The existing and new
recognition suites passed **19 test functions in each of four configurations**:
baseline/candidate, debug/release. Independent expectations cover folder
eligibility, conflicting years, Unicode, numeric/empty titles, and release
metadata. The candidate's existing sidecar/NFO integration suite passed
**32 tests in debug and 32 in release**.

## Native results

Values are medians in microseconds per recognition, including the consumer.
Reduction is `1 − candidate median / baseline median`. The original artifact's
`summary.json` records per-variant ranges and every paired change.

| Workload | Baseline µs | Candidate µs | Reduction | Improved pairs |
|---|---:|---:|---:|---:|
| Prefixed episodes | 46.92 | 43.99 | 6.24% | 5/6 |
| Bare names, season folder | 37.19 | 26.78 | **27.98%** | **6/6** |
| Bare names, dated parent | 60.65 | 41.52 | 31.54% | 5/6 |
| Explicit filename year | 47.35 | 43.54 | 8.06% | 6/6 |
| Specials/multiple episodes | 43.17 | 31.50 | **27.03%** | **6/6** |
| Alternate episode markers | 45.75 | 38.90 | 14.98% | 4/6 |
| Unicode and tags | 76.51 | 69.07 | 9.72% | 5/6 |
| Movies | 34.81 | 32.61 | 6.32% | 4/6 |
| Dates | 42.71 | 39.97 | 6.43% | 4/6 |
| Extras | 20.80 | 20.37 | 2.07% | 4/6 |
| Unknown | 34.77 | 32.38 | 6.88% | 6/6 |
| Mixed | 46.81 | 38.69 | 17.35% | 5/6 |

Control noise limits attribution: movies, dates, and extras bypass the changed
branch yet show median shifts. Movie pairs ranged from a 50.43% slowdown to a
36.58% reduction. Mixed names showed an observed 17.35% median reduction, with
one pair regressing 7.82%; its synthetic distribution is not measured user traffic.
Unknown names include episode markers that enter the changed branch.

Bare-season paired reductions ranged from 25.37% to 45.66%; specials/multiple
reductions ranged from 21.80% to 30.31%. Both families' baseline and candidate
sample ranges were separated. The headline is limited to these two workloads
with six improving pairs; broader percentages remain observations from this run.

## Reproduce and review evidence

The benchmark is [`Benchmarks/EpisodeFolderParsing/`](../Benchmarks/EpisodeFolderParsing/).
The [native workflow](../.github/workflows/episode-folder-parsing-performance.yml)
runs the experiment and integration tests on macOS.

~~~sh
python3 Benchmarks/EpisodeFolderParsing/run.py \
  --output /tmp/illiquid-episode-folder-results --pairs 6 --target-ms 200
bash Scripts/test-nfo-metadata-regressions.sh -c debug
bash Scripts/test-nfo-metadata-regressions.sh -c release
~~~

Use a new output directory. The benchmark README describes requirements and
test-only/benchmark-only modes.

[Checked-in provenance, audit notes and decoded job logs](PerformanceEvidence/EpisodeFolderParsing/macos-initial/)
identify the measured commit, source digests, complete-output digest, and
successful Actions steps. The
[original native archive](https://github.com/Jagalite/illiquid/actions/runs/39069954591/artifacts/12115540648)
contains all raw observations, calibration records, source/support/test
snapshots, receipts, stdout/stderr and command logs. Its SHA-256 is
`08ea93ad10f09b665a2bc02217a2646af18e9177872e5c656e0bd5b5254e2610`.
This archive is hosted by Actions with a 14-day retention period; it is not
duplicated in this commit. Download it before expiry to retain the full evidence.

An independent audit verified all 170 command records and log hashes, the
7,936 complete receipts, all 144 observations and paired ordering, checksums,
summary calculations and test outcomes. All 356 archive members matched the
audited materialized files byte for byte. The measured source, driver, corpus,
runner and tests remained byte-identical after the benchmark directory rename.
Executable hashes were recorded, but binary bytes were excluded from the archive;
the auditor therefore could not independently rehash those binaries.

## Platform and measurement limits

A [supplementary Linux attempt](https://github.com/Jagalite/illiquid/actions/runs/39071181652)
passed recognition tests for both variants in debug and release, then crashed
in the unmodified baseline's Foundation path handling before complete parity
or timings. The exact triggering input was not established. No Linux performance
or full equivalence result is claimed; the exploratory Linux workflow was
removed. [Linux provenance and decoded log](PerformanceEvidence/EpisodeFolderParsing/linux-attempt/)
record the unsuccessful attempt, including its earlier Python setup failure.

These warm component measurements do not quantify filesystem or sidecar I/O,
complete sidebar latency, allocations, playback CPU, frame rate, memory, or
energy. Selected-source tests do not establish a full app build or physical
playback qualification.
