# Sidecar ancestor path-plan research

Native macOS measurements support reusing ancestor paths when a metadata scan
visits consecutive sibling files: at depth 4, the paired median wall-time
reduction was **27.82%** without sidecars, **40.38%** with shared show NFOs, and
**29.99%** with nested PlexMatch mappings. These are component results with warm
filesystem caches. Controls with little or no reuse include slower results.

The reader already caches sidecar contents. This change retains one last-parent
ancestor/sidecar URL plan, bounded by the existing 64-folder limit, to avoid
rebuilding those paths for each sibling. A different parent or source root
builds another plan. Metadata reads, per-file mappings, precedence, cancellation
checkpoints and byte/entry budgets remain on their original paths.

The baseline is `7f9ba073394b77a908e0589447c6edc8d10b832c`; the native candidate
is `e6691567bd74b44f9e42364a70c9ef514cba96e7`. Both variants compile identical
current filename recognition, metadata, NFO and PlexMatch sources, tests and
driver; **only `MediaSidecarReader.swift` differs**. Native source bytes are
unmodified. The earlier Linux cohort measured the working tree later committed
as `56f73526c32de7e4e5f25baf324588482a84a464`; its recorded source, test, driver
and runner hashes were checked against that commit afterward. Production code
and the timing driver are unchanged between those candidate revisions.

## Native macOS results

