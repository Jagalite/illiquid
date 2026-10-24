# Source-presence scan snapshot memory

## Finding and change

`SourceMediaPresenceScanner.start()` creates an immutable cache snapshot for each
resumable folder scan. Previously it included every complete, readable result
from all watched folders. A cursor only queries keys beneath its own scan root,
so a repair of a small subtree retained unrelated cached results throughout its
traversal and asynchronous waits.

`SourceMediaPresenceCursor.reusableResults(in:results:summaries:)` now limits that
snapshot to the job's root and descendants. It keeps the existing complete and
readable checks, preserves both positive and negative results, and uses one
summary lookup per matching path. The scanner's main results and summaries stay
intact for later jobs and ancestor recomputation. Traversal, publication cadence,
revision/generation gates, and invalidation behavior are unchanged.

Containment follows the existing component-boundary rule: a root matches itself
and its slash-delimited descendants, with `/` handled separately. Cursor keys
are constructed from the normalized parent identity and each item's final path
component; symlinks and packages are skipped before cache lookup. Consequently,
an unrelated watched root cannot supply a cache hit to the current cursor.

## Memory ownership matters

Swift's `Dictionary.filter` can share its input storage if every entry passes.
In that common completed-scan case, the old snapshot initially allocates no new
table. The first scanner publication must then copy the source dictionary while
the cursor keeps the old table alive. If some summaries are ineligible, the old
filter instead creates a broad filtered table immediately.

The benchmark samples both cases explicitly. It records allocator-accounted
bytes before snapshot creation, with the snapshot alive, after publishing one
new result, and after releasing the snapshot. Fixture setup reserves capacity
for that new key, so dictionary growth is not confused with copy-on-write. The
input dictionaries leave their construction scope before sampling; an accidental
second owner would otherwise force copying in the candidate too.

These are **incremental component allocations**, not process RSS, physical
footprint, peak app memory, or total library storage. There is one cursor job at
a time per scanner. No whole-player memory or playback-frame-rate benefit is
claimed.

The isolated harness has no subscribed UI or retained source-browser projection.
In the app, `SourcesSidebar` observes the results map and passes it into
`SourceTreeProjectionInput`; `SourceBrowserFilter.cachedInput` can retain that
map too. Those owners can still make a publication copy the full dictionary.
This change removes the cursor's reason to keep unrelated entries alive after
other consumers replace or release their old snapshots; it does not eliminate
every full-map copy or establish the app's peak-memory reduction.

## Native macOS component qualification

