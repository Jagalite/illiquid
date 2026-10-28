# Source media-presence traversal: defer directory identities

## Question and boundary

Can the source sidebar's resumable media-presence cursor scan file-heavy folders
faster by constructing child identities only for directories that need them?

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` (`main` when this study began).
The baseline constructs a Foundation URL and extracts its path for every
enumerated entry. Only ordinary directories consume that path: it becomes the
parent's child key, a cached-result lookup key, or a new traversal frame.

The candidate moves that exact expression into the ordinary-directory branch.
It retains directory-depth unwinding, the parent guard, metadata lookup,
classification, cancellation checks, descendant skipping, and cache semantics.
Directory identities still use the prepared parent's namespace; the enumerator's
absolute path is not substituted, because macOS may spell aliases differently.

This study measures complete cursor traversals over real, precreated directory
trees using native Foundation. It does not measure main-actor publication,
scanner pacing sleeps, source-browser rendering, media decoding, application
startup, energy, or cold/network-volume I/O.

## Acceptance criteria declared before measurement

- Complete results, directory summary fields, and visited-entry counts must
  match the fixture oracle and the baseline in both debug and release.
- The three file-heavy workloads must each reduce median paired elapsed time and
  process CPU time by at least 15%, with at least seven favorable pairs out of
  eight for each metric.
- Directory-only, cached-subtree, and small-folder controls must have no median paired
  elapsed-time or CPU regression greater than 5%.
- All selected component regressions must pass against both implementations;
  the current macOS application graph and selected integration regressions must
  also pass.
- Linux results are exploratory. A native macOS run decides promotion to a PR.
  Preserve every observation, including regressions and failed attempts.
- Every measured native sample must last at least 250 ms. Short observations
  remain in the evidence and prevent qualification; they are not discarded.

## Workloads

Fixtures contain zero-byte files because this cursor reads directory metadata
and filename extensions, never media payloads. Creation is outside all timings.

| Workload | Fixture | Entries visited per traversal | Role |
| --- | --- | ---: | --- |
| `flat_media_4096` | 4,096 playable filenames in one folder | 4,096 | Primary |
| `flat_nonmedia_4096` | 4,096 notes, subtitle sidecars, and cover filenames | 4,096 | Primary |
| `nested_mixed_4096` | Eight shows, eight seasons each, 64 files per season | 4,168 | Primary |
| `directory_only_512` | 16 parent directories, each with 31 children | 512 | Control: every entry still needs a path |
| `cached_repair` | 64 cached positive/negative sibling subtrees | 64 | Control: directory keys and cache lookups remain necessary |
| `small_32` | 32 mixed files | 32 | Control: ordinary small folder |

## Method

The runner stages the complete production scanner into independent baseline and
candidate Swift packages. Shared helpers are copied from the pinned baseline
and current checkout respectively, and source hashes are retained. The only
source extraction is the unchanged `SourceTreeIdentity` declaration from its
SwiftUI-containing file. The harness runs in a separate module; no filesystem,
URL, cancellation, or classification doubles replace production behavior.

Verification uses entry caps of 1, 7, and 256 with a generous time budget, plus
the production 256-entry/20 ms budget. Final result and summary maps are checked
against independently constructed expectations. Fixed-entry traces can be
compared exactly; default-budget scans compare final outputs because faster
traversal may legitimately change slice boundaries.

Timed runs use 256-entry slices with a generous deadline so host speed does not
change slice boundaries. Each process warms the filesystem with two traversals.
Repeated measured traversals include actual enumeration, resource values,
cursor bookkeeping, result accumulation, and temporary-object cleanup. Fixture
construction and full output canonicalization/verification are excluded. These
are **warm filesystem** results.

Both variants use the same iteration count. Calibration targets at least
250 ms for the faster variant. Eight fresh-process pairs alternate AB/BA order,
and workloads rotate between paired blocks. Wall and process CPU time, every
pair, checksums, visited counts, environment, source/binary hashes, commands,
test logs, and calibration are retained. Builds and tests finish before timing.

## Reproduce

On macOS with Swift 6.1 or later and Python 3.10 or later:

```sh
python3 Benchmarks/SourcePresenceTraversal/run.py \
  --output /tmp/illiquid-presence-traversal-results \
  --pairs 8 --target-ms 250
