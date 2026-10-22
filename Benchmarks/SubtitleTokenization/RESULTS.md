# Subtitle filename tokenization: native performance results

## Decision

Adopt the contiguous-ASCII fast path in `ExternalSubtitleMatcher.filenameTokens`.
The final native qualification reduced median process CPU per complete association
by **38.34% for 16-file ASCII inventories** and **43.02% for 256-file ASCII
inventories**, with the candidate faster in all **12/12** pairs for both cases.
The Unicode and empty-input controls remained near parity, and all correctness
checks passed. This meets the acceptance criteria recorded before measurement.

These results concern subtitle association over prepared inventories. They do
not establish playback, battery, filesystem-I/O, or full folder-opening gains.

## Why this area

[FolderPlaylistDiscovery.makePlaylist](../../Sources/IlliquidCore/Playlist/FolderPlaylistDiscovery.swift)
calls the matcher for a folder's media and subtitle inventories. The existing
matcher already uses a token trie to narrow candidates. Filename preparation
still lowercases, folds diacritics and width, and splits with Foundation for
each supported filename, including names made entirely of ASCII characters.

The production change adds 32 lines and removes two. It first asks Swift for
contiguous UTF-8 storage, verifies that every byte is ASCII, then lowercases
`A...Z` and splits on bytes outside ASCII letters and digits. Returned tokens
own their storage. Non-ASCII content or unavailable contiguous storage uses the
original Foundation expression. Filename extraction, scoring, trie traversal,
ambiguity handling, cancellation checks, and natural subtitle ordering are
unchanged. There is no new cache or shared mutable state.

## Measured source and environment

