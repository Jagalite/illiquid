# Media filename metadata and tag guards

The revised candidate reduces warmed filename-recognition CPU time in this
native macOS experiment. All 12 workloads have lower median paired CPU costs;
the synthetic mixed workload improves **9.77%**, and the previously regressing
unclassified-name workload improves **17.32%** with all eight CPU pairs faster.
These results justify proposing the focused production change for review.

## Native results

Measured source: [`aa4ec831`](https://github.com/Jagalite/illiquid/commit/aa4ec831d751dedcd54033564c50407e9234c2ab).
Baseline: main at `68274d1b09dcc866296321a5a8858efc297c4f19`.
Host: Apple M1 (Virtual), three logical CPUs, 7,516,192,768 bytes RAM,
macOS 26.6.2 arm64, Xcode 26.6 (17F113), Apple Swift 6.3.3.
The retained host receipt compares those exact values with the measured manifest.

Eight fresh-process pairs per workload produced **192 timed observations**
and **4,999,168 recognitions**. Timed regions totalled 121.910650 process-CPU
seconds and 123.428489117 elapsed seconds. All observations are retained.

| Workload | Baseline CPU µs/name, median | Candidate CPU µs/name, median | Paired CPU reduction, median | CPU-faster pairs | Paired elapsed reduction, median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Plain movies | 15.353 | 12.696 | 18.83% | 8/8 | 19.43% |
| Movie release names | 24.682 | 22.629 | 8.53% | 7/8 | 8.62% |
| Named episodes | 44.114 | 35.559 | 20.44% | 8/8 | 20.47% |
| Episodes using folders | 33.589 | 25.010 | 26.17% | 8/8 | 26.23% |
| Unclassified names | 23.872 | 19.534 | 17.32% | 8/8 | 17.34% |
| Unicode names | 29.150 | 23.233 | 21.04% | 8/8 | 20.99% |
| Tagged movies | 30.535 | 28.169 | 2.44% | 6/8 | 2.77% |
| Tagged episodes | 41.724 | 37.568 | 12.21% | 7/8 | 11.91% |
| Extras | 11.295 | 9.024 | 19.39% | 8/8 | 19.37% |
| Dated episodes | 36.898 | 32.525 | 10.98% | 7/8 | 11.04% |
| Malformed tags | 28.847 | 26.174 | 8.60% | 8/8 | 8.61% |
| Mixed library | 32.910 | 28.827 | 9.77% | 8/8 | 9.30% |

For each pair, reduction is `100 × (1 - candidate_time / baseline_time)`.
The reported paired median is **not** the ratio of the two separate absolute
medians. Positive percentages mean less time. The
[complete summary](evidence/revised/summary.json) also records every absolute
and paired range, ratio-of-medians result, and elapsed faster-pair count.
[Raw observations](evidence/revised/measurements.jsonl) support independent
recalculation.

Eight pairs on one virtual host establish an observed component-level result,
not a guarantee for every input or machine. Tagged movies improve only 2.44%
at the paired CPU median and are faster in six of eight pairs; their CPU
pair range is −13.71% to +18.19%. One unclassified-name pair is 37.34% slower
in elapsed time even though every CPU pair improves. Both timers and all
unfavorable observations remain in the evidence.

## Production change and relevance

`MediaNameRecognition.recognize(relativePath:)` provides filename evidence
during Media-view scans and when projection rows lack recognized metadata.
[`MediaSidecarReader`](https://github.com/Jagalite/illiquid/blob/aa4ec831d751dedcd54033564c50407e9234c2ab/Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift)
calls it initially and for certain synthesized names while applying metadata.
[`SourceTreeProjectionInput`](https://github.com/Jagalite/illiquid/blob/aa4ec831d751dedcd54033564c50407e9234c2ab/Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift)
uses it as a Media-view fallback.

The patch makes necessary-delimiter checks before optional regex work:

- If neither the filename nor the selected ancestor contains ASCII `{`,
  skip joined catalog/edition evidence construction and both metadata regexes.
- Reuse the filename's brace result before its final movie-ID regex.
- If text contains neither ASCII `{` nor `[`, skip tag-regex replacement.
- Scan contiguous UTF-8 buffers and reuse any materialized representation in
  later cleanup, rather than repeatedly iterating `String.UTF8View`.

Marker-containing inputs still use the original Foundation regexes. All
patterns, date handling, normalization, recognition precedence, selected
ancestor rules, and derived fields remain unchanged. Joined evidence stays
intact: a malformed edition tag can begin in the filename and end in the
selected ancestor, and that existing behavior is preserved.

The check inspects literal UTF-8 bytes. Character-level membership would miss
an ASCII opener that forms a grapheme cluster with a combining mark.
Swift's [`withUTF8` documentation](https://developer.apple.com/documentation/swift/string/withutf8%28_%3A%29)
states that it makes storage contiguous when necessary and can invalidate
existing indices. Here each materialization precedes creation of the
corresponding regex range or String index; the closures return only Booleans
and no buffer pointer escapes.

The storage explanation is a source-based hypothesis supported by the revised
timings. This investigation did not sample stacks or measure allocations, and
does not claim that a profiler established a particular Foundation storage class.

## Correctness qualification

Both complete production variants compile as separate optimized `IlliquidCore`
modules. The benchmark imports those modules; it does not reimplement the
recognizer.

- The original recognition suite and added boundary suite pass against
  baseline and candidate, in debug and release, with warnings treated as
  errors: **18 test functions in two suites in each of four configurations**.
- All **7,497 complete differential rows** agree, covering 7,195 distinct
  paths. Every stored field and the three public derived fields are included:
  15 fields in total, explicit null optionals, and ordered ID/source arrays.
- The decompressed JSON is byte-identical, including Unicode code points.
  Both compressed archives also match the earlier audited output archive.
- Regressions cover combining marks and ZWJ next to delimiters, fullwidth
  lookalikes, Unicode names, duplicate/case-varied IDs, inherited tags,
  season-folder selection, unmatched tags, cross-component editions, and
  native versus UTF-16-created Foundation input storage.
- Source, test, driver, corpus, generated-package and executable identities
  are recorded. Staged sources and executable hashes are rechecked after
  qualification and timing.

The full app's native dependency graph is outside the isolated package.
Existing NFO, PlexMatch, non-decoding, and restoration workflows provide
additional integration checks when this PR opens; their status should be
read separately from this component's qualification.

## Measurement method

Each timed workload contains 128 synthetic paths. The differential corpus
contains all 1,536 timed paths, 73 curated cases, 5,120 deterministic
adversarial combinations, and 768 systematic delimiter/combining-scalar cases.

The same release driver, corpus, and module name are used for both variants.
Each fresh process constructs its corpus and checks its full semantic
checksum before timing. Two batches warm the recognizer. The timed loop
retains a bounded 128-result batch, reuses array capacity, and performs a
small observation checksum. Complete field checking, JSON serialization,
corpus generation and full semantic hashing are outside the timed interval.

One calibration process per variant/workload selects an equal iteration
count for both variants from the slower pilot. The target is 750 ms per
timed process; actual durations vary. The 24 pilots are retained and excluded
from all timing summaries. Each pair alternates baseline/candidate order
per workload, and workload order rotates across pairs.

The driver brackets the same work with process CPU time
(`CLOCK_PROCESS_CPUTIME_ID`) and elapsed time
(`DispatchTime.uptimeNanoseconds`). No samples are removed as outliers, no
timing overhead is subtracted, and CI uses no wall-time performance threshold.
The [calibration records](evidence/revised/calibration.jsonl), raw observations,
source identities, test pass receipts, and complete output archives are retained.
The numeric JSONL files reproduce their original artifact byte lengths and
SHA-256 hashes; their statistics and ordering were independently recomputed.

## Research history

The first guard used generic `String.UTF8View` iteration. Its early elapsed
results suggested a useful improvement but also showed unfavorable controls.
Those controls drove a longer CPU confirmation and the subsequent storage
revision.

| Cohort | Candidate | Protocol | Mixed paired reduction | Unclassified paired reduction | Malformed paired reduction |
| --- | --- | --- | ---: | ---: | ---: |
| [Initial](evidence/initial/) | Generic UTF-8-view guards | 6 pairs, 150 ms target, elapsed only | +10.86% elapsed | −5.49% elapsed | −8.40% elapsed |
| [CPU confirmation](evidence/confirmation-original/) | Same production candidate | 8 pairs, 750 ms, CPU + elapsed | +11.66% CPU | **−7.95% CPU** | −1.25% CPU |
| [Revised](evidence/revised/) | Contiguous-buffer guards | Same 8-pair CPU + elapsed protocol and corpus | +9.77% CPU | **+17.32% CPU** | +8.60% CPU |

The confirmation's unclassified CPU regression occurred in six of eight
pairs; it was not dismissed as elapsed scheduling noise. The revised candidate
changes byte traversal/materialization, keeps the corpus and timing loop
unchanged, and adds one input-storage regression test. All earlier timing
observations remain available.

Native run links:

- [Initial run 39069913567](https://github.com/Jagalite/illiquid/actions/runs/39069913567),
  commit `2c2e73cead0eb2843ada0a89451ac411b210fdcc`.
- [CPU confirmation 39070945382](https://github.com/Jagalite/illiquid/actions/runs/39070945382),
  commit `26ea88858af8ced4750fced9e64606bd58db4147`.
- [Revised cohort 39071954176](https://github.com/Jagalite/illiquid/actions/runs/39071954176),
  commit `aa4ec831d751dedcd54033564c50407e9234c2ab`.

**Revised run status:** the overall run is marked cancelled after a queue
resubmission. The last status query before that decision still showed it
queued. Its logs show the runner started at 21:56:30 UTC, all eight timing
pairs finished at 22:00:51, and artifact upload completed at 22:00:54.
Every test, complete differential, timing pair, final identity check, summary,
and upload completed successfully. This is a complete retained cohort, not
a partial run discarded for its result.

The unchanged [resubmission 39073278603](https://github.com/Jagalite/illiquid/actions/runs/39073278603)
was queued when this report was prepared. It is not included in these results;
the retained revised cohort is the first complete measurement of this source.
Its status and any later output are separately visible at that link.

## Scope and related work

These measurements cover warmed, in-memory recognition and bounded result
handling. They exclude directory enumeration, sidecar I/O, row construction,
SwiftUI layout, decoding, presentation, energy, memory footprint and whole-library
completion time. The source-browser filter reuses parsed rows across queries,
so this is not a claim about search-keystroke or scrolling latency.

Corpus groups are synthetic and do not model the user's library distribution.
The mixed workload has 32 tagged paths out of 128, selected from eight pattern
categories with correlated title/provider/edition choices. It is a reproducible
control, not a population-weighted estimate.

[PR #46](https://github.com/Jagalite/illiquid/pull/46) independently adds an
overlapping tag-removal guard plus separate date-validation work. This patch
additionally gates catalog/edition evidence and uses contiguous UTF-8 scans;
it leaves the existing Calendar behavior intact. The measurements compare
with the frozen main revision and **do not establish incremental performance
on top of #46**. These are overlapping approaches requiring production-code
integration review, not two independent additive speedups.

This investigation is located in `Benchmarks/MediaNameTagGuards` with a
separate workflow to avoid benchmark/artifact path collisions with concurrent
recognition research.

## Reproduce and verify

Use Python 3.10+ and Swift 6.1+ with the bundled Testing library. The native
workflow uses macOS 26 and Xcode 26.6. The isolated packages have no external
package dependencies; the full app has additional native dependencies.

```sh
# Tests, optimized builds and complete output comparison, without timings:
python3 Benchmarks/MediaNameTagGuards/run.py \
  --correctness-only --output /tmp/illiquid-media-name-correctness

# Full paired native experiment:
python3 Benchmarks/MediaNameTagGuards/run.py \
  --pairs 8 --target-ms 750 \
  --output /tmp/illiquid-media-name-results

# Only baseline/candidate debug and release regression suites:
python3 Benchmarks/MediaNameTagGuards/run.py \
  --tests-only --output /tmp/illiquid-media-name-tests
```

Use a new or empty output directory and avoid competing benchmark workloads.
The runner records completed measured processes, excluded calibration,
source/executable hashes, commands, compiler/host details, complete test logs
and compressed full differential outputs. It stops on correctness or identity
mismatches.

Pull requests run the tests, optimized builds and complete differential with
`--correctness-only`. Explicit workflow dispatch runs the full eight-pair
experiment. The temporary research-branch push trigger and numeric-evidence
collector are removed from the final PR.

The final tooling relocates the benchmark and adds the correctness-only mode
after measurement. The production implementation, Swift driver and corpus
retain their measured bytes; the Python runner's hash changes for this new
mode. Historical evidence retains its original paths and hashes. The exact
measured runner remains available at the pinned measurement commit.

## Retained identities

| Item | SHA-256 |
| --- | --- |
| Baseline production | `b9e75457eccae3c30e09817ce3520750429935b2af646532ac290b18e4aee8fb` |
| First production candidate | `9fb59c859190dd1ad9a2e389ec233104a993a5017ae233b85e53e37800af69e5` |
| Revised production | `28ec3a94b98647ee1aaec8e04c88a0eeb12338809b768684e6b8ddb78e7e3558` |
| Swift corpus | `6c9ed953f1409a67e5262cd5aa3e7dfcbc5bab7c98072c7d987816b2562f8af0` |
| CPU/elapsed Swift driver | `261cba6d00ab569bfecd68c1b0605d826823a0d60fee4023c08339743804850e` |
| Measured CPU/elapsed runner | `3313bdf45ae9d2453221fc0038bda9c8fb64ada372caec6b4efd6ac2080c435e` |
| Complete differential gzip, each variant | `6fb3abd2c961d796e7ad9fa7af6041f67b3623497a02b501259e7f6773d6e169` |

[Initial receipts](evidence/initial/receipt.json),
[confirmation receipts](evidence/confirmation-original/receipt.json), and
[revised receipts](evidence/revised/receipt.json) identify runs, artifacts and
file hashes. Later cohorts retain schema-validated numeric data and source/test
receipts rather than republishing arbitrary diagnostic/environment logs.
Their complete differential bytes are identical to the fully audited initial
archive. All measurements remain independently recalculable after Actions
artifact retention expires.
