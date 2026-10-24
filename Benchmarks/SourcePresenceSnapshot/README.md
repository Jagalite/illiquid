# Source-presence repair snapshot memory

This experiment measures the dictionary snapshot retained by a source-library
presence repair job. The original scanner copies all complete, readable folder
results in its library. The candidate limits that snapshot to the repaired
subtree, whose descendants are the only keys its cursor can consult.

## Measured result

Local qualification used Swift 6.3.2 on Linux x86-64 with optimized builds,
six balanced AB/BA pairs per case and independent processes for memory and
timing. All **360 observations / 180 pairs** passed reachable-content parity.
The source fixture stays alive throughout each measurement.

| Cached library folders | Repair fixture folders | Reusable entries before / after | Retained allocator growth before / after |
| --- | ---: | ---: | ---: |
| 1,000 | 8 | 745 / 6 | 17,616 B / 368 B |
| 10,000 | 8 | 7,446 / 6 | 282,624 B / 368 B |
| 100,000 | 8 | 74,466 / 6 | 2,248,704 B / 368 B |
| 100,000 | 256 | 74,466 / 190 | 2,248,704 B / 4,848 B |
| 100,000 | Whole library | 74,466 / 74,466 | 2,248,704 B / 2,249,056 B |
| 100,000 | Filesystem root | 74,466 / 74,466 | 2,248,704 B / 2,248,800 B |

The 100,000-folder/small-repair case drops from **2.14 MiB to 368 B** of
additional allocator-accounted storage, a **99.984%** reduction. This measures
the extra repair snapshot, not the source library's existing storage or the
player's process RSS. The no-reachable-result case also retains 368 B of
measured allocator growth; that residual includes runtime/URL effects, not a
nonempty snapshot.

The change still walks the entire result dictionary. Narrow repairs skip
irrelevant summary lookups and allocations: the 100,000-folder/eight-folder
case's median construction CPU was 39.54 ms before and 9.45 ms after. Whole-root
controls retain all eligible entries and add containment work. The filesystem
root control at that size measured 30.45 ms before and 35.13 ms after; other
whole-library controls also showed overhead. Shared-host timings and the
conservative construction boundary below do not establish a whole-player
speedup. The intended gain is lower temporary retained memory for narrow jobs.

The [Linux evidence](evidence/linux/) includes every raw observation, source
snapshot, build receipt, calibration and successful focused-test log. All
20 helper/recomputation tests pass in debug and release with warnings as
errors. Independent review checked source and binary hashes, all 360 receipts,
and the optimized timing loop's allocation lifetime. The additional scanner
integration tests await the macOS workflow; local component tests do not
establish full native application qualification.

## Reproduce

Requirements: Swift 6.1 or newer, Python 3, and either macOS or Linux with glibc
2.33 or newer. There are no fetched package dependencies. Run from any directory:

```sh
python3 Benchmarks/SourcePresenceSnapshot/run.py \
  --output /tmp/illiquid-source-presence-snapshot \
  --pairs 6 --sizes 1000,10000,100000 --target-ms 80
```

A quick build and semantic smoke, with deliberately insufficient timing samples
for performance conclusions:

```sh
python3 Benchmarks/SourcePresenceSnapshot/run.py \
  --output /tmp/illiquid-source-presence-snapshot-smoke \
  --pairs 2 --sizes 1000 --iterations 2
```

`--swift` selects a toolchain, preserving its `swift` driver symlink name.
`--prepare-only` stages and builds the two binaries without observations. An
output directory must be empty. `--baseline-source` accepts a retained copy of
the original scanner when its Git commit is unavailable, with a mandatory
pinned SHA-256 match.

## Exact source comparison

The baseline is the scanner at
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. Its full source SHA-256 is pinned in
`run.py`. Both variants compile the exact `let reusableResults = …` block from
their scanner, with its original completeness/readability predicate, inside
the same small dictionary owner. Candidate root-URL preparation immediately
preceding that block is included as well. The candidate also compiles the complete,
unchanged `SourceMediaPresenceSnapshot.swift` helper. The cursor's `Summary`
declaration is copied verbatim and must be identical between variants.
The baseline's later cursor-URL construction is outside its measured block.
This timing boundary is conservative for the candidate; it is not an end-to-end
comparison of job setup.
The `SourceTreeIdentity` declaration and complete `NormalizedFileURL.swift`
support file are unchanged production sources and verified identical to the
pinned baseline. Both variants compile the same identity support.

This is a component harness. It does not compile Observation, SwiftUI,
filesystem traversal, scheduling or the rest of the player. Source snapshots,
extracted block locations and hashes, generated Swift, common harness files,
compiler identity, commands, binary hashes and host information are retained
in each output directory. The construction blocks themselves are unchanged;
their containing type and public benchmark entry point are harness code.

## Fixtures and parity

Each library has 1,000, 10,000 or 100,000 stored folder results. The five cases
repair a subtree containing zero, eight or 256 fixture folders, the entire
`/Library` hierarchy, or filesystem root `/`. The latter two are controls where
all original results remain reachable. Paths resembling the repair root, such
as `/Library/Repair-extra`, exercise component boundaries.

Results include both `true` and `false`. Some summaries are absent, incomplete
or unreadable. These exclusions mean the reusable snapshot can contain fewer
entries than the fixture subtree size. A fixture-membership/integer-rule oracle
checks every expected key and Boolean, absence of ineligible keys, the complete
snapshot count and a deterministic digest of reachable results. Baseline-only
unreachable keys are the intended difference. Every paired observation must
have identical reachable results; full-library/root controls must agree in
their complete contents.

## Measurement boundaries

Memory and timings use separate **fresh processes**, run sequentially in
balanced AB/BA pairs. Memory processes warm tiny collection/runtime paths,
construct and retain the source fixture, read the allocator, construct one
snapshot, then read the allocator again while both source dictionaries and the
snapshot remain alive. Fixture construction, validation and JSON encoding are
outside that interval. Dictionary capacity is recorded as a diagnostic.

The primary memory metric is additional **live allocator-accounted bytes**:

- Linux: `mallinfo2().uordblks + mallinfo2().hblkhd`, including mmap allocations.
- macOS: `malloc_zone_statistics(NULL, …).size_in_use`.

These process-wide allocator readings can include allocator rounding and
runtime effects. They are not RSS, peak memory, whole-player footprint, or an
estimate of copied string bytes. The source dictionaries stay alive, so string
storage can remain shared; the snapshot's collection allocation is the target.

Timing processes perform three warm constructions before measuring. A fresh
calibration process for each variant chooses one equal iteration count for a
workload, targeting at least the requested duration for the slower variant.
Each construction is bracketed by monotonic wall and process CPU clocks.
Snapshot destruction, count/capacity consumption and correctness checks happen
outside the brackets. Clock overhead is included and not subtracted. The
measurement does not include scanning, cursor execution or UI responsiveness.

`summary.json` reports medians, ranges and paired percentage changes. The runner
requires semantic parity but intentionally imposes no timing threshold. Use the
whole-library/root controls to assess the extra containment work, and report
CPU tradeoffs alongside retained-memory savings.

Run the regression suite and native source-scanner tests separately. Avoid
running builds, tests or other benchmarks concurrently with formal timing.
