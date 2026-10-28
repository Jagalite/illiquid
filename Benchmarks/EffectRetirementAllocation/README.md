# Effect retirement allocation research

This study targets the partial-match temporary dictionary built by
`PlaybackCore.settleEffects(for:)` when it retires a playback authority. The
baseline filters outstanding-effect records, then maps the filtered dictionary
to IDs. Swift 6.1.3 shares the original dictionary when every record matches and
returns an empty dictionary when none match; only partial matches construct a
new full-record table. The candidate examines each authority once by index, preserves empty and
all-match paths, and collects only IDs for partial matches before running the
existing removal/completion loop. It defers collecting a matching prefix until
the first nonmatch proves the selection is partial; only that prefix's keys
are revisited, without checking those authorities again.

The baseline is `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. This is a separate
investigation from checkpoint folder-membership construction.


## Decision and tradeoffs

Keep the single-pass revision as a reviewable optimization for partial-selection
allocation traffic. At 4,096 records with half retiring, median requested bytes
fell from **1,427,728 to 132,968** (90.7% paired reduction), while elapsed time
fell from **1,061.95 to 607.57 microseconds** (42.6% paired reduction). All six
pairs were faster in every nonempty mixed case. All-match/4,096 also ran 34.2%
faster with the same median requested bytes.

This is a conditional improvement. At 4,096 records, the no-match control's
median event time rose from 97.20 to 104.47 microseconds (+13.8% paired change,
four of six pairs slower); the one-match control rose from 95.57 to 110.37
microseconds (+10.3% paired change, all six pairs slower). At 512 records, those
controls rose 10.8% and 8.6%, respectively, with all pairs slower. These are
recorded regressions, even though they are much smaller than the rejected
versions' large control costs. Their impact depends on real authority-population
frequencies, which this study does not estimate.

Partial ID-array growth also makes more small requests: mixed/4,096 made a
median **24 allocation requests versus 14** for the baseline, despite requesting
90.7% fewer total bytes. The smaller mixed cases similarly increase request
counts. The sparse case instead falls from two requests/768 bytes to one
request/40 bytes. The intended memory benefit is reduced cumulative requested
bytes, not a universal decrease in allocation count.

Native qualification is pending. The evidence supports publishing a draft for
review; it does not establish a merge-ready macOS or full-application result.

## Single-pass qualification results

Measured candidate: [`896038769f4e0710f207e8779edbc9c09176ed4c`](https://github.com/Jagalite/illiquid/commit/896038769f4e0710f207e8779edbc9c09176ed4c). The successful
[Linux job](https://github.com/Jagalite/illiquid/actions/runs/40642978782/job/122665183998)
used Swift 6.1.3, x86_64 Linux, glibc 2.39. Native macOS 26/Xcode 26.6 qualification is still queued as of 2026-10-28 06:26 UTC; the PR remains a draft.

All four baseline/candidate debug/release test configurations passed with 114
tests each. The final cohort contains **576 process observations**: 24 workloads,
six paired executions, two variants, and separate timing/allocation modes. An
[independent audit](evidence/v3-deferred-prefix/audit.json) recomputed checksums, paired statistics and
medians, verified the complete observation grid and source provenance, and
checked the allocation-probe self-test. No observations were discarded.

| Population | Effects | Baseline µs | Candidate µs | Paired time change | Baseline requested bytes | Candidate requested bytes | Paired byte change | Requests, baseline → candidate | Faster pairs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| all | 0 | 2.52 | 2.50 | -1.0% | 0 | 0 | — | 0.0 → 0.0 | 5/6 |
| all | 1 | 2.91 | 2.72 | -6.0% | 40 | 40 | 0.0% | 1.0 → 1.0 | 6/6 |
| all | 8 | 5.35 | 4.30 | -20.4% | 376 | 336 | 0.0% | 4.0 → 3.5 | 6/6 |
| all | 32 | 13.73 | 9.87 | -28.4% | 1,556 | 1,680 | -9.5% | 15.0 → 7.0 | 6/6 |
| all | 512 | 204.58 | 130.84 | -35.6% | 21,344 | 21,344 | 0.0% | 11.0 → 11.0 | 6/6 |
| all | 4,096 | 1,708.98 | 1,120.76 | -34.2% | 166,664 | 166,664 | 0.0% | 14.0 → 14.0 | 6/6 |
| mixed | 0 | 2.52 | 2.49 | -0.5% | 0 | 0 | — | 0.0 → 0.0 | 5/6 |
| mixed | 1 | 2.91 | 2.75 | -5.5% | 40 | 40 | 0.0% | 1.0 → 1.0 | 6/6 |
| mixed | 8 | 4.68 | 3.73 | -20.6% | 2,936 | 344 | -88.3% | 4.0 → 5.0 | 6/6 |
| mixed | 32 | 9.62 | 6.69 | -30.8% | 11,544 | 1,400 | -87.9% | 7.0 → 10.0 | 6/6 |
| mixed | 512 | 115.81 | 71.28 | -39.0% | 178,984 | 17,136 | -90.4% | 11.0 → 17.0 | 6/6 |
| mixed | 4,096 | 1,061.95 | 607.57 | -42.6% | 1,427,728 | 132,968 | -90.7% | 14.0 → 24.0 | 6/6 |
| none | 0 | 2.50 | 2.52 | +0.9% | 0 | 0 | — | 0.0 → 0.0 | 2/6 |
| none | 1 | 2.56 | 2.56 | -0.5% | 0 | 0 | — | 0.0 → 0.0 | 5/6 |
| none | 8 | 2.75 | 2.78 | +1.3% | 0 | 0 | — | 0.0 → 0.0 | 3/6 |
| none | 32 | 3.23 | 3.34 | +3.3% | 0 | 0 | — | 0.0 → 0.0 | 0/6 |
| none | 512 | 13.81 | 15.46 | +10.8% | 0 | 0 | — | 0.0 → 0.0 | 0/6 |
| none | 4,096 | 97.20 | 104.47 | +13.8% | 0 | 0 | — | 0.0 → 0.0 | 2/6 |
| sparse | 0 | 2.50 | 2.50 | -0.4% | 0 | 0 | — | 0.0 → 0.0 | 3/6 |
| sparse | 1 | 2.93 | 2.68 | -8.5% | 40 | 40 | 0.0% | 1.0 → 1.0 | 6/6 |
| sparse | 8 | 3.30 | 3.05 | -7.4% | 768 | 40 | -94.8% | 2.0 → 1.0 | 6/6 |
| sparse | 32 | 3.81 | 3.56 | -5.4% | 768 | 40 | -94.8% | 2.0 → 1.0 | 5/6 |
| sparse | 512 | 14.72 | 15.97 | +8.6% | 768 | 40 | -94.8% | 2.0 → 1.0 | 0/6 |
| sparse | 4,096 | 95.57 | 110.37 | +10.3% | 768 | 40 | -94.8% | 2.0 → 1.0 | 0/6 |

Times and byte counts are medians of six process observations per variant.
Percentages are the median of six paired candidate/baseline ratios minus one;
they need not equal the percentage change between the displayed medians. A dash
means both variants requested zero bytes. Timing processes contain many summed
reducer updates, not independent statistical repetitions. The shortest aggregate
timing sample was 4.637 ms and the longest was
60.906 ms. Treat small differences cautiously; six
pairs do not establish universal or statistically significant speedups.

The all/mixed/none/sparse populations retire all records, alternating records,
no records, or exactly one record (when nonempty), respectively. These are
synthetic controls and stress cases; their frequencies in live playback were
not measured.

The durable [evidence index](evidence/index.json) links all three measured commits
and job URLs. Each cohort preserves every observation, numeric result, manifest,
test receipt and independent audit recovered from the successful job log.
Rejected cohorts remain separately identified. Full calibration files, command
and test logs, source snapshots, binaries' hashes and semantic receipt files are
also in the CI artifacts, retained for 14 days; not every artifact file is
copied into this repository.


## Reproduce

On a host with Swift 6.1 or later:

```sh
python3 Benchmarks/EffectRetirementAllocation/run.py \
  --pairs 6 --target-ms 50 --output /tmp/effect-retirement-results
