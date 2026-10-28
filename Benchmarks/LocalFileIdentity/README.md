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
both clock reads using `withExtendedLifetime`. Deduplication verifies complete
first-item metadata and order.

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
