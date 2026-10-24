# Source visibility row-storage memory research

## Scope and qualification status

This change removes a redundant source-browser row-array allocation when the
visibility pass leaves every row included and unannotated. The implementation
also bounds requested array growth after a late exclusion or annotation, while
allowing sparse filtered output to remain small.

The completed Linux component study contains 324 observations in 162 balanced
baseline/candidate pairs. The unchanged prepared-row cases reduced allocator
growth in all 36 pairs, with median paired reductions of 67.2–79.1% across the
three sizes. The source-level storage-sharing mechanism and output parity passed
the checks below. Timing results are mixed and include substantial unfavorable
samples.

The native macOS workflow remains pending. This is a successful portable memory
experiment proposed as a **draft pending native qualification**. Whole-player
memory, visible sidebar latency and playback performance remain unmeasured.

## Allocation mechanism

The [baseline filter](https://github.com/Jagalite/illiquid/blob/6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635/Sources/IlliquidApp/UI/SourceBrowserFilter.swift)
retains source rows in the tree cache and visibility key. Its visibility loop
nevertheless appends every accepted row into a separate array. Even a default
projection with no hidden rows therefore leaves the cached projection holding
another backing allocation for the same row values.

The [candidate filter](https://github.com/Jagalite/illiquid/blob/08c6da0cc4aca611adf1ec08da171b23dcbdf207/Sources/IlliquidApp/UI/SourceBrowserFilter.swift)
keeps the output array absent until the first exclusion or original/computed
visibility annotation. Before that point, all preceding input rows have been
accepted without annotations, so they form the exact unchanged output prefix.
At the first such event, the candidate copies that prefix once and appends later
accepted rows into the new buffer. If no such event occurs, the projection
returns the original array storage.

The sharing criterion is deliberately conservative. Any existing or newly
computed annotation takes the materialized path, even if the two annotation
values compare equal. This preserves the existing assignment of newly evaluated
regex identifiers: canonically equivalent Swift strings can have different
UTF-8 bytes. Stale annotations are still cleared. View filtering, rule counts,
hidden counts, preview behavior, inherited visibility, empty-folder handling,
and cancellation checks retain their existing execution order.

Swift arrays preserve value semantics through copy-on-write: a mutation of one
shared array produces independent storage as needed. The new tests exercise
mutations both in a caller's input and in a consumer's copy of a published
projection. See [Apple's Array documentation](https://developer.apple.com/documentation/swift/array).
The row values contain URL, String and metadata references that already share
underlying storage in the baseline; the eliminated allocation is the second row
array and its unused capacity, rather than a second deep copy of every referenced
object.

### Growth after the first change

A plain `Array(prefix)` followed by normal append growth can allocate an
unnecessarily large buffer when the first changed row is near the end of the
input. For example, hiding the next-to-last row first copies almost the entire
input; appending the final accepted row can then trigger geometric growth.

The final implementation checks whether the materialized output is at capacity
before each append. Its next requested capacity grows geometrically, capped at
the input count. This caps the request before addition and avoids asking for
almost twice the necessary size after a late change. Swift can round the actual
capacity above the requested count, so receipts record actual input and output
capacities separately from allocator bytes.

There is no unconditional reservation for the full input. An early exclusion
followed by a single surviving row can still produce a small output allocation.
The final `hide_penultimate`, `preview_last`, and `keep_one` controls exercise
these boundaries in addition to ordinary unchanged, filtered and annotated
results.

## Exact source provenance

The final cohort compares one immutable baseline with a clean local checkout.
The published candidate and measured local commit have different commit IDs
but the same complete Git tree:

| Role | Identifier |
| --- | --- |
| Baseline commit | `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` |
| Measured local candidate commit | `f788a21e574a13cc682f7381ba8491f170ecc1f1` |
| Published candidate commit | [`08c6da0cc4aca611adf1ec08da171b23dcbdf207`](https://github.com/Jagalite/illiquid/commit/08c6da0cc4aca611adf1ec08da171b23dcbdf207) |
| Shared candidate tree | `f876c82d3671797b349b6766a13edc8cfe5881b4` |
| Baseline filter Git blob | `5fa84b5ede8cf373d8703cc76ba63f6cb5d02fba` |
| Candidate filter Git blob | `9eb94493522e92d8c4a8feb04ff1bc75e7cc4c2b` |

The source hashes recorded for `SourceBrowserFilter.swift` are:

```text
baseline SHA-256:  d88bbb49f2fe147081f4c83e010a43acfa010a0857ceb5b6a165c8e7e7e45615
candidate SHA-256: 066a7dce7055bf69c9e7e228755feafd364c8eb78fe183fc272df2026049dd62
runner SHA-256:    209d4ef29747e09ff85c4b0d91ffe2b69a61f2d160bdd36b3cd9c049ae4c8e36
harness SHA-256:   9120039701dfaddeab8339ca0bc4dba5ba0c2943e6c2886b58f40817b691c3ab
```

The [runner](../Benchmarks/SourceVisibilityStorage/run.py) compiles the complete
filter and tree-input files, their actual core dependencies, and guarded verbatim
app value, matcher, sorter and row declarations. Supporting production bytes
must match between variants; only the filter can differ. The experiment measures
these production implementations directly.

The manifest records all original and compiled source hashes, extracted-section
hashes, harness inputs, compiler, host, checkout state and binary hashes. Linux
uses the existing runner's explicit Darwin-to-Glibc and FoundationXML import
adaptations, plus a directory hint for one existing sidecar test fixture. The
native macOS source does not receive these adaptations. Completion verifies the
staged source, executable and runner hashes again. Later report/evidence commits
can change the repository tree while the hashes continue to identify the exact
measured implementation.

## Experimental design

The final Linux environment is x86-64 Linux with glibc 2.39, Swift 6.3.2, and an
Intel Xeon Platinum 8573C host. These component measurements use synthetic
lexical URLs and file metadata. They perform no media decoding, filesystem scan,
or SwiftUI rendering. The 100,000-row workload is a stress case.

The design has nine cases at 1,000, 10,000 and 100,000 input rows. Each of the 27
case/size groups uses six alternating AB/BA pairs, with a fresh process for each
member: 162 pairs and 324 completed observations. Every process performs
three independent eight-row warmups for its scenario before constructing the
measured fixture.

| Case | Operation and purpose |
| --- | --- |
| `unchanged` | Prepared media rows under default tree visibility; directly exercises storage reuse. |
| `nonmatching_rule` | One enabled regex is evaluated and matches nothing; verifies unchanged output with active rules. |
| `hide_half` | A regex excludes alternate media rows; filtered-output control. |
| `hide_last` | The final row is manually hidden; late prefix materialization without a subsequent append. |
| `preview` | Alternate rows receive revealed visibility annotations; annotation control. |
| `tree_input` | A real immutable tree input builds and sorts a source listing before visibility. |
| `hide_penultimate` | The next-to-last row is hidden, then the final row is appended; late growth control. |
| `preview_last` | Only the final row receives an annotation; late annotation growth control. |
| `keep_one` | All rows except the last are hidden; sparse-output control. |

The before-sample occurs after fixture construction. The after-sample occurs
immediately after the cold awaited production projection returns, with the
fixture, filter actor and result explicitly held alive. Wall time and process
CPU time surround that one call. Full output encoding, checksums, pointer
comparison, capacity reporting and JSON serialization occur afterward.

The prepared-row cases therefore exclude their common input backing storage
from the incremental delta. The `tree_input` case also measures production row
construction, sorting and cache retention; its broader delta should be compared
within that case. Both variants still construct the media-path set and thumbnail
candidate list.

### What the memory metric measures

The primary value is the difference between two process-wide live allocator
counters. Linux uses `mallinfo2().uordblks + mallinfo2().hblkhd`; the native probe
uses `malloc_zone_statistics(NULL).size_in_use`. Their implementations are
retained in [the small C probe](../Benchmarks/SourceVisibilityStorage/CVisibilityHeap/heap.c).

The output field is named `retained_allocator_delta_bytes`, but its precise
meaning is **live allocator growth at projection return**. The driver does not
force an autorelease-pool drain or wait for quiescence. Pending Foundation
autoreleases and unrelated runtime/background activity can therefore contribute
to the sample. This metric does not establish steady-state or post-drain
retained heap, process RSS, physical footprint, peak memory, cumulative
allocation traffic, GPU memory, or total player memory.

A separate nested pair of live array borrows verifies that unchanged prepared
rows share their backing storage in the candidate and do not in the baseline.
That ownership observation supports the allocation mechanism independently of
allocator noise. Native Foundation representation and allocator behavior can
differ, so Linux byte counts or percentages should not be transferred to macOS.

### Latency interpretation

The experiment records wall and process CPU time as controls. The observed
latencies are mixed; this change is not presented as a speed improvement.
Complete case-level medians and paired changes appear below; ranges and every
unfavorable observation are preserved in the linked raw evidence. Fewer allocated
bytes alone do not establish faster sidebar interaction, reduced frame drops,
lower energy use, or faster playback. Six pairs of one cold call per process
also do not characterize user-interface tail latency.

## Completed Linux results

These tables report median **at-return live allocator growth in bytes**. Each
row represents six fresh-process baseline/candidate pairs. Reduction is the
median of `100 × (baseline − candidate) / baseline` within each pair; it is
not the ratio of the two displayed medians. Positive values favor the candidate.

The [complete summary](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/summary.json) includes ranges, pairwise differences and favorable-pair counts.

### 1,000 input rows

| Case | Baseline bytes | Candidate bytes | Median paired reduction | Lower candidate pairs |
| --- | ---: | ---: | ---: | ---: |
| `unchanged` | 499,840 | 163,968 | 67.196% | 6/6 |
| `nonmatching_rule` | 499,968 | 164,096 | 67.179% | 6/6 |
| `hide_half` | 251,536 | 251,536 | 0.000% | 0/6 |
| `hide_last` | 499,856 | 487,504 | 2.473% | 6/6 |
| `preview` | 531,968 | 519,680 | 2.310% | 6/6 |
| `tree_input` | 939,840 | 608,032 | 35.305% | 6/6 |
| `hide_penultimate` | 499,856 | 487,440 | 2.484% | 6/6 |
| `preview_last` | 499,904 | 487,616 | 2.458% | 6/6 |
| `keep_one` | 1,136 | 1,136 | 0.000% | 0/6 |

### 10,000 input rows

| Case | Baseline bytes | Candidate bytes | Median paired reduction | Lower candidate pairs |
| --- | ---: | ---: | ---: | ---: |
| `unchanged` | 6,793,472 | 1,421,504 | 79.075% | 6/6 |
| `nonmatching_rule` | 6,793,600 | 1,421,632 | 79.074% | 6/6 |
| `hide_half` | 3,414,736 | 3,414,736 | 0.000% | 0/6 |
| `hide_last` | 6,793,488 | 4,624,464 | 31.927% | 6/6 |
| `preview` | 7,113,600 | 4,942,720 | 30.517% | 6/6 |
| `tree_input` | 13,033,696 | 7,786,832 | 40.256% | 6/6 |
| `hide_penultimate` | 6,793,360 | 4,624,464 | 31.927% | 6/6 |
| `preview_last` | 6,793,600 | 4,624,768 | 31.926% | 6/6 |
| `keep_one` | 1,136 | 1,136 | 0.000% | 0/6 |

### 100,000 input rows

| Case | Baseline bytes | Candidate bytes | Median paired reduction | Lower candidate pairs |
| --- | ---: | ---: | ---: | ---: |
| `unchanged` | 58,452,600 | 15,463,744 | 73.544% | 6/6 |
| `nonmatching_rule` | 58,445,376 | 15,465,128 | 73.540% | 6/6 |
| `hide_half` | 29,233,552 | 29,242,048 | -0.011% | 1/6 |
| `hide_last` | 58,450,144 | 47,465,208 | 18.793% | 6/6 |
| `preview` | 61,648,256 | 50,664,576 | 17.825% | 6/6 |
| `tree_input` | 110,545,864 | 68,603,408 | 37.941% | 6/6 |
| `hide_penultimate` | 58,454,032 | 47,468,368 | 18.796% | 6/6 |
| `preview_last` | 58,454,080 | 47,468,544 | 18.793% | 6/6 |
| `keep_one` | 1,136 | 1,136 | 0.000% | 0/6 |

### Observed storage capacities

All unchanged prepared-row measurements share the input buffer only in the
candidate. The measured row stride is 320 bytes. These observations distinguish
the removed backing allocation from changes in unrelated allocator activity.

| Input rows | Input capacity | Baseline output capacity | Candidate output capacity | Candidate shares input |
| --- | ---: | ---: | ---: | --- |
| 1,000 | 1,011 | 1,049 | 1,011 | Yes |
| 10,000 | 10,009 | 16,793 | 10,009 | Yes |
| 100,000 | 100,006 | 134,348 | 100,006 | Yes |

The sparse `keep_one` control has output capacity **1 in both variants** in
every observation. Filtered and annotated outputs continue to own separate
storage. The full `tree_input` case retains the production tree cache and
projection simultaneously, and its savings remain separate from the prepared-row
deltas. Rounded capacities are observations of this allocator/toolchain, not API
guarantees or fixed byte limits.

Memory benefits are workload-dependent. The 100,000-row `hide_half` control
has a small unfavorable median paired allocator change (0.011% increase)
with equal output capacities. That observation is retained alongside the
larger gains; the experiment does not establish lower allocation in every call.

### Timing controls and unresolved tradeoffs

Timing does not establish a general speedup or CPU neutrality. For example,
`hide_last` at 10,000 rows is slower in all six CPU pairs (47.4% median paired
increase). At 1,000 rows, preview CPU time increases 48.0% and wall time 74.0%
by the same paired calculation. The 100,000-row unchanged case has a 36.8%
median paired wall-time increase despite its lower allocator growth.

The adjacent 10,000-row `hide_penultimate` case is faster in five of six CPU
pairs, and process ranges are broad. These inconsistencies limit attribution
to the algorithm. Source review found extra constant checks and a deferred
prefix traversal, but no repeated whole-array copy or superlinear growth.
A repeatable native slowdown must be treated as a memory/latency tradeoff and
investigated before this draft is considered ready.

All durations below are milliseconds for one cold awaited call. Negative
paired reductions mean slower candidate samples. Both medians and paired
reductions are shown because their signs can differ.

| Case / rows | Wall median baseline → candidate (ms) | Paired wall reduction | CPU median baseline → candidate (ms) | Paired CPU reduction |
| --- | ---: | ---: | ---: | ---: |
| `unchanged` / 1,000 | 7.78 → 8.60 | -15.8% | 7.70 → 7.67 | +1.3% |
| `nonmatching_rule` / 1,000 | 10.77 → 13.00 | -4.5% | 10.57 → 11.65 | -6.8% |
| `hide_half` / 1,000 | 28.90 → 12.88 | +35.5% | 19.65 → 12.01 | +13.1% |
| `hide_last` / 1,000 | 15.80 → 11.15 | +25.4% | 13.53 → 10.95 | +18.5% |
| `preview` / 1,000 | 15.26 → 26.23 | -74.0% | 13.94 → 17.23 | -48.0% |
| `tree_input` / 1,000 | 34.23 → 41.99 | -17.4% | 33.89 → 41.70 | -14.6% |
| `hide_penultimate` / 1,000 | 12.44 → 13.62 | +0.6% | 12.22 → 13.22 | -1.0% |
| `preview_last` / 1,000 | 10.97 → 16.28 | -29.1% | 10.95 → 15.48 | -27.6% |
| `keep_one` / 1,000 | 3.98 → 4.51 | +0.2% | 3.61 → 3.99 | +11.3% |
| `unchanged` / 10,000 | 86.91 → 68.34 | +20.6% | 78.11 → 61.30 | +23.2% |
| `nonmatching_rule` / 10,000 | 173.69 → 116.19 | +30.7% | 159.51 → 113.00 | +29.6% |
| `hide_half` / 10,000 | 160.00 → 94.93 | +35.7% | 115.40 → 87.04 | +23.9% |
| `hide_last` / 10,000 | 229.76 → 317.59 | -78.0% | 169.77 → 239.38 | -47.4% |
| `preview` / 10,000 | 293.94 → 279.50 | -7.4% | 238.32 → 247.75 | -6.9% |
| `tree_input` / 10,000 | 1183.33 → 922.00 | +24.8% | 726.31 → 583.93 | +16.2% |
| `hide_penultimate` / 10,000 | 574.14 → 597.11 | +7.2% | 248.47 → 215.70 | +30.7% |
| `preview_last` / 10,000 | 462.22 → 462.93 | +8.1% | 220.35 → 205.80 | -4.7% |
| `keep_one` / 10,000 | 195.18 → 199.25 | +17.8% | 61.31 → 61.16 | -4.9% |
| `unchanged` / 100,000 | 2932.56 → 3586.23 | -36.8% | 1863.38 → 1998.92 | -5.1% |
| `nonmatching_rule` / 100,000 | 4522.50 → 3719.18 | +9.0% | 2859.61 → 2759.19 | +7.0% |
| `hide_half` / 100,000 | 4033.82 → 3282.48 | +27.9% | 1858.39 → 2015.69 | -2.9% |
| `hide_last` / 100,000 | 4508.08 → 4797.00 | -37.4% | 3189.16 → 3018.28 | -1.5% |
| `preview` / 100,000 | 3161.75 → 2719.75 | +28.4% | 3163.21 → 2674.86 | +18.7% |
| `tree_input` / 100,000 | 4927.46 → 3813.38 | +21.5% | 4907.63 → 3777.22 | +22.0% |
| `hide_penultimate` / 100,000 | 2271.71 → 3003.53 | -9.3% | 2141.05 → 2911.98 | -18.1% |
| `preview_last` / 100,000 | 2010.49 → 1761.98 | +1.8% | 1985.23 → 1723.82 | +3.5% |
| `keep_one` / 100,000 | 562.39 → 552.05 | +18.4% | 556.33 → 547.13 | +18.9% |

## Correctness and validation

Five portable suites cover the source-browser filter, media organization,
visibility-cache boundaries, search and the new row-storage behavior. The
completed Linux run passed 33 baseline release test functions with only the new
positive sharing assertion excluded. It passed all 34 candidate test functions
in both debug and release. All three builds treat compiler warnings as errors.

The baseline sharing test was then run alone and failed as expected. Its nested
borrow comparison keeps both pointers valid for the comparison and never
returns either pointer. The new tests also exercise caller and consumer
copy-on-write isolation; first, middle and last exclusions; annotation creation
and removal; inherited visibility after an earlier view exclusion; empty-folder
hiding; all-hidden regex counts; and exact UTF-8 rule-ID replacement. The existing
suites provide search, grouping, cache-invalidation and cancellation coverage.
See [the focused tests](../Tests/IlliquidAppTests/SourceVisibilityStorageTests.swift).

Thirty-six verification cases—nine workloads at zero, one, 31 and 257 rows—passed
complete byte-for-byte comparison. The length-delimited output encoding includes
every row field, annotation, recognized-media field, hidden/rule count,
thumbnail URL and sorted media path. The actual verification outputs are retained
as deterministic gzip files. Each of the 324 measured observations also supplies a 64-bit FNV checksum
of the complete output, its encoded byte length, counts and rule-count map;
these receipts agree across both variants and every pair in a group. Those
large measurement outputs were compared by checksum and explicit fields. The
36 separate small verification cases were compared byte for byte.

Independent review found no semantic defect in the lazy-prefix implementation:
until the output is materialized, every prior row is included and its original
and computed annotations are both absent. The first divergence therefore copies
exactly the accepted prefix. An all-hidden result remains a materialized empty
array and cannot fall back to the full input. A separate audit script recomputed every reported group from the raw
observations, checked AB/BA ordering and command receipts, parsed every complete
verification snapshot, and verified source identity. See the
[independent audit receipt](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/independent-audit.json).

## Native status and overlapping work

The dedicated [native workflow](../.github/workflows/source-visibility-storage.yml)
has separate component and integration jobs on `macos-26` with the repository's
pinned Xcode 26.6. The component job reproduces the measurements and correctness
checks. The integration job prepares the pinned native SDK, builds the app
dependency graph and runs six adjacent suites, adding
`SourceEmptyFolderVisibilityTests` to the five portable suites.

[Run 40102200273](https://github.com/Jagalite/illiquid/actions/runs/40102200273)
targets published commit `08c6da0cc4aca611adf1ec08da171b23dcbdf207`. The completed evidence in this report is from Linux. Native component
measurements and app integration are tracked in that live workflow; this draft
does not claim completed macOS qualification. The draft should stay unmerged until those results are
available and reviewed. This workflow does not itself provide a visible-playback
or Instruments whole-app memory study.

During review, a concurrently published
[`perf/source-browser-row-storage-20261024` branch](https://github.com/Jagalite/illiquid/tree/perf/source-browser-row-storage-20261024)
was found to address the same redundant row array. Its observed head was
`914b87e4a587676b6d9e97aab0d4b8d26f4fd244`, and the latest branch-specific PR lookup
returned no PR. Comparing that work prompted explicit examination of late-prefix
capacity growth and the additional controls in this final candidate. The two
branches overlap; their row-storage changes and claimed savings must be treated
as one optimization and coordinated before either is merged.

## Reproduction and evidence

Check out the published measured candidate and use Swift 6.1 or later on PATH.
From the repository root:

```sh
python3 Benchmarks/SourceVisibilityStorage/run.py \
  --output /tmp/source-visibility-storage \
  --pairs 6 --sizes 1000,10000,100000
```

The output directory must be new or empty. The isolated component package has
no downloaded dependencies. `--tests-only` runs the semantic tests and baseline
negative control; `--skip-tests` is intended for a separately identified
measurement run. `--pairs 2 --sizes 1000 --smoke` is an exploratory check and
should remain separate from the formal cohort.

The committed evidence includes:

- [Source, environment and executable manifest](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/manifest.json), with `complete: true` and 324 observations.
- [All 27 summary groups](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/summary.json), including all memory, wall-time and CPU ranges and paired changes.
- [Test results](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/tests.json) and [36 complete-byte verification results](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/verification.json).
- [Independent numeric/source audit](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/independent-audit.json) and [publication/source mapping](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/publication.json).
- [Deterministic raw evidence archive](../Benchmarks/SourceVisibilityStorage/evidence/linux-x86_64/raw-evidence.tar.gz): every command and observation, compiler/test logs, all 72 compressed verification snapshots, both staged source packages, the runner and extraction helper, review receipts, and a Git bundle of the exact measured local commit.

The archive contains a SHA-256 inventory for each included file. Its own digest
is recorded in `publication.json`. Extract it with
`tar -xzf raw-evidence.tar.gz`; it deliberately excludes build caches and
toolchain installations. Executable hashes remain in the manifest. The bundle
has the published baseline as its prerequisite; in a full clone, import the
measured local commit with `git fetch /path/to/reproduction/measured-candidate.bundle HEAD`.
The archived independent audit records the original live binary checks; rerunning
those checks requires the original executables or a new benchmark cohort. Report median paired reductions from the
per-pair data; these can differ from a ratio of the two displayed medians. Earlier
pilot or unbounded-growth measurements belong to their own source revisions and
must not be combined with this cohort. The [benchmark README](../Benchmarks/SourceVisibilityStorage/README.md)
describes the extraction boundary, portability adaptations and individual
workloads.
