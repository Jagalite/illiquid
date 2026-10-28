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

## Results

Qualification is in progress. No performance result is claimed until the
native evidence has been collected and reviewed.