The macOS component job passed on **macOS 26.6.2, an Apple M1 virtual runner,
arm64, Apple Swift 6.3.3**, using the same six balanced pairs and all nine workloads. The
tested code is commit `6122d0584733e84f85ee6d86dda29e6215b7952c`; source and
harness hashes match the Linux experiment. The native records are in
[`evidence/macos`](evidence/macos), and the qualification run is
[#40101026865](https://github.com/Jagalite/illiquid/actions/runs/40101026865).

Median allocator delta **after the first publication with the snapshot alive**:

| Cached folders / folders within this job | Baseline | Candidate | Reduction |
| --- | ---: | ---: | ---: |
| 32 / 8, complete summaries | 1,280 B | 384 B | 70.00% |
| 1,000 / 100, complete summaries | 48 KiB | 5 KiB | 89.58% |
| 10,000 / 100, complete summaries | 288 KiB | 5 KiB | 98.26% |
| 100,000 / 100, complete summaries (stress) | 4,505,600 B (4.30 MiB) | 5 KiB | 99.89% |
| 100,000 / 10,000, complete summaries (stress) | 4,505,600 B | 288 KiB | 93.45% |
| 100,000 / 100, mixed eligibility (stress) | 2,260,992 B | 2.5 KiB | 99.89% |
| Whole tree: 100,000 / 100,000 (control) | 4,505,600 B | 4,505,600 B | 0% |
| Filesystem root: 10,000 / 10,000 (control) | 288 KiB | 288 KiB | 0% |

Every nonempty case releases the entire measured increment when the cursor
snapshot is released. The empty case has an equal 64-byte publication increment
in both variants, with no snapshot-attributed allocation. Whole-tree controls
remain unchanged in memory because the whole cache is relevant to those jobs.

The snapshot construction/destruction CPU medians were:

| Workload | Baseline | Candidate | Median paired CPU reduction |
| --- | ---: | ---: | ---: |
| Repair 1,000 / 100 | 0.322 ms | 0.0346 ms | 89.20% |
| Repair 10,000 / 100 | 3.407 ms | 0.258 ms | 92.37% |
| Repair 100,000 / 100 (stress) | 33.624 ms | 5.964 ms | 82.40% |
| Repair 100,000 / 10,000 (stress) | 36.480 ms | 9.293 ms | 75.22% |
| Mixed 100,000 / 100 (stress) | 53.567 ms | 7.362 ms | 86.28% |

All eight nonempty workloads improved in all six CPU pairs. Pairwise reductions
are the median of paired ratios, so they can differ from the ratio of the two
displayed medians. The empty-input control rose from 0.217 to 0.425 microseconds
(about 0.21 microseconds absolute); it does no path scanning or allocation that
the new helper can avoid. No empty-input special case was added for that small
absolute cost. These timers exclude source publication and the other work listed
in the measurement scope above.

The native component ran all **21 regression tests in debug and release**, and
all **54 paired reachable-lookup comparisons** passed. The separate native
integration job built the full application graph using the pinned native SDK
and passed **27 tests across three suites** in release mode without parallel
execution: `SourceMediaPresenceScannerTests`,
`SourceMediaPresenceRecomputationTests`, and `SourceMediaPresenceReuseTests`.
Both jobs completed successfully. The exact test/build log and qualification
receipt are retained as [`native-integration.log`](evidence/macos/native-integration.log)
and [`qualification.json`](evidence/macos/qualification.json). The evidence-only
follow-up changes the report and retained logs, not the tested production code,
tests, benchmark, or workflow.

## Linux qualification

Swift 6.3.2 on Linux x86_64; six balanced fresh-process baseline/candidate pairs
per workload, with deterministic hashing and a different fixture seed per pair.
The baseline is the unmodified scanner from
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.

Median allocator delta **after the first publication with the snapshot alive**:

| Cached folders / folders within this job | Baseline bytes | Candidate bytes | Reduction |
| --- | ---: | ---: | ---: |
| 1,000 / 100, complete summaries | 35,152 | 4,464 | 87.30% |
| 10,000 / 100, complete summaries | 282,624 | 4,464 | 98.42% |
| 100,000 / 100, complete summaries (stress) | 4,493,312 | 4,464 | 99.90% |
| 100,000 / 10,000, complete summaries (stress) | 4,493,312 | 280,656 | 93.75% |
| 100,000 / 100, mixed eligibility (stress) | 2,244,688 | 2,272 | 99.90% |
| Whole tree: 100,000 / 100,000 (control) | 4,493,312 | 4,493,312 | 0% |
| Filesystem root: 10,000 / 10,000 (control) | 282,624 | 282,624 | 0% |

The complete-summary stress repair reduces the measured live increment from
about **4.29 MiB to 4.36 KiB**. Releasing the snapshot removes the measured
increment in both implementations. Whole-tree controls retain the same amount
because every cached result is relevant to that job.

Snapshot construction/destruction CPU medians fell from 1.786 to 0.207 ms for
the 10,000/100 repair and from 30.461 to 6.890 ms for the 100,000/100 stress
repair. Source publication, filesystem I/O, UI rendering, fixture creation,
lookup verification and allocator sampling are outside these timers. The
empty-input control rose from approximately 0.105 to 0.201 microseconds. Small
allocator deltas can be hidden by allocator caches; zero measured delta for the
32/8 case is not a claim that its snapshot has no storage.

All **21 component tests pass in debug and release**, including the eight new
reuse regressions and the 13 existing recomputation tests. The new tests cover
path boundaries, `/`, Unicode equivalence and original key bytes, positive and
negative results, missing/incomplete/unreadable summaries, independent snapshots,
real cursor traversal equivalence, and create/remove repair across two watched
roots. The benchmark verifies every input-key lookup and all **54 paired
reachable-lookup receipts**. There are 108 retained timing/memory samples across
nine workloads; no samples are discarded.

Raw records, ranges, source hashes, compilation logs and all test logs are in
[`evidence/linux`](evidence/linux). Native macOS qualification is run by the
existing [source-presence workflow](../../.github/workflows/source-presence-performance.yml).
The native component results above independently confirm the allocation change;
Linux evidence alone does not qualify the macOS application graph.

## Reproduce

From the repository, with Swift 6.1+ and Python 3.10+ on macOS or Linux with
glibc 2.33+, use a new empty output directory:

```sh
python3 Benchmarks/SourcePresenceSnapshot/run.py \
  --pairs 6 --target-ms 50 --output /tmp/illiquid-presence-snapshot
```

`--tests-only` runs the component regression suites in debug and release.
`--cases repair-10000-100,whole-tree-100000` selects measurement workloads.
`--skip-tests` is for exploratory runs and is marked in the completion record.
The frozen baseline and its SHA-256 receipt allow shallow checkouts to reproduce
the comparison.

The isolated package compiles the complete production scanner/cursor, its
Foundation-based core dependencies, root pruning and recomputation helpers. The
exact `SourceTreeIdentity` declaration is extracted from `SourcesSidebar.swift`.
The timing adapter copies the exact snapshot statements and observed storage
declarations into a small main-actor shell; the candidate calls the real helper.
Generated sources and their hashes are retained under the output's `build/`
directory and manifest. The macOS integration job separately builds the full app
graph with the pinned native SDK and runs the existing scanner suites plus the
new reuse suite in release mode without parallel tests.
