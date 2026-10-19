# Batch source media presence recomputation

## Finding and change

The folder scanner publishes buffered directory summaries on the main actor.
The previous publication loop sorted changed folders deepest first and called
`recompute` for every one. Each call then walked to the watched root, evaluating
every ancestor again. For a wide tree, many sibling updates repeatedly scanned
the same parent child set. The work can grow with the product of batch size and
parent width, even though each directory listing is scanned off the main actor.

The new `SourceMediaPresenceRecomputation.orderedPaths` collects changed paths
and their watched ancestors once, then orders the unique paths with children
before parents. The scanner evaluates each affected folder once using its
existing true/false/unknown calculation. It still merges accepted summaries
first and uses every buffered key as a trigger, including revision-rejected
keys whose stored state needs propagation. Generation/revision gates,
filesystem traversal, cursor budgets, scheduling and observable result setters
are unchanged.

Path lengths are calculated once for sorting. They use `Character.count` so
canonically equivalent Unicode spellings cannot place an ancestor before its
child. The mixed composed/decomposed spelling regression checks both ordering
and the propagated media result.

## Measured result

**2026-10-17, Linux x86_64, Intel Xeon Platinum 8573C, Swift 6.3.2, `-O` with
whole-module optimization.** Ten paired fresh-process measurements per workload,
alternating baseline/candidate order. These are isolated **publication** costs,
not total directory-scan or visible sidebar latencies.

The smaller empty-tree batches improved from 2.539 to 0.296 ms and from
33.001 to 0.927 ms. The 1,024-summary / 4,096-child workload improved from
498.740 to 3.626 ms. Shared-ancestor work is also removed for positive media,
unknown descendants and complete deep-tree batches.

| Publication workload | Baseline median (ms) | Candidate median (ms) | Median paired speedup |
| --- | ---: | ---: | ---: |
| Empty tree: 64 updated summaries, 256 children | 2.539385 | 0.295713 | 8.92x |
| Empty tree: 256 updated summaries, 1,024 children | 33.000881 | 0.927269 | 36.39x |
| Empty tree: 1,024 updated summaries, 4,096 children | 498.739913 | 3.625761 | 139.80x |
| Full 4,097-summary / 4,096-child tree **(stress)** | 1921.749613 | 11.236148 | 169.80x |
| Some changed children contain media: 256 / 1,024 | 4.895387 | 0.640372 | 7.75x |
| Root has direct media: 1,024 / 4,096 | 5.268737 | 2.628932 | 2.01x |
| Incomplete/unreadable descendants: 256 / 1,024 | 31.376998 | 0.738152 | 42.29x |
| Whole 64-level chain | 7.889900 | 0.302068 | 26.00x |
| One changed leaf in a 96-level chain | 0.417467 | 0.478466 | 0.88x |
| Whole 48-level chain with Unicode names | 26.431597 | 3.347443 | 7.98x |
| One changed child with 4,095 cached siblings | 0.336381 | 0.333388 | 1.00x |
| One changed root with 1,024 cached children | 0.011409 | 0.011679 | 0.98x |
| One empty root | 0.002120 | 0.002284 | 0.92x |

The speedup column is the median of ten **paired** ratios, which can differ from
the ratio of the two displayed medians. The complete min/median/max values and
paired reductions are in [summary.json](evidence/linux/benchmark/summary.json);
[measurements.jsonl](evidence/linux/benchmark/measurements.jsonl) and
[pairs.jsonl](evidence/linux/benchmark/pairs.jsonl) retain every sample.

### Tradeoffs and limits

Building the temporary set and order adds work when a publication has no shared
ancestors to deduplicate. The single changed leaf in a 96-level chain rose by
about **61 microseconds** (0.417 to 0.478 ms). The tiny empty-root case rose by
about **0.16 microseconds**; the single-root repair rose by about 0.27 microseconds.
The cached-sibling repair was effectively unchanged in this run. No small-batch
special case was added: the measured absolute overhead is small, while the
implementation remains one ordering policy with explicit parity coverage.

The full 4,097-summary case is a **stress fixture**, not a typical publication.
The production cursor defaults to 256 entries per slice, yields for 10 ms
between incomplete slices, and publishes approximately every 100 ms or on
completion. The 64-, 256- and 1,024-summary cases show smaller batch behavior.
Batch counts in wide fixtures include the root summary.