[Successful native run](https://github.com/Jagalite/illiquid/actions/runs/39846158270),
October 22, 2026: **macOS 26.6.2, Apple M1 (Virtual), Apple Swift 6.3.3**.
Eight balanced AB/BA pairs produced **192 observations across 12 scenarios**.
Each scan recognizes 128 files, except the single-file control. Depth includes
the source root; depth 63 is a deep-tree stress case.

Time columns are independent variant medians in milliseconds per scan.
Percentage columns are **medians of paired percentage changes**, not changes
between those independent medians. Negative means less time. These calculations
can disagree, particularly in noisy controls, so both are retained.

| Scenario | Baseline ms | Candidate ms | Paired wall change | Paired CPU change | Faster wall pairs | Faster CPU pairs |
|---|---:|---:|---:|---:|---:|---:|
| Siblings, depth 1 | 8.322 | 7.491 | −23.97% | −16.27% | 6/8 | 8/8 |
| Siblings, depth 4 | 13.665 | 8.933 | −27.82% | −27.68% | 8/8 | 8/8 |
| Siblings, depth 12 | 29.007 | 12.157 | −58.84% | −58.88% | 8/8 | 8/8 |
| Siblings, depth 63 | 190.897 | 39.863 | −79.29% | −78.41% | 8/8 | 8/8 |
| Shared show NFO, depth 4 | 12.752 | 7.752 | −40.38% | −40.34% | 8/8 | 8/8 |
| Nested Plex mappings, depth 4 | 18.719 | 13.474 | −29.99% | −30.47% | 8/8 | 8/8 |
| Per-file movie NFO, depth 4 | 16.487 | 12.287 | −23.41% | −23.58% | 8/8 | 8/8 |
| Unique parents, depth 4 | 12.732 | 13.543 | −0.19% | **+0.23%** | 5/8 | 3/8 |
| Alternating parents, depth 4 | 10.270 | 10.565 | **+2.49%** | **+2.49%** | 4/8 | 4/8 |
| Unicode folders, depth 4 | 16.325 | 12.682 | −26.20% | −26.16% | 7/8 | 7/8 |
| Extras early return, depth 4 | 1.582 | 1.658 | **+3.57%** | **+3.64%** | 4/8 | 4/8 |
| Single-file scan, depth 4 | 0.107 | 0.111 | **+2.57%** | **+2.75%** | 3/8 | 3/8 |

Depth-4/12/63 siblings and all three sidecar workloads improved in every wall
and CPU pair. The one-entry cache provides no reuse for alternating parents or
single-file scans; their adverse medians are part of the tradeoff. Unique-parent
paired medians are near zero, but its independent medians favor the baseline;
no improvement is established. Extras return before path-plan logic and are an
unchanged-path control; the cause of their slower result was not measured.

All slower pairs remain, including **+20.96%** wall time for depth-1 siblings,
**+8.41%** for Unicode paths, and **+38.23%** for unique parents. Extras range
from **−28.04% to +43.55%**. These are not worst-case or tail-latency guarantees.
The 100 ms calibration was a target, not an enforced minimum: **63 of 192**
measured intervals were shorter; the minimum was **64.131 ms**. See the complete
[summary](results/native-macos/summary.json),
[timing rows](results/native-macos/measurements.jsonl) and
[24 calibration rows](results/native-macos/calibration.json).

### Native correctness and evidence

Baseline and candidate each passed debug and release component suites:
**62 tests in each of four configurations**, including macOS-only PlexMatch
filesystem cases. All **1,421 complete outputs and `filesRead` counts** matched
across 15 scenarios. Stored recognition fields, derived display values, 64/65
ancestor boundaries, decomposed Unicode, cancellation/read order, root/parent
changes, per-file precedence, cached misses and the 16 MiB budget are covered.

The [native evidence](results/native-macos/) preserves both source manifests,
four test logs, [test counts](results/native-macos/tests.json), complete gzip
output snapshots, host/compiler details, command receipts, binary hashes,
calibrations, every observation, completion and audit provenance. The
[verification digest](results/native-macos/verification.json) matches the Linux
canonical-output digest below. **Full-app PR CI remains pending**; these
component suites do not build the app graph.

## Linux exploratory results

Measured October 22, 2026, with Swift 6.3.2 on Linux x86_64 / glibc 2.39.
This earlier cohort is retained separately and is not pooled with native data.
Eight balanced AB/BA pairs produced 192 observations across 12 scenarios.
Every ordinary scan recognizes 128 files; the single-file control recognizes
one. Time columns are independent variant medians in milliseconds per scan.
Percentage columns are **medians of paired percentage changes**, not percentage
changes between those independent medians. Negative means less time. The two
calculations can disagree, as the extras and single-file controls demonstrate.

| Scenario | Baseline ms | Candidate ms | Paired wall change | Paired CPU change | Faster wall pairs |
|---|---:|---:|---:|---:|---:|
| Siblings, depth 1 | 6.582 | 6.007 | −12.56% | −12.50% | 8/8 |
| Siblings, depth 4 | 10.060 | 6.880 | −34.67% | −34.68% | 7/8 |
| Siblings, depth 12 | 20.774 | 9.902 | −54.40% | −54.38% | 8/8 |
| Siblings, depth 63 | 138.081 | 32.030 | −77.58% | −77.58% | 8/8 |
| Shared show NFO, depth 4 | 13.495 | 8.836 | −32.81% | −32.81% | 7/8 |
| Nested Plex mappings, depth 4 | 19.466 | 17.375 | −12.58% | −12.58% | 7/8 |
| Per-file movie NFO, depth 4 | 16.160 | 13.484 | −22.73% | −22.73% | 6/8 |
| Unique parents, depth 4 | 11.153 | 10.872 | −0.16% | −0.16% | 4/8 |
| Alternating parents, depth 4 | 12.388 | 10.855 | −4.47% | −4.19% | 4/8 |
| Unicode folders, depth 4 | 16.121 | 11.528 | −24.16% | −24.15% | 7/8 |
| Extras early return, depth 4 | 2.625 | 2.521 | **+2.14%** | **+3.76%** | 3/8 |
| Single-file scan, depth 4 | 0.119 | 0.120 | −2.82% | −2.63% | 4/8 |

Repeated siblings provide the clearest signal, especially at greater depth.
Unique-parent, alternating-parent and single-file controls each won only four
of eight pairs and do not establish reliable improvements. The extras control
has an adverse paired median. All slower samples remain in the evidence,
including individual wall changes of +9.27% for depth-4 siblings, +13.31% for
Unicode paths and +8.71% for per-file NFOs. This is not a tail-latency guarantee.

The 100 ms calibration duration was a target, not an enforced minimum:
32 of 192 measured intervals were shorter, and the minimum was **63.834 ms**.
The [summary](results/linux-exploratory/summary.json) records each scenario's
minimum, every paired percentage and both CPU and wall medians. No failed or
unfavorable timing rows were discarded from the completed campaign.

### Linux correctness and provenance

Baseline and candidate each passed debug and release component suites:
**59 tests in each of four configurations**. All **1,421 complete recognized
outputs and `filesRead` counts** matched across 15 scenarios. Those outputs
include all stored recognition fields and derived display values. Additional
boundary scenarios accept 64 ancestor folders, reject 65, and exercise
decomposed Unicode. The new regressions also cover cancellation checkpoints,
root/parent changes, exact path spelling, cached misses, precedence and the
16 MiB sidecar byte budget.

The [source manifests](results/linux-exploratory/candidate-sources.json),
[baseline manifest](results/linux-exploratory/baseline-sources.json),
[test counts](results/linux-exploratory/tests.json) and
[full test logs](results/linux-exploratory/) retain the compiled-source proof.
The existing macOS-only PlexMatch filesystem tests retain their platform guard
and do not run on Linux. These component tests do not build the app graph.

The complete [baseline](results/linux-exploratory/baseline-outputs.json.gz) and
[candidate](results/linux-exploratory/candidate-outputs.json.gz) snapshots are
losslessly gzip-compressed. Their decompressed bytes match the original
outputs; canonical JSON for both reproduces the SHA-256 in
[verification.json](results/linux-exploratory/verification.json):
`a6ac48a5bd63846bc3259b8bbc79d951ca6eab63e2f1bc3b4cc1af37971b257e`.
All [timing rows](results/linux-exploratory/measurements.jsonl),
[24 calibration rows](results/linux-exploratory/calibration.json),
[environment](results/linux-exploratory/environment.json), command receipts,
binary hashes and completion receipt are preserved. A separate recalculation
verified row completeness, AB/BA order, hashes and every reported statistic.

The initial sandboxed Linux attempt failed in SwiftPM process accounting
before executing tests. The complete recorded campaign ran with normal process
access. No production workaround was introduced for that environment failure.

### Unicode fixture correction

The [first native attempt](https://github.com/Jagalite/illiquid/actions/runs/39844610485)
failed in the **baseline debug suite, before timing**. `appendingPathComponent`
normalized NFC/NFD fixture spellings on macOS, invalidating the distinct-byte
assertion. Commit `e6691567` repaired the fixture with explicit percent-encoded
`URL(string:)` roots and child URLs, retaining byte-distinction and reused/fresh
parity checks. That commit also updated workflow evidence retention after an
artifact-service timeout: compressed evidence is preserved in job logs and the
artifact upload is optional; qualification remains blocking. Production
sources, driver and runner are unchanged. The Linux cohort remains its original
measurement, not a retest with the repaired fixture. The corrected native run
passed all four suites and completed the timing campaign reported above.

The [correction evidence](results/unicode-fixture-correction-linux/provenance.json)
preserves the corrected test, focused baseline/candidate debug passes, command
receipts and both control logs. Replacing byte equality with String equality
while retaining percent-encoded `absoluteString` keys passes this case; those
ASCII keys remain distinct. A separate control switches to decoded `.path`
keys and canonical String equality: it fails with **two parity assertions**.
Both exact mutations and their hashes are recorded, including the passing
control. This focused Linux check is separate from the subsequent successful native qualification.

## Reproduce

Requires Swift 6.1 or newer and Python 3.10 or newer. Run from a checkout that
contains the baseline commit:

```sh
python3 Benchmarks/SidecarPathPlan/runner.py --output /tmp/sidecar-plan-study
```

Use `--tests-only` for both implementations' debug/release component tests and
complete-output comparison without timing. The output directory must be new
or empty. Native macOS uses unchanged source bytes. Linux substitutes the
reader's Darwin import with Glibc and imports FoundationXML for the NFO parser;
original and compiled hashes record these two adaptations. Test sources remain
unchanged, including the platform guard on the existing macOS-only PlexMatch
filesystem suite.

The standalone Swift package runs the actual sidecar, NFO precedence, PlexMatch
and ancestor-plan regression tests in debug and release for both readers. The
repository's separate full native PR workflow remains the app/test-graph gate.

## Measurement protocol

- The unit is a complete scan of 128 files (one file for the small-scan control).
  Each scan constructs and destroys a new reader, so both its sidecar-content
  cache and ancestor plan start empty on every timed iteration.
- Fixture creation is outside timing. An untimed scan in each process warms
  filesystem caches and shared filename-recognition initialization. These are
  warm-filesystem measurements, not cold-disk measurements.
- Timed work includes every production `recognize` call, actual sidecar probes
  and parsing, result collection, reader lifecycle, and the same small checksum
  consumer. JSON serialization and full output comparisons are outside timing.
- The driver covers sibling files at depths 1, 4, 12 and 63, shared show NFO,
  nested PlexMatch mappings, per-file movie NFOs, Unicode paths, unique parents,
  alternating parents, extra-file early returns and one-file scans. Depth counts
  the source root. Separate output checks cover accepted depth 64 and rejected
  depth 65, plus decomposed Unicode folder names.
- Both variants calibrate once per scenario. A shared iteration count targets
  100 ms for the faster calibration sample. Eight alternating AB/BA pairs use
  fresh processes. Every wall/CPU sample and every calibration is retained;
  no outlier removal or selective reruns occur within a campaign.
- Complete recognized fields and derived display values, plus `filesRead`, must
  match for every fixture. Each timed process also checks its final outputs and
  read count against that complete differential result.
- Reports give medians of each variant's scan times and medians of paired
  percentage changes separately. These two percentage calculations need not
  agree. Raw rows retain minimum sample durations and adverse controls.

## Qualification scope and limits

The practical benefit is reduced repeated path work for consecutive siblings,
using one bounded per-reader plan. Gains depend on depth, visitation order and
sidecar work; unique or alternating parents cannot be assumed to improve.
These synthetic component results do not establish whole-player responsiveness,
frame rate, energy use, cold-disk latency or worst-case latency. Filesystem caches
are warm; reader caches start empty on every scan. The plan adds retained URLs
and strings; allocation/RSS effects were not measured. Native component success,
the full app test graph and installed-app behavior remain separate evidence.
