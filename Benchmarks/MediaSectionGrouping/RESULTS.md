# Media section grouping performance research

2026-10-21. **Initial cohorts complete; confirmatory result pending.**

## Question and scope

Can repeated media-section titles avoid repeated Foundation case folding during a
cached source-browser projection? The candidate adds a dictionary local to
`SourceBrowserFilter.organizeMedia`, reusing the canonical section title for an
identical spelling. It preserves the first encountered spelling and existing
section/member ordering. The dictionary expires after each call, so searches and
visibility changes cannot inherit an earlier projection's title choice.

This measures the actual production component in a standalone Swift package:
complete Filter/Projection and core source files, plus guarded verbatim model and
loader declarations from AppModel/SourcesSidebar. It does not build or measure the
whole player. There are no playback, FPS, UI-layout, energy, allocation, or memory
results. The cache adds transient dictionary entries and string references in
proportion to distinct title spellings; unique-section fixtures expose timing
overhead but do not quantify that memory tradeoff. See [methodology](README.md).

## Revisions and environments

Both initial cohorts compare baseline
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3` with candidate
`cf27b1e73cd2b1ecd5bfd8b9e5bb0fd273b42536`. Only
`SourceBrowserFilter.swift` differs among staged production dependencies. The
runner rejects other production drift and records original, staged, compiled, and
executable hashes: [native baseline](results/macos-initial/baseline-sources.json),
[native candidate](results/macos-initial/candidate-sources.json),
[native binaries](results/macos-initial/binaries.json),
[Linux provenance](results/linux-exploratory/provenance.json).

| Environment | Initial native, primary | Exploratory Linux |
| --- | --- | --- |
| Host | GitHub Actions `macos-26`; Apple M1 (Virtual), arm64; 3 reported CPUs | Intel Xeon Platinum 8573C, x86_64; 9 reported CPUs |
| OS | macOS 26.6.2, build 25G83 | Linux 6.18.55, glibc 2.39 |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`); target `arm64-apple-macosx26.0` | Swift 6.3.2 (`swift-6.3.2-RELEASE`); target `x86_64-unknown-linux-gnu` |
| Python | 3.15.0 | 3.12.14 |
| Build | Release, whole-module optimization; Xcode 26.6 | Release, whole-module optimization |
| Recorded start, UTC | 2026-10-21 20:21:22 study start | 2026-10-21 20:16:22 timing-cohort start |

Exact records: [native environment](results/macos-initial/environment.json),
[Linux environment](results/linux-exploratory/environment.json), and
[Linux timing cohort](results/linux-exploratory/timing-cohort.json). Linux's original
environment file describes the earlier 100-file smoke preparation; the separate
cohort record describes the full matrix. Interrupted diagnostic compilation was
resumed before final release builds. Native production sources/tests have no
portability changes; Linux records Glibc/FoundationXML imports and an explicit
directory hint in one existing sidecar-test fixture. Linux is supporting evidence,
not a substitute for macOS Foundation behavior or native timing.

## Method and correctness

Each cohort covers eight cases at 100, 1,000, and 10,000 files: six alternating
AB/BA pairs per case, with every observation in a fresh process. The 288 final
observations and 48 separate calibration observations are retained. Calibration
chooses a shared iteration count targeting 60 ms for the faster variant, capped
at 65,536 iterations; this is a target, not a guaranteed duration.

The timer surrounds awaited `project(input:)` calls after priming tree/visibility
caches and three warmups. It includes cached-input checks, search, grouping,
section/episode ordering, projection creation, minimal result consumption, and
replacement of the prior result. Synthetic fixtures use actual filename
recognition before timing. Process launch, recognition, filesystem work, output
validation, JSON encoding, and final-result disposal are excluded. Wall time uses
`DispatchTime`; CPU uses the whole-process `CLOCK_PROCESS_CPUTIME_ID` clock.

The four component suites pass **29 tests in total per configuration** on baseline and
candidate in both debug and release, on both platforms
([native receipts](results/macos-initial/tests.json),
[Linux receipts](results/linux-exploratory/tests.json)). All 24 complete projections
match baseline within each platform
([native verification](results/macos-initial/verification.json),
[Linux verification](results/linux-exploratory/verification.json)). Each measured
process also checks its initial, warmed, and final complete output outside timing,
and asserts exactly one tree build and one visibility build.