The benchmark includes real Foundation URL traversal, `@MainActor` execution,
`@Observable` result setters and Swift collection operations. Its default
retains the fixture's initial result snapshot, so the first setter's dictionary
copy-on-write cost is **inside** the timer. There is no subscribed SwiftUI view.
Filesystem I/O, summary acceptance/merging, async scheduling, fixture creation,
result reset and verification are outside the timer. No claim is made about
end-to-end scan time, playback frame rate, rendering latency, energy or memory
footprint. Native macOS component and app-graph checks are wired separately in
[the workflow](../../.github/workflows/source-presence-performance.yml).

## Correctness and measurement protocol

- The production helper passed all **13 repository tests in debug and release**,
  compiled unmodified as an `IlliquidApp` module with `-enable-testing`, Swift 6
  language mode and warnings treated as errors. Coverage includes root and
  prefix boundaries, duplicate and shared ancestors, `/`, Unicode equivalents,
  missing/unreadable/incomplete states, positive propagation, changed parents
  with unchanged children and **1,024 seeded randomized tree scenarios**.
- The benchmark extracts the exact publication loop, recomputation method,
  watched-path checks, summary fields and observed storage declarations from
  baseline commit `68274d1b09dcc866296321a5a8858efc297c4f19` and the candidate.
  The baseline source SHA-256 is checked before compilation; generated fragment
  hashes and complete source snapshots are retained.
- All **78 seeded baseline/candidate fixture comparisons** matched in debug and
  release. All **130 timed pairs** also produced identical complete result maps.
  Each untimed fixture check additionally verifies publication idempotence.
- There are **260 retained timing samples** across 13 workloads. Each timing
  process performs two excluded warm-up publications, then a calibrated number
  of iterations targeting at least 30 ms of timed work. The shortest recorded
  sample was 30.509 ms. Slow stress cases necessarily exceed that target even
  at one iteration. Calibration and compiler work do not enter the reported
  samples.
- `SWIFT_DETERMINISTIC_HASHING=1` gives paired processes matching collection
  layouts; fixture seeds vary between pairs. Source snapshots, compiler and
  platform information, commands, calibration and final-map checksums are
  recorded in [manifest.json](evidence/linux/benchmark/manifest.json) and its
  neighboring evidence files. This is one shared-host run; the retained ranges
  should be considered alongside the medians.

The component test logs are [debug](evidence/linux/tests-debug.txt) and
[release](evidence/linux/tests-release.txt). Their
[receipt](evidence/linux/regressions.json) includes the exact standalone compiler
commands and runner source. This Linux session used Swift Testing's bundled
entry point because its temporary SwiftPM executable was unavailable; the
repository script below uses the normal isolated SwiftPM package on supported
hosts. No full macOS app build is claimed by the Linux evidence.

## Reproduce

With Swift 6.3.2 and Python available, use a new empty output directory:

```sh
bash Scripts/test-source-presence-regressions.sh --jobs 2 -Xswiftc -warnings-as-errors
bash Scripts/test-source-presence-regressions.sh -c release --jobs 2 -Xswiftc -warnings-as-errors
python3 Benchmarks/SourceMediaPresence/run.py \
  --pairs 10 --target-ms 30 --output /tmp/illiquid-source-presence
```

A shallow checkout that lacks the pinned baseline can use the retained source:

```sh
python3 Benchmarks/SourceMediaPresence/run.py \
  --baseline-source Benchmarks/SourceMediaPresence/evidence/linux/benchmark/sources/baseline/SourceMediaPresenceScanner.swift \
  --pairs 10 --target-ms 30 --output /tmp/illiquid-source-presence-shallow
```

`--tests-only` runs debug/release fixture parity without timings. `--case NAME`
selects timing workloads while retaining all correctness cases. `--ownership
unique` is an optional distinct control that forces unique result storage before
timing; the committed measurements use the default shared ownership. Compiler
selection accepts `--swiftc`, `SWIFTC`, or `PATH`.

The macOS workflow repeats component tests and paired timings, and separately
prepares the pinned native SDK, builds the app graph and runs
`SourceMediaPresenceScannerTests` plus `SourceMediaPresenceRecomputationTests`.
That integration suite covers live filesystem traversal, active-job event bursts,
create/remove repairs, cached siblings, rescan and clearing roots.
