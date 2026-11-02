# Playback effect settlement: memory and performance study

## Outcome and scope

**Linux component qualification passed.** Partial-authority settlement requested
32.62–90.79% fewer allocation bytes per event. Ordinary mixed and nearly-full
cases also improved CPU timing; sparse-case timing was inconclusive. Some
workloads made more allocation requests. The benefit concerns temporary reducer
bookkeeping during source replacement, stop, or cancellation.

macOS qualification remained queued as of **2026-10-28 16:49 UTC**; the PR remains
a draft pending that result. These results establish no whole-player, retained
heap, RSS, frame-rate, seek-latency, or battery improvement.

| Reference | Revision or location |
| --- | --- |
| Baseline | [ea2ff568237e2667f7b1aeee67b11a44ebe95b72](https://github.com/Jagalite/illiquid/commit/ea2ff568237e2667f7b1aeee67b11a44ebe95b72) |
| Measured candidate | [427b1d2198aab101809f510cfde281b95778eb66](https://github.com/Jagalite/illiquid/commit/427b1d2198aab101809f510cfde281b95778eb66) |
| Qualification run | [GitHub Actions 40642352444](https://github.com/Jagalite/illiquid/actions/runs/40642352444) |
| Retained evidence | [Linux summary](../Benchmarks/EffectSettlement/evidence/linux/summary.json), [manifest](../Benchmarks/EffectSettlement/evidence/linux/manifest.json), [parity](../Benchmarks/EffectSettlement/evidence/linux/parity.json), [receipt](../Benchmarks/EffectSettlement/evidence/linux/receipt.json), [full review bundle](../Benchmarks/EffectSettlement/evidence/linux/review-bundle.json.gz) |

## Mechanism and tradeoffs

Originally, `settleEffects(for:)` filters outstanding effects, then maps keys
before removing IDs and recording completion. Swift 6.3.3's
[`_NativeDictionary.filter`](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/stdlib/public/core/NativeDictionary.swift)
records matches in a bitset. No matches return an empty dictionary; all matches
return the original dictionary. Only partial matches allocate another record
dictionary, retaining nested metadata storage.

The candidate first checks whether all records match. That path maps keys
directly, preserving the known-size ID array. Otherwise, `compactMap` collects
matching IDs without the record dictionary. Unlike
[`map`](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/stdlib/public/core/Sequence.swift),
[`compactMap`](https://github.com/swiftlang/swift/blob/swift-6.3.3-RELEASE/stdlib/public/core/SequenceAlgorithms.swift)
grows an initially empty array, explaining additional small allocation requests.
Partial matches repeat the preliminary scan through the first nonmatch,
potentially a long prefix for nearly-full matches.

Exact authority equality and collection-before-mutation remain unchanged.
Completed IDs use a contiguous prefix plus a sparse `Set`; traversal order
preserves final membership.

## Method and correctness

The harness compiles the full production core and unchanged `MediaTrack.swift`
dependency. It verifies ancestry, identical source inventories, and that only
`PlaybackCore.swift` differs. The manifest records exact source/binary hashes and
the Swift 6.3.3, Linux x86_64, glibc 2.39 environment.

All 47 cases call public `PlaybackCore.update`: load, stop, and retired cleanup
at 0/1/4/8/32/128/512 records, mixed/no-match populations, and extra 7-of-8,
127-of-128, and 1-of-128 load cases. Diagnostic controls and two retained-snapshot
cases are separate. Larger populations are scaling experiments, not observed
player frequencies.

Baseline release and candidate debug/release each passed **88 tests in nine
suites**. **94 complete semantic traces were byte-identical** across both
insertion orders. Independent expectations and regression tests cover state,
effects, invariants, all four settlement call sites, exact revision boundaries,
failures, duplicates, unknown results, completion gaps, and snapshot isolation.

Both variants calibrated independently toward 180 ms. Six fresh-process pairs
alternated AB/BA order; all **564 timing samples** exceeded the 100 ms CPU/wall
floor, with a minimum of **157.814534 ms**. Fixtures are constructed outside
measurement; each core is updated once. Windows include public update,
production invariants, transition destruction, and a scalar checksum. Fixture
construction/destruction and encoding are excluded.

Separate **564 Linux allocation observations** counted successful
`malloc`/`calloc`/`realloc` requests and requested bytes. Every process passed
its interception self-check. This includes completion-history/emitted-effect
work and measures traffic. Samples, pilots, ranges, and paired ratios are retained.

## Linux results

Medians below are **baseline → candidate per event**. Parentheses show CPU change.
Matches/total counts records seen by settlement; cleanup's triggering cancellation
has already completed.

| Scenario; matches/total | CPU µs (change) | Requested bytes | Allocation requests |
| --- | ---: | ---: | ---: |
| Load; 1/2 | 2.570 → 2.355 (−8.35%) | 2,232 → 1,504 | 5 → 4 |
| Load; 2/4 | 3.241 → 2.865 (−11.60%) | 2,976 → 1,632 | 6 → 6 |
| Load; 4/8 | 4.292 → 3.596 (−16.21%) | 4,400 → 1,808 | 7 → 8 |
| Stop; 4/8 | 4.573 → 3.828 (−16.29%) | 3,504 → 912 | 8 → 9 |
| Cleanup; 4/8 | 3.719 → 3.026 (−18.64%) | 3,064 → 472 | 5 → 6 |
| Load; 64/128 | 33.713 → 24.798 (−26.44%) | 46,560 → 6,104 | 12 → 17 |
| Stop; 64/128 | 33.638 → 25.462 (−24.31%) | 45,664 → 5,208 | 13 → 18 |
| Cleanup; 64/128 | 34.104 → 24.036 (−29.52%) | 45,096 → 4,640 | 9 → 14 |
| Load; 127/128 | 59.846 → 46.278 (−22.67%) | 91,388.33 → 8,419.79 | 13.52 → 18.44 |
| Load; 1/128 | 8.121 → 7.740 (−4.70%) | 2,232 → 1,504 | 5 → 4 |

All **90/90 partial-match allocation pairs** requested fewer bytes. Across all
three operations, mixed-eight cases added one request and mixed-128 cases added
five. Requested bytes improved while request frequency sometimes increased.

CPU improved in **72/72 ordinary mixed pairs** and **12/12 nearly-full pairs**.
Sparse 1-of-128 timing is inconclusive: two of six pairs were slower, spanning
−15.55% to +6.14%, despite the lower median and unequivocal byte reduction.

Controls limit the interpretation:

- All-match unique-state bytes changed −0.51% to +0.53%; CPU changed −3.97% to +1.87%.
- No-match bytes/requests were unchanged; CPU changed −2.76% to +3.26%.
- Retained-snapshot bytes changed less than 0.05%; CPU changed −0.33% and −1.20%.
- Diagnostic allocation counters stayed at zero; CPU changed +0.03% to +2.70%. The
  zero-record case was slower in all six pairs (+0.64% to +4.95%), with a median
  increase of approximately 21 ns.

Hash iteration can affect temporary completion-history allocation. Controls and
variability preclude a universal no-regression claim; the evidence supports a
targeted partial-match allocation improvement.

## Reproduction and experiment history

Reproduce from the **recorded candidate commit**, using Swift 6.3.3 and a fresh
output directory. Follow the
[benchmark README](../Benchmarks/EffectSettlement/README.md), including Kyoto
guidance, with `--pairs 6 --target-ms 180`; compare source hashes to the manifest.
The full workflow is manual. Existing completed-effect-history CI automatically
includes the new regression tests.

The earlier
[unconditional-compactMap experiment](https://github.com/Jagalite/illiquid/commit/6cba034d20ac0603904fada62601e287c5d6ace0)
passed correctness but failed building its allocation meter because `cc` was
missing. Its
[exploratory evidence](../Benchmarks/EffectSettlement/evidence/exploratory-linux/)
supports none of this report's performance claims. Final qualification installed
GCC and reran allocation and timing measurements for the revised algorithm.
