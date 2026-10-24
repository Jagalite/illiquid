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
Native results will be recorded separately; Linux evidence alone does not
qualify the macOS application graph.

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