```

The output directory must be new or empty. Follow the repository's `AGENTS.md`
build coordination instructions when Kyoto is available. The dedicated workflow
uses an isolated macOS runner, runs the selected application-graph tests, then
runs this component study. It can run on a research-branch push before a PR.

## Relationship to previous studies

- `SourceMediaPresence` reduces repeated ancestor recomputation during
  publication.
- `SourcePresenceSnapshot` reduces cached-result memory retained by repair jobs.
- `RecursiveMediaScan` changes a separate recursive media inventory path.

This change targets per-entry path construction inside
`SourceMediaPresenceCursor.nextBatch`, which remains in the pinned baseline.

An independent, concurrent investigation published the same production change
on `research/source-presence-traversal-20261028` at
`2c3109a9ea8330799cfe15565e941a445f99dcf2`. Its filenames, output consumption,
cleanup boundary, and acceptance thresholds differ. Keep the two measurement
cohorts separate and land the production change once. This overlap was discovered
after both research branches had been published and native qualification queued.

## Results

Local correctness passed: 23 tests in each of the baseline/candidate debug and
release runs, with complete four-way output equality before and after the
exploratory measurements. The two-pair Linux timings were mixed and do not
qualify the change. The [complete Linux evidence](evidence/linux-exploration/README.md)
retains every sample and the initial test-fixture correction.

### Native attempt 1 — app-test fixture failed before measurement

[Run 40634880691](https://github.com/Jagalite/illiquid/actions/runs/40634880691),
[job 122639438086](https://github.com/Jagalite/illiquid/actions/runs/40634880691/job/122639438086),
on the immutable production/test/harness/workflow revision
`a641d4eed92315eae3c966295df1c5e2b9512185`, completed **unsuccessfully**
on 2026-10-28 on a macOS 26 runner using Xcode 26.6.
The complete release application graph compiled, and **33 of 34 focused tests
passed**. The newly introduced `temporaryDirectoryAliasKeepsTheCallersCacheNamespace`
assumed `/tmp` always resolves to `/private/tmp`; this runner retained a
`/tmp` spelling. That environment-specific assertion failed, stopping the app
step. The component step was **skipped**; no native timing samples were taken.
This is not a scanner correctness failure or a successful qualification.

The [retained, SHA-256-marked gzip evidence bundle](evidence/macos/attempt-1-failure.json)
contains the complete application test log and available machine-readable
receipts, not just the workflow conclusion. The original
[uploaded artifact](https://github.com/Jagalite/illiquid/actions/runs/40634880691/artifacts/12794621057)
provides a second copy. Decode the JSON's `gzipBase64` field as base64 then
gunzip; verify the compressed bytes against its `gzipSha256` field.

The only follow-up code change
([fix `ec9e2fed`](https://github.com/Jagalite/illiquid/commit/ec9e2fed6d66662dc866d4253085887c908236f8))
repairs the test fixture to use the `/private/tmp` spelling only when that
fixture is actually accessible there, otherwise using native resolved spelling.
The production scanner, component harness, workload definitions, thresholds,
and measurement workflow are unchanged. The failed attempt is retained.
[Native requalification run 40642915320](https://github.com/Jagalite/illiquid/actions/runs/40642915320)
was queued for this repaired test; **no performance result is claimed** until
its app receipt, component receipts, source/binary integrity, full output parity,
and every raw measured sample independently satisfy the predeclared criteria.

### Native attempt 2 — paired performance favorable, duration floor not met

[Run 40642915320](https://github.com/Jagalite/illiquid/actions/runs/40642915320),
[job 122664979786](https://github.com/Jagalite/illiquid/actions/runs/40642915320/job/122664979786),
on test-fixture repair revision `ec9e2fed6d66662dc866d4253085887c908236f8`
completed on 2026-10-28 using **macOS 26.6.2, arm64 Apple M1 virtual,
Xcode 26.6, Apple Swift 6.3.3**, Python 3.15.0. The GitHub Actions
workflow concluded green, but **nativeQualificationSuccess=false**.
The full release app dependency graph compiled and its **34 focused tests
passed**. The component's **24 tests passed in all four baseline/candidate
debug/release configurations (96 test executions)**; before/after
verification produced exactly matching four-way complete traversal receipts.
Recorded source and binary integrity checks passed, as did output/checksum
parity in all **48 measured pairs (96 samples)**.

These independent raw-sample recalculations use the **median of eight paired
percentage changes**, not a ratio of separately measured medians. The scan
time columns show separately measured per-traversal medians for context.

| Workload | Wall baseline → candidate (ms/scan) | Paired wall reduction | CPU baseline → candidate (ms/scan) | Paired CPU reduction | Favorable wall / CPU pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `flat_media_4096` | 83.394 → 35.375 | 53.33% | 79.479 → 35.356 | 53.38% | 8/8, 8/8 |
| `flat_nonmedia_4096` | 83.836 → 35.183 | 54.86% | 75.766 → 34.867 | 54.35% | 8/8, 8/8 |
| `nested_mixed_4096` | 88.348 → 39.964 | 53.39% | 87.051 → 39.584 | 52.02% | 8/8, 8/8 |
| `directory_only_512` | 20.619 → 17.117 | 11.89% | 18.275 → 17.021 | 3.30% | 8/8, 8/8 |
| `cached_repair` | 1.368 → 1.283 | 0.07% | 1.231 → 1.254 | 0.03% | 4/8, 4/8 |
| `small_32` | 0.672 → 0.306 | 52.48% | 0.601 → 0.302 | 51.78% | 8/8, 8/8 |

All three primary workloads independently exceed the predeclared 15%
paired-median wall/CPU savings with at least 7/8 favorable pairs, and all
three controls remain within the 5% median regression ceiling. **Nevertheless,
two candidate `small_32` observations fell below the 250 ms measured-sample
minimum**: pair 4 at **237.800042 ms** and pair 5 at **249.418125 ms**,
with a cohort-wide minimum of 237.800042 ms. Both are included in the retained
96-row dataset; neither was discarded or remeasured in that cohort. The
calibration pilot passed but underestimated per-process variation. The native
timing floor is mandatory even for a control, so this run **cannot qualify
the optimization**. Do not combine it with later cohorts or use its favorable
performance numbers to justify a PR.

[Permanent compressed attempt-2 receipts](evidence/macos/attempt-2-short-samples.json)
contain all top-level machine-readable receipts, every raw measurement,
checksum and calibration, plus the app test log. They reproduce the
[original artifact 12856366334](https://github.com/Jagalite/illiquid/actions/runs/40642915320/artifacts/12856366334)
and use a SHA-256-marked gzip/base64 JSON filename-to-content mapping.

### Native attempt 3 — calibration margin correction

Only the research runner's warmup/pilot iteration-count safety multiplier
was increased from **1.5× to 3.0×** in
[commit `6867da97`](https://github.com/Jagalite/illiquid/commit/6867da970f633a9a73611cbcb38e487789c2ac64),
to reduce the chance that an ordinary faster-process fluctuation produces
a measured sample shorter than 250 ms. **The 250 ms acceptance floor, 15%
primary improvement thresholds, 7/8 favorable-pair requirement, 5% control
regression ceiling, six workloads, eight fresh-process pairs, production
scanner, app regression and component tests are unchanged.** The original
short samples remain retained. The
[new independent native run 40780859398](https://github.com/Jagalite/illiquid/actions/runs/40780859398)
is pending qualification; no successful result or PR is claimed from it
until all required receipts and raw samples pass.

Across both attempts, the measured operation remains **warm local real-filesystem
cursor traversal with result accumulation and temporary-object cleanup**,
not whole-player CPU, UI latency, cold I/O, or energy consumption.
