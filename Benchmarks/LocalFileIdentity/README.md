# Local file identity call-site qualification

## Relationship to the optimization

This companion study is stacked on [PR #144](https://github.com/Jagalite/illiquid/pull/144),
at commit `630530f27be150823d4dd4737b15cec947bfd8c9`. It makes no production
changes. Both measured variants use the same complete supporting source files;
the baseline uses the original `NormalizedFileURL` from main at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, and the candidate uses #144's exact
implementation.

The distinct focus is `PlaylistMutation.indexPreservingCurrentIdentity` across
first/middle/last/missing targets, duplicate-heavy playlist imports, and systematic
byte/NSURL compatibility. The parent study exercises `FolderPlaylist.index(of:)`
and a lower-duplicate import. Shared key workloads serve as independent replication,
not a comparison or ranking of alternative optimization PRs.

## Optimization under test

`NormalizedFileURL.persistenceKey(for:)` previously called `normalize(url)?.path`.
After validating and lexically standardizing a local URL, that constructs another
file URL only to read its path. Playlist item IDs, selection lookup, deduplication
and persistence call this helper.

The candidate returns the standardized path directly for non-NUL ASCII paths. It retains the original local-authority validation and the exact
file-URL constructor for Unicode, NUL, repeated separators,
trailing separators, and Darwin file-reference-shaped paths. Root `/` remains
supported. The `normalize` and filesystem-resolution APIs are unchanged.

The conservative fallback matters because Foundation's file-path conversion
has platform-specific byte behavior. Swift String equality can hide differences
between canonically equivalent Unicode spellings; the new regression tests
compare optional UTF-8 arrays against the unchanged `normalize(url)?.path` oracle.

## Qualified portable result

The [successful Linux run](https://github.com/Jagalite/illiquid/actions/runs/40640423378)
tested commit `5715179b655f35c2b97f6816ab3ef122ad20873f` on a GitHub Ubuntu 24.04
x86_64 runner with Swift 6.3.2. The recorded CPU model is AMD EPYC 9V45.
Production code is exactly the parent PR's version. Later report/evidence changes
do not alter the measured production, harness or tests.

All **47 tests in seven suites passed for both variants in debug and release**:
four configurations and 188 test executions, including parameterized/generated
fixtures. The driver also verified complete semantic receipts for every workload
before measuring.

The run retained **400 observations across 20 workloads and ten balanced pairs**.
The shortest retained timed loop was 141.25 ms. Every ASCII target workload
improved in all ten pairs. ASCII selection-preservation operations were
40.18–41.69% lower in wall time by median paired reduction; deduplication took
38.97–39.09% less time under these fixtures.

The table includes every workload. Percentage reductions are the median of the
ten `100 × (1 − candidate / baseline)` paired observations; they are not computed
from the two displayed marginal medians. Negative values mean slower.

| Workload | Baseline median | Candidate median | Median paired time reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| Key: short ASCII | 3.251 µs | 1.951 µs | 40.09% | 10/10 |
| Key: long ASCII | 23.595 µs | 11.873 µs | 49.89% | 10/10 |
| Key: escaped ASCII | 4.970 µs | 2.832 µs | 43.83% | 10/10 |
| Key: dot-segment/localhost alias | 3.745 µs | 2.424 µs | 35.28% | 10/10 |
| Key: relative reference | 5.157 µs | 3.803 µs | 25.85% | 10/10 |
| Key: composed Unicode (NFC) | 3.870 µs | 3.919 µs | -2.03% | 2/10 |
| Key: decomposed Unicode (NFD) | 3.942 µs | 3.748 µs | 2.64% | 5/10 |
| Rejected HTTPS | 60.10 ns | 60.40 ns | -0.43% | 4/10 |
| Rejected remote-file authority | 397.35 ns | 399.23 ns | -0.63% | 3/10 |
| Same-file comparison: ASCII | 6.608 µs | 3.987 µs | 40.06% | 10/10 |
| Same-file comparison: Unicode | 8.034 µs | 8.011 µs | -1.25% | 3/10 |
| Selection: 32 items, last hit | 107.967 µs | 64.645 µs | 40.18% | 10/10 |
| Selection: 1,000 items, first hit | 6.458 µs | 3.856 µs | 40.90% | 10/10 |
| Selection: 1,000 items, middle hit | 1.663 ms | 969.441 µs | 41.66% | 10/10 |
| Selection: 1,000 items, last hit | 3.308 ms | 1.957 ms | 40.60% | 10/10 |
| Selection: 1,000 items, missing target | 3.285 ms | 1.930 ms | 41.20% | 10/10 |
| Selection: 10,000 items, last hit | 33.471 ms | 19.310 ms | 41.69% | 10/10 |
| Selection: 1,000 Unicode items, last hit | 3.411 ms | 3.439 ms | -0.80% | 4/10 |
| Deduplicate: 1,000 unique inputs | 3.425 ms | 2.097 ms | 39.09% | 10/10 |
| Deduplicate: 4,000 inputs, 1,000 identities | 13.357 ms | 8.159 ms | 38.97% | 10/10 |

### Controls, limits and native gate

The composed-Unicode key control was **2.03% slower by median paired reduction**
(eight of ten pairs slower). Its difference of marginal medians is about 49 ns/key.
Unicode comparison and Unicode playlist selection also had small negative paired
medians. The decomposed-Unicode and rejected-source cases varied across pairs;
they do not establish fallback gains. Some control pairs contain substantial
host noise; the unfiltered ranges and every observation are retained.

These are warmed component wall-time measurements on one Linux runner. The study
does not establish macOS performance, allocator totals, startup time, UI latency,
frame rate, energy use or a whole-player gain. The parent PR has its own native
evidence; [this broader native qualification](https://github.com/Jagalite/illiquid/actions/runs/40640423501)
was still queued when this report was prepared. Keep the companion PR in draft
until the native byte tests and workload matrix complete.

All 20 summaries were recomputed from raw measurement rows, all pair/checksum
receipts were checked, and 19 source/qualification hash entries were matched
against exact committed files. See the [retained evidence](evidence/linux-x86_64-20261028/)
and its [audit](evidence/linux-x86_64-20261028/audit.json).

## Reproduce

Use a checkout containing baseline commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Python 3, and Swift 6.1 or newer.
On macOS, select the same Xcode with `DEVELOPER_DIR`. The native workflow uses
macOS 26 and Xcode 26.6. No external Swift packages or native media SDK are needed.

Run builds through Kyoto when its shared queue is available, as required by
`AGENTS.md`. Submit the entire runner, then inspect its job, logs and completion:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/LocalFileIdentity/run.py \
  --pairs 10 --target-ms 150 --output /tmp/illiquid-file-identity
```

When Kyoto is unavailable, state that limitation and run the same Python
benchmark command directly. The hosted workflow checks this explicitly. Builds
within one invocation are serialized and use isolated build directories.
Use a new or empty output directory for every run.

`--mode tests` runs only correctness checks, `--mode benchmark` runs only
measurements, and the default `--mode all` runs both. `--swift` and `--swiftc`
select an explicit toolchain. The pair count must be even.

## Correctness and build isolation

The runner copies five complete, unmodified production source files into
separate baseline and candidate snapshots: `NormalizedFileURL`,
`NaturalFilenameOrdering`, `MediaSource`, `FolderPlaylist`, and `PlaylistMutation`.
Baseline files come from the pinned Git commit; candidate files come from the
checkout. It rejects any production-source difference other than the intended
`NormalizedFileURL.swift` change.

Both variants run the same seven test files in debug and release, including the
parent PR's augmented local-source tests. The runner requires a positive Swift
Testing receipt with matching test counts across all four configurations. These cover
byte-level file identity, local-source authorization, playlist lookup and
selection, restoration ordering, and existing folder-playlist behavior. The
new tests include path and URL constructors, relative bases, bridged NSURLs,
escaped characters, Unicode, unsupported authorities, and special path forms.

Timing builds use `-O -whole-module-optimization -swift-version 6` and warnings
as errors. The production sources form a separate dynamic `IlliquidCore` library;
the identical driver is compiled afterward without cross-module optimization.
This prevents the driver from folding invariant calls into one precomputed result.
The runner records the exact sources, flags, compiler, host and binary hashes.

## Workloads

| Group | Cases |
| --- | --- |
| Individual keys | Short/long ASCII, escaped filenames, dot-segment aliases, relative bases, composed/decomposed Unicode, rejected HTTPS and remote-file authorities |
| Resource comparison | Matching and nonmatching ASCII and Unicode pairs |
| Playlist selection | 32-item last hit; 1,000-item first/middle/last/miss; 10,000-item last hit; 1,000-item Unicode last hit |
| Deduplication | 1,000 unique items; the same 1,000 items repeated four times (75% duplicates) |

Each direct-key or comparison case cycles through 64 prepared inputs. Playlist
selection uses 64 preconstructed target aliases at the specified hit position.
The missing-target case verifies the existing fallback to index zero. Playlist
construction, sorting, expected-result calculation and warm-up happen before
the clock starts. The prepared closures and their input arrays remain alive through
both clock reads using `withExtendedLifetime`. The benchmark verifies complete
deduplicated output contents and order. The existing empty-base order-restoration
test separately verifies first-occurrence metadata through the deduplication path.

Both variants are calibrated toward a 150 ms timed loop; the larger resulting
iteration count is shared by both variants and all retained pairs. Every
calibration trial is retained separately from measurements. Each measured
observation uses a fresh process. Baseline-first and candidate-first order
alternates, and workload order reverses on alternating pairs. No observations
are discarded based on timing.

Every measured call contributes to a verified deterministic checksum. Before
measurements, complete semantic receipts must match between variants. These
receipts and the regression tests provide byte-level checks; the timed checksum
is intentionally cheaper and is not the sole correctness oracle.

`summary.json` reports per-workload medians, ranges, median paired reductions,
and how many pairs favor the candidate. There is no timing threshold in CI.
Interpret controls and absolute times alongside percentage reductions.

## Evidence

The output retains `manifest.json`, `summary.json`, `workloads.json`,
`calibration.json`, `semantics.json`, every raw calibration and measurement
in `observations.jsonl`, command receipts, complete logs, and source snapshots.
Failure leaves completed evidence available and marks the summary failed.
The workflow uploads the evidence even when a phase fails.

These are warmed, component-level wall-time measurements. They do not establish
application startup latency, UI responsiveness, decoding throughput, frame rate,
energy savings, or a player-wide speedup. Full application and live playback
qualification remain separate from this isolated Foundation/playlist experiment.


## Preliminary work and retained limits

Two earlier Linux runs ([first](https://github.com/Jagalite/illiquid/actions/runs/40639069775),
[reordered guard](https://github.com/Jagalite/illiquid/actions/runs/40639627605))
tested an independently developed, overlapping implementation. Their correctness
checks passed. Their timing results are exploratory: the driver did not explicitly
keep fixture captures alive through the final clock read, so fixture destruction
could contaminate timing. They do not qualify #144, are not pooled with this
study, and are excluded from final performance claims.

The follow-up cohort uses the exact parent implementation, the explicit lifetime
guard, ten balanced pairs and a 150 ms calibration target. Linux and native macOS
results must be reported separately. A portable component result is not evidence
of a macOS or whole-player speedup.
