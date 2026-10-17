# Playlist shuffle restoration qualification

## Scope and result

This independent audit covers the in-memory playlist edit/shuffle subsystem on
`main` at `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. It does not change the
playback pipeline, media-name recognition, external subtitle matching, source
transactions, or any other agent's branch.

`PlaybackCoordinator.setShuffleEnabled(false)` synchronously calls
`PlaylistMutation.restoringOrder` on the main actor. The previous algorithm
recomputed each unique item's normalized path three times across deduplication,
indexing and filtering. For N input entries with U unique identities, that is
N + 2U identity evaluations. The replacement performs N evaluations, preserves
the first occurrence's complete metadata, and consumes a keyed map in saved
order followed by current order. Empty queues and empty saved orders avoid
unneeded indexing. There is no persistent cache or filesystem I/O added.

This is a behavior-preserving performance change, not a claim that the original
shuffle ordering was functionally wrong. General asynchronous Next/Previous,
pending-load queue-edit races and EOF/native playback are **not qualified** by
this work and remain separate investigation items.

## Correctness checks

- Actual four production Swift source files were compiled, without model stubs
  or rewritten platform implementations. Their initial contents were verified
  against GitHub blob hashes before the experiment.
- The independent integer-label oracle exhausts **41,261** combinations of
  current queues (three identities, lengths zero through four) and saved orders
  (those identities plus an absent identity, lengths zero through four).
  Repeated current identities carry different dates and subtitle metadata, so
  comparing full returned items also detects last-wins metadata regressions.
- Eight new Swift Testing tests cover empty inputs, duplicate/missing saved IDs,
  deleted files staying deleted, appended items retaining their relative order,
  canonical Unicode/path aliases, remote query-string identities, idempotence,
  and current-item index preservation after successive queue edits.
- Together with the two existing `PlaylistMutationTests`, **10 tests in 2 suites
  pass** on the original implementation in debug and on the replacement in
  debug and release, using Swift 6.2.1 on x86_64 Linux. Passing the baseline is
  intentional: these tests protect existing semantics while work is reduced.

Run from the repository root:

```sh
bash Scripts/test-playlist-restoration.sh
bash Scripts/test-playlist-restoration.sh -c release
```

The standalone runner copies the exact source/test files into a temporary Swift
package, uses the toolchain's bundled Testing library, and does not modify the
repository's native `Package.swift` or pinned dependencies. The macOS CI workflow
runs both configurations with the repository's existing Xcode runner settings.
Local macOS CI success is not claimed; inspect the PR's checks.

## Optimized timing experiment

Swift 6.2.1, `swiftc -O -swift-version 6`, x86_64 Linux. **120 fresh processes**
produce **360 timed restoration calls**: three sizes, four scenarios, two
implementations, five process repetitions, three timed calls per process.
Within each case the implementation execution order alternates between pairs.
Each process warms the function first; fixture creation, ID creation, reference
output and full-item equality checks are outside the measured interval. The
table reports the median of five per-process medians. Every output was checked
against the original implementation; no timing threshold is a test assertion.

- `unchanged`: every original item remains, in reversed current order.
- `edited`: every fourth current item is removed, and equally many new items
  are appended. Saved IDs still include the removed entries.
- `duplicates`: the current queue and saved IDs are both repeated, with one
  extra nonexistent saved ID. The item count column is the base unique count;
  actual input entries are twice that count in this case.
- `no-base`: the saved order is empty; current entries remain unique.

| Items | Scenario | Baseline median (ms) | Candidate median (ms) | Reduction |
|---:|---|---:|---:|---:|
| 100 | unchanged | 2.247 | 0.817 | 63.7% |
| 100 | edited | 2.006 | 0.737 | 63.3% |
| 100 | duplicates | 2.871 | 1.523 | 46.9% |
| 100 | no-base | 2.069 | 0.707 | 65.8% |
| 1,000 | unchanged | 23.407 | 8.248 | 64.8% |
| 1,000 | edited | 19.860 | 7.550 | 62.0% |
| 1,000 | duplicates | 28.059 | 16.931 | 39.7% |
| 1,000 | no-base | 20.046 | 7.312 | 63.5% |
| 10,000 | unchanged | 233.751 | 88.351 | 62.2% |
| 10,000 | edited | 221.732 | 86.844 | 60.8% |
| 10,000 | duplicates | 310.191 | 158.972 | 48.8% |
| 10,000 | no-base | 213.082 | 76.738 | 64.0% |

These are function-level timings, **not** measured macOS UI latency, visible
frame performance, end-to-end playlist command latency, memory/energy savings,
or decoder speedups. Even the candidate takes tens of milliseconds at 10,000
items on this host; this does not establish that all large-queue interaction is
frame-budget safe. Both algorithms remain O(N + saved IDs) in time. The candidate uses O(U)
auxiliary storage; the original also retains a seen-set that can grow with
missing saved IDs. The empty saved-order fast path is O(N).

Raw observations, compiler/platform metadata and SHA-256 source receipts are in
[`results-linux-swift-6.2.1.json.gz`](results-linux-swift-6.2.1.json.gz).
The retained raw JSON is gzip-compressed for storage; the runner emits plain JSON.
`Baseline.swift` retains the exact original restoration/deduplication methods
under a separate benchmark-only enum. It is never part of a production target.

```sh
python3 Benchmarks/PlaylistRestoration/run.py --output /tmp/playlist-results.json
# Short parity smoke; do not interpret one repetition as a performance result:
python3 Benchmarks/PlaylistRestoration/run.py --sizes 100 --repeats 1 --rounds 1
```

The retained dataset combines three completed batches with identical source
hashes. An earlier exploratory all-in-one run exceeded the local execution
limit; its incomplete observations are excluded. The JSON includes every
observation from the three retained batches, without timing-based exclusions.

## Review and remaining qualification

The production diff changes only `PlaylistMutation.restoringOrder`. Manual
source review checked first-occurrence semantics, no removed-entry resurrection,
deterministic append order, value preservation, no global state, and unchanged
callers. No separate reviewing agent was available or is claimed.

Run the focused checks on macOS before merging and measure the actual shuffle
control with a large queue on target hardware before advertising an app-level
responsiveness improvement. No merge, release, dependency, or playback-policy
change is performed by this PR.
