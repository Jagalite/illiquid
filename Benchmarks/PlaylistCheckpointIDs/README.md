# Shuffled checkpoint identity projection

This experiment compares the main-actor shuffle-order reconciliation in
PlaybackController.checkpointSession against the frozen main revision
ea2ff568237e2667f7b1aeee67b11a44ebe95b72.

## Relationship to PR #136

This is an independent qualification companion to
[PR #136](https://github.com/Jagalite/illiquid/pull/136). That PR appeared while
the initial study was running and proposes the same identity-only optimization.
This branch adopts its production implementation unchanged. It adds an
independent expected-ID oracle, checkpoint serialization/restoration coverage,
larger synthetic workloads, separately sampled native peak-allocation machinery,
and retained experiment receipts. Both PRs' existing tests and research remain
available. The parent is pinned to
628bc2fcd24ecfd84cc445e10ba8cf996c94468c.

The initial independent implementation was measured at
416f4d870ba67cce5579d241e6e456c0043caee5 and is preserved in this branch's
merge ancestry. Its complete results remain under
[evidence/initial-linux](evidence/initial-linux). Qualification of the exact
adopted implementation and combined tests is pending.

## Initial portable result

The [initial Linux job passed](https://github.com/Jagalite/illiquid/actions/runs/40639408871/job/122653784919)
using Swift 6.2.1 on x86_64 Linux/glibc 2.39. All 25 focused tests passed in each
of baseline/candidate x debug/release, including 41,261 unique ordering cases.
The study retained 48 verification, 86 calibration, and 288 measured observations.

For unchanged nonempty saved order, the elapsed medians were:

| Input items | Baseline | Initial candidate | Median paired reduction |
| ---: | ---: | ---: | ---: |
| 1,000 | 13.07 ms | 6.98 ms | 46.4% |
| 10,000 | 131.45 ms | 71.40 ms | 45.7% |
| 100,000 | 1,379.02 ms | 761.88 ms | 44.8% |

All twenty 32-to-100,000-item cases were faster in each of six pairs and met the
duration floor. Unique-item workloads reduced paired elapsed time by 44-47%;
duplicate inputs with about 50% unique identities improved by 31-32%. CPU
observations agreed closely. The singleton with empty saved order was effectively
unchanged (1.4% paired difference); neither zero-item control met the duration
floor, so neither supports a quantitative speed claim.

These are synthetic component results on a shared Linux runner. Every local path
contains precomposed Café, and subtitle metadata shares
one array. Foundation implementation and path representation can change both
absolute and relative costs. Full macOS application compilation, controller
integration, UI latency, and native allocation measurements remain unqualified.
In particular, the empty saved-order path may increase transient peak memory
because its set and output-order array coexist; that requires native measurement.

## Change and hypothesis

The previous caller reconstructs a complete ordered playlist with
PlaylistMutation.restoringOrder and then maps every returned item to its ID.
For nonempty saved order, restoration temporarily retains a dictionary of complete
items, an identity-order array, and a restored item array. The final projection
normalizes each returned item's URL again.

The new restoringIDs helper computes each input identity once, retains only
identities in its temporary containers, and returns the order directly. It keeps
surviving saved IDs first and appends new IDs in current order. Duplicate current
items and duplicate saved IDs retain the first current identity. Removed entries
stay removed. Empty/singleton inputs avoid a set allocation.

The set's removed member supplies the returned spelling, so a canonically equal
saved Unicode string cannot replace the current identity's UTF-8 representation.
No persistent cache, new actor, filesystem access, or checkpoint scheduling change
is introduced. Both implementations remain O(N + M) for N current items and M
saved IDs. The item payloads were already shared; this removes temporary container
storage and repeated identity work, not deep copies of media/subtitle data.

## Reproduce

Requires Swift 6.1 or newer with bundled Swift Testing, Python 3.9 or newer, and
the pinned commit in local Git history. Timing and correctness can run on Linux;
the allocator sampler requires macOS. Follow AGENTS.md and submit builds through
Kyoto when the shared queue is available. Builds in this runner are serialized.

    python3 Benchmarks/PlaylistCheckpointIDs/run.py \
      --output /tmp/playlist-checkpoint-ids --pairs 6 --memory-pairs 4 --target-ms 100

    python3 Benchmarks/PlaylistCheckpointIDs/run.py \
      --output /tmp/playlist-checkpoint-ids-tests --mode tests

Output directories must be empty or new. The dedicated workflow runs the native
experiment on macOS 26 with the repository's selected Xcode. Existing playlist
restoration CI also runs the new tests as part of its regular PR qualification.

## Correctness and source boundaries

Both baseline and candidate compile the complete production FolderPlaylist,
PlaylistMutation, NormalizedFileURL, and NaturalFilenameOrdering files. The runner
rejects changes to the three supporting files and to the original restoringOrder
declaration. It checks that the actual controller checkpoint method changes only
the qualified projection expression.

The same four test files run against both variants in debug and release. A
baseline-only test shim exposes the old expression as restoringIDs; it is not
compiled into the performance module. The existing integer-label oracle covers
41,261 queue/saved-order combinations. Added tests cover decoded raw URLs,
canonical Unicode spelling, and repeated checkpoint/serialization/restoration
cycles.

Performance modules compile separately with -O, whole-module optimization,
Swift 6, and no cross-module optimization. The identical driver selects the old
caller expression or new API at compilation. Each observation checks the complete
output order and every ID's UTF-8 bytes against unchanged restoringOrder, and
records a deterministic fingerprint. Pair fingerprints and checksums must match.

## Timing protocol

There are 24 predefined workloads: empty/singleton controls, plus 32, 1,000,
10,000, and 100,000 items with empty, unchanged, reversed, stale/appended, and
duplicate saved/current orders. Fixture construction and validation are outside
measurement. A shared subtitle array and dates supply realistic item metadata.

Each call constructs, consumes, and disposes its result inside an autorelease
pool. Calibration observes both variants, sets a shared iteration count, and is
preserved but excluded from results. Six fresh-process pairs alternate baseline
first and candidate first. CPU and elapsed measurements are uninstrumented.
Every pair is retained; there is no speedup threshold or outlier deletion.
A duration-qualified flag identifies loops below one quarter of the target.

## Memory protocol and limits

A separate cold process observes one projection, with no warmup or reference
computation beforehand. The fixture's setup pool drains before the observer
starts. A C pthread samples malloc_zone_statistics(NULL).size_in_use at a
requested 200 microsecond interval. Its initial reading follows thread setup;
the result and input remain alive through its final sample and thread join.
Validation and reporting happen afterward.

The fixed memory cohort consists of the empty-call observer floor and
1,000/10,000/100,000 items with empty, unchanged, and duplicate orders, four
alternating pairs each. The metric is sampled peak live allocator bytes above
the initial reading. Sample count, observation window, maximum sample gap,
final live bytes, and process-lifetime peak RSS before/after are also retained.

This is not allocation traffic or an exact instantaneous peak. Short transients
can be missed, and all-zone statistics are not an atomic snapshot. Sampling can
perturb the allocation schedule, so sampled durations are not used for speedups.
RSS includes setup and other process memory; fixture construction can already
set its high-water mark. Neither metric establishes whole-player RAM, playback
smoothness, energy use, or disk encoding/write latency.

## Evidence

The initial study's [manifest](evidence/initial-linux/manifest.json),
[all workload summaries](evidence/initial-linux/summary.json),
[raw observations](evidence/initial-linux/observations.jsonl), command receipts,
and test logs are retained verbatim with
[SHA-256 recovery receipts](evidence/initial-linux/provenance.json).
The initial container ownership setup failure occurred before compilation and
produced no measurements; its [failure receipt](evidence/setup-failure/summary.json)
and commands are also preserved.

The exact adopted PR #136 implementation is being rerun with the combined tests.
The Darwin sampler and full macOS application graph remain pending. No measured
native memory reduction or whole-player improvement is claimed.

## API references

- [Swift string equality and canonical equivalence](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/stringsandcharacters/)
- [Swift set removal returns the removed value](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/collectiontypes/)
- [Apple allocator statistics declarations](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h)