The UTF-8 guard on cache hits is essential: Swift dictionary keys equate canonical
Unicode spellings, while Foundation folding can depend on their original bytes.
The [new regression suite](../../Tests/IlliquidAppTests/SourceMediaGroupingTests.swift)
covers a three-title Greek example, canonical/case variants, accents, width,
section ranking, member ordering, and successive projections. In a separate Linux
negative control, removing only the byte guard caused four Greek header/member
expectations to fail. Byte-distinct canonical equivalents can therefore miss or
replace a cache slot and fold again; preserving baseline behavior takes priority.

## Reading the tables

Times are **independent medians per projection**, in milliseconds. Paired Δ is the
median of `100 × (candidate / baseline − 1)` for the six matched batches; negative
means faster. It is not the ratio of the two independent medians. For example,
10,000 native movies have lower candidate median wall time but a **+0.65%** paired
change. Faster-pair counts show consistency, not statistical significance. No
final observations were discarded.

`movies`, `seasons`, and `unicode_groups` repeat section titles; `unique_sections`
has one episode per show. `broad_search` retains all episodes; `narrow_search`
retains about 1%. `files_control` and `tree_control` never call media grouping.

## Initial native results

[Primary Actions run 39667766429](https://github.com/Jagalite/illiquid/actions/runs/39667766429)
succeeded. [All observations](results/macos-initial/measurements.jsonl),
[calibration](results/macos-initial/calibration.jsonl), and
[unrounded summary, ranges, and individual paired changes](results/macos-initial/summary.json)
are retained.

| Case | Files | Wall ms, baseline → candidate | Paired wall Δ | Faster pairs | CPU ms, baseline → candidate | Paired CPU Δ | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `movies` | 100 | 3.194 → 1.702 | -33.14% | 6/6 | 1.969 → 1.603 | -18.68% | 5/6 |
| `movies` | 1,000 | 22.416 → 27.998 | +21.68% | 2/6 | 15.937 → 14.332 | -24.89% | 5/6 |
| `movies` | 10,000 | 138.691 → 135.141 | +0.65% | 3/6 | 135.450 → 131.457 | -0.62% | 4/6 |
| `seasons` | 100 | 2.893 → 2.395 | -12.83% | 4/6 | 2.865 → 2.365 | -13.01% | 4/6 |
| `seasons` | 1,000 | 35.679 → 30.718 | -16.50% | 4/6 | 32.085 → 28.920 | -6.37% | 3/6 |
| `seasons` | 10,000 | 496.289 → 471.803 | -11.11% | 5/6 | 476.285 → 462.173 | -10.19% | 5/6 |
| `unicode_groups` | 100 | 7.223 → 6.010 | -32.66% | 4/6 | 5.544 → 4.941 | -17.73% | 4/6 |
| `unicode_groups` | 1,000 | 63.193 → 66.011 | -3.32% | 3/6 | 61.300 → 65.206 | -2.36% | 3/6 |
| `unicode_groups` | 10,000 | 569.943 → 465.775 | -16.11% | 5/6 | 540.538 → 465.553 | -16.20% | 5/6 |
| `unique_sections` | 100 | 4.627 → 4.558 | +1.68% | 3/6 | 4.623 → 4.562 | +1.45% | 3/6 |
| `unique_sections` | 1,000 | 40.957 → 45.873 | +2.41% | 2/6 | 40.934 → 45.902 | +2.37% | 2/6 |
| `unique_sections` | 10,000 | 387.411 → 373.848 | -3.58% | 5/6 | 381.533 → 372.079 | -3.66% | 4/6 |
| `broad_search` | 100 | 1.493 → 1.411 | -7.39% | 5/6 | 1.493 → 1.411 | -7.42% | 5/6 |
| `broad_search` | 1,000 | 15.383 → 15.197 | -1.84% | 4/6 | 15.362 → 15.175 | -1.90% | 4/6 |
| `broad_search` | 10,000 | 226.652 → 216.871 | -6.91% | 4/6 | 226.613 → 216.858 | -6.96% | 4/6 |
| `narrow_search` | 100 | 0.7403 → 0.7249 | +1.48% | 3/6 | 0.7356 → 0.7189 | +3.12% | 2/6 |
| `narrow_search` | 1,000 | 6.263 → 6.434 | +0.00% | 3/6 | 6.263 → 6.433 | +0.41% | 2/6 |
| `narrow_search` | 10,000 | 65.894 → 62.911 | -4.48% | 6/6 | 65.898 → 62.915 | -4.48% | 6/6 |
| `files_control` | 100 | 0.0176 → 0.0197 | +20.22% | 2/6 | 0.0179 → 0.0203 | +20.54% | 2/6 |
| `files_control` | 1,000 | 0.0172 → 0.0181 | +4.15% | 2/6 | 0.0175 → 0.0188 | +5.36% | 2/6 |
| `files_control` | 10,000 | 0.0201 → 0.0238 | +17.86% | 3/6 | 0.0206 → 0.0235 | +12.70% | 3/6 |
| `tree_control` | 100 | 0.0183 → 0.0165 | -3.08% | 4/6 | 0.0170 → 0.0157 | +0.37% | 3/6 |
| `tree_control` | 1,000 | 0.0138 → 0.0136 | -1.03% | 3/6 | 0.0119 → 0.0111 | -0.76% | 3/6 |
| `tree_control` | 10,000 | 0.0167 → 0.0173 | -0.10% | 3/6 | 0.0172 → 0.0179 | -0.93% | 3/6 |

## Exploratory Linux results

[All observations](results/linux-exploratory/measurements.jsonl),
[calibration](results/linux-exploratory/calibration.jsonl), and
[unrounded summary](results/linux-exploratory/summary.json) are retained separately.

| Case | Files | Wall ms, baseline → candidate | Paired wall Δ | Faster pairs | CPU ms, baseline → candidate | Paired CPU Δ | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `movies` | 100 | 1.635 → 1.261 | -36.27% | 5/6 | 1.398 → 0.9958 | -33.19% | 6/6 |
| `movies` | 1,000 | 10.553 → 9.072 | -18.37% | 5/6 | 10.064 → 7.592 | -25.41% | 5/6 |
| `movies` | 10,000 | 114.953 → 121.149 | -0.15% | 3/6 | 109.605 → 115.684 | +0.09% | 3/6 |
| `seasons` | 100 | 2.110 → 1.822 | -24.29% | 4/6 | 1.814 → 1.462 | -25.82% | 5/6 |
| `seasons` | 1,000 | 26.274 → 19.337 | -30.84% | 5/6 | 23.808 → 17.248 | -36.37% | 5/6 |
| `seasons` | 10,000 | 222.727 → 146.718 | -21.48% | 5/6 | 217.219 → 141.684 | -22.61% | 5/6 |
| `unicode_groups` | 100 | 1.953 → 1.446 | -32.62% | 5/6 | 1.715 → 1.275 | -29.48% | 5/6 |
| `unicode_groups` | 1,000 | 15.301 → 12.693 | -19.98% | 5/6 | 15.215 → 12.042 | -23.04% | 6/6 |
| `unicode_groups` | 10,000 | 202.089 → 163.784 | -17.32% | 5/6 | 191.606 → 163.715 | -17.11% | 5/6 |
| `unique_sections` | 100 | 12.605 → 16.887 | +41.09% | 2/6 | 10.750 → 15.706 | +53.41% | 2/6 |
| `unique_sections` | 1,000 | 174.399 → 167.469 | -11.44% | 4/6 | 163.032 → 163.385 | -8.49% | 3/6 |
| `unique_sections` | 10,000 | 865.707 → 780.151 | -3.47% | 4/6 | 853.393 → 774.826 | -2.48% | 4/6 |
| `broad_search` | 100 | 1.623 → 1.249 | -25.77% | 6/6 | 1.520 → 1.190 | -24.50% | 6/6 |
| `broad_search` | 1,000 | 18.045 → 15.587 | -16.95% | 5/6 | 17.944 → 15.496 | -17.14% | 5/6 |
| `broad_search` | 10,000 | 160.294 → 110.269 | -29.92% | 6/6 | 159.362 → 110.239 | -29.32% | 6/6 |
| `narrow_search` | 100 | 1.209 → 1.191 | -2.94% | 3/6 | 1.073 → 1.114 | +10.31% | 2/6 |
| `narrow_search` | 1,000 | 8.047 → 11.691 | +43.36% | 1/6 | 7.969 → 11.734 | +44.47% | 1/6 |
| `narrow_search` | 10,000 | 76.613 → 79.160 | +4.93% | 1/6 | 76.562 → 79.015 | +4.59% | 1/6 |
| `files_control` | 100 | 0.0408 → 0.0429 | -0.54% | 3/6 | 0.0264 → 0.0260 | +3.19% | 2/6 |
| `files_control` | 1,000 | 0.0479 → 0.0473 | +5.13% | 2/6 | 0.0279 → 0.0308 | +11.93% | 2/6 |
| `files_control` | 10,000 | 0.0377 → 0.0402 | +1.44% | 3/6 | 0.0278 → 0.0279 | +5.23% | 2/6 |
| `tree_control` | 100 | 0.0640 → 0.1340 | +64.63% | 2/6 | 0.0348 → 0.0519 | +21.12% | 3/6 |
| `tree_control` | 1,000 | 0.0427 → 0.0367 | -16.26% | 5/6 | 0.0293 → 0.0262 | -13.84% | 5/6 |
| `tree_control` | 10,000 | 0.0354 → 0.0455 | +29.97% | 1/6 | 0.0258 → 0.0272 | +7.00% | 2/6 |

## Interpretation and confirmatory cohort — pending

The initial native cohort suggests benefits in several repeated-section cases:
10,000 seasons and Unicode groups show paired wall changes of −11.11% and −16.11%,
with matching CPU direction and five of six pairs faster. It also contains
material ambiguity. At 1,000 movies, paired wall time increases 21.68% while CPU
decreases 24.89%; unique sections at 100 and 1,000 files show small paired
regressions. Unaffected files controls vary by +4.15% to +20.22% in wall time.
Scheduling or host variation is plausible, but the data cannot establish the
cause of every regression.

Linux repeated-section cases often improve, but its 100-file unique sections
regress 41.09% in paired wall time and 1,000-file narrow search regresses 43.36%.
Its tree controls also vary substantially. These adverse observations remain in
the report; results should not be pooled across runtimes or reduced to one
aggregate speedup. Six short pairs do not justify a claim of universal improvement.

A separate [native confirmation run 39671527994](https://github.com/Jagalite/illiquid/actions/runs/39671527994)
uses **all eight cases at 1,000 files, 12 AB/BA pairs, and a 250 ms target**. This
middle size includes the wall/CPU disagreement and the overhead controls. It was
chosen after inspecting the initial data; the initial full matrix remains part
of the assessment. The workflow-only revision is
`1a981a0cb89b650f19f678448e39eda2a855df16`; production, tests, and measurement driver
are unchanged from the measured candidate.

**Confirmation results and final decision: PENDING.** Add its environment, raw
receipts, paired wall/CPU table, control interpretation, and decision here after
verification. No confirmatory outcome is assumed above.

## Reproduce and inspect

From the measured candidate checkout, with Git history available, use a new
output directory for each invocation. The runner pins the baseline automatically.
For the native environment, select `/Applications/Xcode_26.6.app/Contents/Developer`
as `DEVELOPER_DIR` before running:

```sh
python3 Benchmarks/MediaSectionGrouping/run.py \
  --sizes 100 1000 10000 --pairs 6 --target-ms 60 \
  --output /tmp/media-sections-initial-reproduction

python3 Benchmarks/MediaSectionGrouping/run.py \
  --mode benchmark --sizes 1000 --pairs 12 --target-ms 250 \
  --output /tmp/media-sections-confirmation-reproduction
```

The first command includes all four test configurations; benchmark mode rebuilds
and verifies complete projections before timing. `--swift /path/to/swift` selects
a different toolchain. Exact driver hashes are in the environment records.
[Native provenance](results/macos-initial/provenance.json) records the verified
artifact digest. Compact receipts are committed here; the primary run's
`media-section-grouping-macos` artifact includes full traces, staged sources,
driver snapshots, and command logs, with 14-day retention. Build binaries/cache
are excluded from that artifact; executable hashes are retained.
