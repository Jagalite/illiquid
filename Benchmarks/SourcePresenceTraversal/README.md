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

### Native attempt 3 — qualified macOS result

[Run 40780859398](https://github.com/Jagalite/illiquid/actions/runs/40780859398),
[job 123141893934](https://github.com/Jagalite/illiquid/actions/runs/40780859398/job/123141893934),
completed **2026-10-29 UTC** on **macOS 26.6.2 (25G83), arm64
VirtualMac2,1 / Apple M1 (Virtual), Xcode 26.6, Apple Swift 6.3.3,
Python 3.15.0**. The job checked out measurement revision
`6867da970f633a9a73611cbcb38e487789c2ac64`, with pinned baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
The only correction following attempt 2 was the runner's **1.5× → 3.0×
calibration safety multiplier**. Production, the six workloads, eight
fresh-process pairs, the 250 ms floor, all performance thresholds, tests,
and timing scope were unchanged. The research branch's later commits
preserve evidence and document the result rather than alter the
qualified production/test/harness/workflow revision.

**Native qualification passed**: `app/tests.json` reports **34/34 focused
full-application-graph tests passing**; `component/tests.json` reports
**24/24 tests passing for each baseline/candidate × debug/release combination
(96 component test executions)**. Independently compared complete
baseline/candidate debug/release traversal receipts match exactly **before
and after** timing; their canonical SHA-256 is
`15401450158498c17f0ac676329cc8263ac032ec781c007a2835e1bc28784a5d`.
Production source and staged-file hashes match; the four distinct binary
build hashes are recorded. Both executable/source integrity and all
measured-pair output/checksum checks pass.
`component/completion.json` has `nativeQualificationSuccess=true`,
`exactReceiptParity=true`, and `sourceAndBinaryIntegrity=true`.

Independent recalculation from **all 96 measured native samples** confirms
that the three file-heavy cases meet **≥15% median paired wall and CPU
savings**, each with **8/8 favorable pairs** for both metrics. The controls
avoid the predeclared **>5% median paired regressions**. All samples were
retained, and the minimum measured elapsed duration was **556.077625 ms**
(above the mandatory 250 ms floor). The percentage figures below are the
**median of the eight paired percentage changes**, not a ratio of the
separately measured per-traversal medians.

| Workload | Wall baseline → candidate (ms/scan) | Paired wall reduction | CPU baseline → candidate (ms/scan) | Paired CPU reduction | Favorable wall / CPU pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `flat_media_4096` | 90.144 → 39.245 | 53.89% | 89.947 → 39.241 | 55.93% | 8/8, 8/8 |
| `flat_nonmedia_4096` | 94.996 → 39.271 | 59.55% | 94.485 → 39.255 | 58.04% | 8/8, 8/8 |
| `nested_mixed_4096` | 87.938 → 40.429 | 55.61% | 87.918 → 40.172 | 55.72% | 8/8, 8/8 |
| `directory_only_512` | 19.311 → 19.418 | −0.17% | 19.309 → 19.409 | −0.14% | 4/8, 4/8 |
| `cached_repair` | 1.383 → 1.357 | −1.98% | 1.382 → 1.357 | −1.92% | 2/8, 2/8 |
| `small_32` | 0.670 → 0.326 | 49.70% | 0.669 → 0.326 | 49.70% | 8/8, 8/8 |

A negative reduction is a regression: the directory-only and cached-repair
control median regressions remain below 5%. The control cases do **not**
require 7/8 favorable pairs.

[Permanent compressed native attempt-3 receipts](evidence/macos/attempt-3-qualified.json)
contain the app log, component manifests/tests/build hashes/commands,
calibration, all 96 raw observations, the summary, and complete four-way
pre/post verification results. The gzip is SHA-256-marked
`12ead7bdad11e1afd0d5edbe3dab849938317d5e3e44c283e1600ab90d008c27`,
verified independently against the
[original CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40780859398/artifacts/12870462338).
Decode the JSON's `gzipBase64` as base64 then gunzip; check
`gzipSha256` first. Unqualified attempts 1 and 2 remain preserved separately
without sample selection or cohort pooling.

**Scope and limitations:** This result measures a warm local real-filesystem
`SourceMediaPresenceCursor` traversal, including cursor bookkeeping, result
accumulation, and temporary-object cleanup under native Foundation. It is
**not** a measured whole-player CPU benefit, UI responsiveness/latency,
cold or network I/O, media decoding, or energy improvement.

## Current-source correctness integration

Pull requests use `--regression-only`. This runs every debug/release test in
both arms and all independent filesystem oracle workloads before reporting
parity, then checks binary/source integrity and exits without timing. Test
skipping and workload subsets are rejected. Completion explicitly reports
`nativeQualificationSuccess=false`; this does not requalify historical timings.

The scanner baseline remains `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Only `MediaFileSupport.swift` is shared from reviewed PR head
`a13019a18e9a05a164b7f724863c98fabfd63ae6` in both arms, checked against the
SHA-256 pin in `REGRESSION_SUPPORT`. Its bounded lowercase ASCII extension
fast path preserves the POSIX lowercase fallback. All other dependencies and
the extracted identity declaration retain the historical equality guard.
Receipts retain historical hashes, actual staged hashes and support provenance.
Further support edits require explicit review and pin updates.

Default runs, branch pushes and manual dispatch retain the strict historical
support guard and original timing criteria. They intentionally reject support
drift. Run `python3 Scripts/tests/source-presence-traversal-policy-tests.py`
for noncompiling policy and failure controls. Existing evidence is unchanged.