```

Use a new output directory. When the shared Kyoto queue is available, submit
that complete command through it as required by `AGENTS.md`. The hosted jobs
explicitly record Kyoto's absence and compile isolated packages serially.

## Correctness

The new regression suite drives the real reducer through source replacement,
pending-load supersession, stop, and successful/failed cancellation. It covers
exact authority equality across sessions, generations and revisions, survival
of application effects, late duplicate/unknown callbacks, state-copy isolation,
and Codable round trips. It also checks all 64 assignments of six records to
the retiring versus application authority, including their later callbacks.
Both baseline and candidate run the complete Core and
StateSpace test suites in debug and release.

The eager ID collection must finish before removals begin. A lazy dictionary
view could retain the original storage and cause copy-on-write during removal.
The candidate intentionally preserves the eager boundary.

## Measurements

Both variants compile complete production Core and StateSpace modules with the
real `MediaTrack.swift` dependency. There are no extracted declarations,
substitute reducers, or platform stubs. The runner records all source hashes and
rejects any production difference outside `PlaybackCore.swift`.

The fixture first performs real events to load A paused and prepare replacement
B through its open result. It then seeds checkpoint records using unused effect
and operation IDs. Populations are 0, 1, 8, 32, 512, and 4,096 records, with all,
alternating, or none belonging to A's retiring authority. The mixed population
is a synthetic authority-selection stress case, not an observed player workload.

Only the real `core.update` that accepts B's preroll completion is measured.
It commits B, retires A's matching effects, and preserves unrelated records.
Fixture creation, result consumption, canonicalization, encoding, and state
destruction are outside that event's window. Setup owners are released before
the timed update so they do not keep an extra copy of its dictionary.

The revised cohort also includes a sparse case with only the first seeded
record matching, for 24 workloads in total. The single-pass revision reserves
only the known matching prefix and then grows the partial ID array as needed.
It never reserves the total outstanding population for a sparse selection.

Six baseline/candidate pairs alternate AB/BA in fresh processes. Timing targets
50 ms of summed event time, with a cap on excessive setup work and 20,000
iterations. This is a target, not a guaranteed minimum sample duration. Every timed event
contributes to a noninlined checksum. A separate untimed fixture verifies exact
outstanding records, completion membership, session state, allocator and event
counters, invariants and Codable round trips. Every measured transition checks acceptance, invariants, and the cheap
checksum. Each process also checks one fresh untimed fixture in detail. Paired
processes must produce the same production canonical FNV-1a64 digest; the
otherwise-omitted pending-session field is explicitly checked absent. The
`semantic_sha256` field hashes that receipt string for archiving, not the full
state representation.

Linux additionally runs separate allocation processes. Their preload library
counts successful `malloc`, `calloc` and `realloc` requests on the measured
thread, enabled only around the synchronous reducer update. A standalone
self-test checks an empty window and three known requests totaling 225 bytes.
Timing processes explicitly omit the preload library.

Requested bytes measure cumulative allocation traffic, including a successful
reallocation's requested new size. They are not retained bytes, peak memory,
resident memory, allocator usable sizes, or object counts. Aligned allocation
APIs and frees are excluded. Native macOS runs do not use this Linux probe.

Dictionary iteration order may change, so the sparse completion-history Set
can take a different temporary allocation path. The measured totals cover the
complete reducer transition; individual byte differences are not all assigned
to the removed dictionary.

## Evidence and limits

The workflow retains source/test/driver snapshots, compiler and binary hashes,
test and command logs, calibration, every raw observation, semantic receipts and
summaries. Important records also appear as `EFFECT_TEST`,
`EFFECT_OBSERVATION`, `EFFECT_RESULT` and `EFFECT_MANIFEST` lines in the job log.

Linux component results do not establish macOS timing or allocation behavior.
These tests do not build the full media-player application or exercise live
playback, native renderer resources, UI latency, power or energy. Both versions still scan outstanding effects and build an ID array when
matches exist; the asymptotic selection complexity remains linear.


## Rejected first implementation

The first experiment used eager `compactMap`. It passed all 113 Core/StateSpace
tests in each baseline/candidate debug/release configuration, but its controls
ruled it out. In the Linux 4,096-effect case with no matching authority, median
elapsed time increased from 74.87 to 353.66 microseconds (+377.3% paired change).
With all effects matching, median requested bytes increased from 166,664 to
265,136 (+59.1% paired change). Partial-match requested bytes fell substantially,
but those regressions made the simple rewrite unsuitable.

## Rejected counted-selection implementation

The second experiment counted matching authorities, reserved exactly that many
IDs, and scanned again to collect them. It passed the same 113 tests in all four
configurations. Mixed/4,096 requested bytes fell from 1,427,728 to 83,664 (94.1%)
and paired elapsed time fell 30.9%. However, the added sparse cases caught the
second scan's cost: sparse/512 elapsed time increased 36.8% and sparse/4,096
increased 58.2%, with all six pairs slower in both cases. This version was also
rejected.

The single-pass revision checks each authority once, retaining the indexed
projection and efficient all/none cases. All earlier observations are retained
as rejected cohorts; their improvements are not presented as final results.

The relevant standard-library fast paths are in
[Swift 6.1.3 NativeDictionary.swift](https://github.com/swiftlang/swift/blob/swift-6.1.3-RELEASE/stdlib/public/core/NativeDictionary.swift).