- Baseline: [`a2de305c8dbcaa81aac1477df7c9a0017c14eae3`](https://github.com/Jagalite/illiquid/commit/a2de305c8dbcaa81aac1477df7c9a0017c14eae3). The three frozen source files and their Git blob identities are in [`baseline/`](baseline/).
- Accepted candidate: [`ab0d08f19b63d705bb8b74faebb389923bf06dfa`](https://github.com/Jagalite/illiquid/commit/ab0d08f19b63d705bb8b74faebb389923bf06dfa). Later report/workflow cleanup does not change measured production, test, or harness sources.
- Candidate matcher SHA-256: `32baa1287ed03126aedee7c57fadd72aaf44fccc196b76e544de48fcb4e884a8`.
- Host: GitHub Actions macOS 26 runner, Apple M1 (Virtual), macOS 26.6.2 build 25G83, Xcode 26.6 selection, Apple Swift 6.3.3, `arm64-apple-macosx26.0`, locale `en_US`.

The baseline and candidate are separate optimized dynamic libraries linked to
the same Swift driver with `-swift-version 6 -O -whole-module-optimization`.
Each sample runs in a fresh process. Twelve balanced AB/BA pairs per case use
identical iteration counts calibrated from baseline CPU toward a 500 ms batch.
Actual durations and calibration pilots are retained; the target is not a
guaranteed batch duration. Runs are serial within each qualification job.

The timer includes the complete `associate` call, result key/subtitle-count
consumption, and result destruction. Fixture creation, full correctness
verification, four warmup calls, and JSON serialization are outside it. No
control overhead is subtracted. Full output equality is verified separately
from the timed count checksums.

## Accepted candidate: complete results

Results below are **milliseconds of process CPU per complete association**.
CPU change is `100 × (candidate median / baseline median − 1)`; negative
values mean less CPU. The raw evidence also contains wall-clock timings and
the median, minimum, and maximum of the within-pair ratios.

| Workload | Baseline CPU ms | Candidate CPU ms | CPU change | Faster pairs |
|---|---:|---:|---:|---:|
| ASCII, 1 media file | 0.0243 | 0.0144 | -40.55% | 12/12 |
| ASCII, 16 media files | 0.3414 | 0.2105 | -38.34% | 12/12 |
| ASCII, 256 media files | 5.5445 | 3.1591 | -43.02% | 12/12 |
| ASCII, 4,096 media files | 97.9239 | 59.3711 | -39.37% | 12/12 |
| Three subtitle languages, 16 media | 0.6907 | 0.4634 | -32.92% | 12/12 |
| Three subtitle languages, 256 media | 10.2166 | 6.7634 | -33.80% | 12/12 |
| Long ASCII names, 256 media | 30.8262 | 20.8141 | -32.48% | 12/12 |
| Unrelated subtitles, 256 media | 17.0991 | 9.4165 | -44.93% | 12/12 |
| Ambiguous subtitle, 256 media | 9.0690 | 5.5637 | -38.65% | 12/12 |
| Empty subtitle inventory, 256 media | 0.3158 | 0.3174 | +0.49% | 5/12 |
| Unsupported subtitles, 256 media | 9.2852 | 5.4024 | -41.82% | 12/12 |
| Unicode, 16 media files | 0.6912 | 0.6965 | +0.77% | 6/12 |
| Unicode, 256 media files | 8.0901 | 8.1049 | +0.18% | 8/12 |
| Late Unicode in long names, 256 media | 14.4646 | 13.9507 | -3.55% | 6/12 |
| Mixed ASCII/Unicode, 256 media | 5.6145 | 4.9881 | -11.16% | 8/12 |

The required ASCII comparisons exceed the 10% reduction threshold. Scaling the
original five-of-six direction requirement to twelve pairs requires at least
ten faster pairs; both required cases were faster in all twelve. All four controls
have median regressions below 1%. Their median paired candidate/baseline
ratios are 1.0391 (empty), 1.0222 (Unicode 16), 0.9689 (Unicode 256), and
1.0108 (late Unicode), also within 5%.

Individual control samples remain noisy: Unicode-256 paired ratios range
from 0.703 to 1.575. Treat these controls as near parity in this cohort;
the measurements do not establish exactly zero fallback overhead or a
Unicode speedup. The mixed-name improvement is a secondary result with
8/12 faster pairs, less consistent than the all-ASCII cases.

## Correctness

The final run passed **30 tests in three suites** in each of baseline debug,
baseline release, candidate debug, and candidate release: four configurations,
not 120 distinct tests. The five new tests cover all 128 ASCII scalars against
the original Foundation normalization oracle, delimiter boundaries, long
tokens, Unicode case/diacritic/width behavior, and ambiguous or unique
associations. NUL and slash are excluded only from the filesystem-delimiter
association fixture; the normalization-oracle test still covers both URL cases.

The existing suites retain coverage of exact and prefix matching, release and
language qualifiers, duplicate inputs, ordering, and cancellation at each
observed checkpoint. Separately, all **23 complete URL-to-ordered-subtitle
association records** match the independent fixture expectations and each
other across baseline and candidate. Their parity hash is
`a2dcadf230f9a889fb53d44230e898c2d4cbe7bb8f3ec15a0115a7e81ea6f1d5`.
All 360 final timing records passed their count/checksum checks.

This is an isolated component qualification. It does not replace a full
application build or an interactive playback test.

## Initial signal, confirmation, and refinement

The initial implementation scanned a generic UTF-8 view before selecting the
ASCII path. Its six-pair run improved the required ASCII cases by 40.02% and
32.41%, but showed apparent regressions in two Unicode controls. Those samples
were retained and triggered a longer, twelve-pair confirmation with **unchanged
production code**. The confirmation again improved ASCII-256 by 38.90% in
12/12 pairs, while the Unicode slowdowns did not reproduce.

| Control | Initial, 6 pairs | Same code confirmation, 12 pairs | Refined, 12 pairs |
|---|---:|---:|---:|
| Empty subtitle inventory, 256 media | -2.18% | +2.12% | +0.49% |
| Unicode, 16 media files | +2.26% | -0.65% | +0.77% |
| Unicode, 256 media files | +6.24% | -1.47% | +0.18% |
| Late Unicode in long names, 256 media | +12.73% | -1.10% | -3.55% |

While that confirmation waited for a runner, the final variant was prepared
to use only available contiguous storage. This avoids a preliminary generic
UTF-8 traversal when storage is unavailable. The full final qualification
above validates that variant independently. The initial regression was **not
confirmed**, so the data do not establish that the storage refinement caused
the difference between the control results.

Absolute baseline costs differed substantially across runs: ASCII-256 was
7.9346 ms initially, 4.9779 ms in the focused confirmation, and 5.5445 ms in
the final qualification. Compare variants within a cohort. Do not combine
those absolute numbers into a before/after comparison of the two candidates.
No samples were dropped from any cohort.

## Durable evidence and exact reproduction

| Cohort | Revision | Native run | Measurements | Correctness suites | Evidence directory |
|---|---|---|---:|---|---|
| Initial | `290c96d99edde9bba2339003d19fdc522c75fd8a` | [39666930147](https://github.com/Jagalite/illiquid/actions/runs/39666930147) | 15 × 6 × 2 = 180 | All four configurations | [initial](results/initial/) |
| Focused confirmation | `5b6caf43d764900ce55e800bd061da117a46c23a` | [39667855647](https://github.com/Jagalite/illiquid/actions/runs/39667855647) | 5 × 12 × 2 = 120 | None; benchmark-only mode | [confirmation](results/confirmation/) |
| Accepted refinement | `ab0d08f19b63d705bb8b74faebb389923bf06dfa` | [39669433630](https://github.com/Jagalite/illiquid/actions/runs/39669433630) | 15 × 12 × 2 = 360 | All four configurations | [refined](results/refined/) |

Each directory commits the manifest, raw measurements, summary, parity/result
receipts, and `evidence.zip`. The ZIP preserves the full runner output:
source/test/driver snapshots, calibration, command receipts, build and test
logs, full association records, and binary hash receipts. Compiled executables
and libraries themselves are not archived. This evidence remains available
after the Actions artifact retention period expires.

| Committed evidence ZIP | SHA-256 |
|---|---|
| [initial/evidence.zip](results/initial/evidence.zip) | `2156245d8de08f10dd526046260fe8a6fb2fbfcd483ae259f788b83c8009ecc0` |
| [confirmation/evidence.zip](results/confirmation/evidence.zip) | `81f9effec915d68379ea233c6a71c0cb9e338ef4279de3f5f60e507d2a786938` |
| [refined/evidence.zip](results/refined/evidence.zip) | `489f7ed76c84b44094fd1fd42dfd43675fc8956aeb4a2ed76003a1142212494e` |

To reproduce the accepted cohort from a checkout, use the recorded toolchain
and an empty output directory. Ensure `swift` and `swiftc` on `PATH` resolve
to that Xcode toolchain:

```sh
git checkout ab0d08f19b63d705bb8b74faebb389923bf06dfa
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 \
  DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
  python3 Benchmarks/SubtitleTokenization/run.py \
  --output /tmp/illiquid-subtitle-tokenization-refined \
  --mode all --pairs 12 --target-ms 500
```

The initial cohort used `--mode all --pairs 6 --target-ms 150` at its recorded
revision. The focused confirmation used:

```sh
git checkout 5b6caf43d764900ce55e800bd061da117a46c23a
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 \
  DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
  python3 Benchmarks/SubtitleTokenization/run.py \
  --output /tmp/illiquid-subtitle-tokenization-confirmation \
  --mode benchmark --pairs 12 --target-ms 500 \
  --case ascii_256 --case empty_256 --case unicode_16 \
  --case unicode_256 --case late_unicode_256
```

Full association verification still runs for all 23 records when cases are
selected. The permanent workflow retains path-filtered PR and manual triggers
and runs the full twelve-pair qualification; temporary research push triggers
are removed. Timing deltas are reported evidence, not CI pass/fail thresholds.
