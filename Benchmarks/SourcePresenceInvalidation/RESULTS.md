# Source-presence invalidation results

## Decision

Native qualification is pending. The local exploration supports continuing with
targeted ancestor invalidation; it does not establish native effect sizes.

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Candidate and final runner: `56baa65bed70d643ee8a6c11de5a0b3c4c74c858`.
Production scanner SHA256:
`7fce5c90f7268775f6ab834332acd8f23571839acc538599e0df2e6b994453b2`.

Native qualification run:
[40635623857](https://github.com/Jagalite/illiquid/actions/runs/40635623857).

## Why this area

`SourcesSidebar.applyFilesystemEvents` calls the media-presence scanner on the
main actor after classifying filesystem events. For a directory-listing change,
only that directory and its cached ancestors lose their result values. Cached
descendants and unrelated folders remain useful.

The original implementation nevertheless filtered every cached summary and
result. Its result predicate searched the changed-directory set for every cached
folder, multiplying the work for a batch of changes. This is synchronous work
before control returns to the UI; the later asynchronous repair is a separate
cost.

The selected change skips summary filtering when there are no watched subtrees
and finds existing ancestor result keys directly. Literal UTF-8 slash boundaries
identify candidate prefixes; the existing containment predicate and Swift
dictionary equality still decide which keys match. A single observed mutation
removes the collected keys, while a no-op does not open that mutation scope.
Subtree and full-root invalidation retain the original filtering path.

## Exploration

The first candidate only skipped the empty-subtree summary pass. Its two-pair
Linux exploration produced mixed timings, including a slower wall-time result
for the 10,000-folder case. That narrower candidate was not selected. Its source
snapshot, raw observations, and validation receipts remain under
[`evidence/guard-exploration-linux`](evidence/guard-exploration-linux).

The ancestor candidate then passed all 26 component tests in each
baseline/candidate debug/release configuration using Swift 6.3.2 on x86_64 Linux.
Exact state traces also matched in all four builds. The two-pair timing run was
exploratory: some intervals were far shorter than 50 ms, and unchanged controls
varied substantially.

Selected local wall-time medians, in milliseconds per complete synchronous
invalidation call:

| Case | Result ownership | Baseline | Candidate |
| --- | --- | ---: | ---: |
| One changed directory; 32 cached folders | Unique | 0.010961 | 0.004107 |
| One changed directory; 1,000 cached folders | Unique | 0.214590 | 0.005442 |
| One changed directory; 10,000 cached folders | Unique | 2.568544 | 0.008412 |
| One changed directory; 10,000 cached folders | Shared initial snapshot | 2.325691 | 0.061849 |
| 16-call burst; 10,000 cached folders | Unique | 1.933468 | 0.001756 |
| 16-call burst; 10,000 cached folders | Shared initial snapshot | 1.945451 | 0.005471 |

These are independent variant medians, not ratios of paired observations. The
burst revisits four directories; later calls include already-invalidated paths.
All raw samples and control results are retained in
[`evidence/ancestor-exploration-linux`](evidence/ancestor-exploration-linux).
Do not use this table as a macOS latency claim.

## Native results

Pending the native component and full application-graph scanner jobs. The
component plan is ten alternating baseline/candidate process pairs per case
and ownership condition, covering all 16 workloads. It records both process CPU
and monotonic wall time, independent repetition counts, complete output receipts,
and short-sample flags. No timing observations are discarded.

## Correctness and limits

The comparison compiles each complete production scanner with the same
dependencies. Debug and release builds compare complete results, summaries,
original UTF-8 spellings, revisions, pending repairs, roots, task state, and job
counts. There are 366 ordinary complete-state snapshots across the two ownership
conditions. A separate 1,464-input lexical corpus verifies every remaining
result/summary field against the original predicate, including canonical Unicode
equivalence, unusual separators, false values, and repeated no-op events.

Five new filesystem regression tests cover changed and unchanged Observation
notifications, retained snapshots, ignored event payloads, directory-only repair,
subtree/full-root repair, and release of completely emptied dictionary storage.
The baseline must pass those same tests, so these are compatibility checks.

The benchmark times the complete synchronous `invalidate` method: classification,
revision changes, cache changes, repair queuing, and task scheduling. Fixture
restoration, checksums, task draining, filesystem traversal, and SwiftUI rendering
are outside the interval. A queued-burst worker has not begun traversing the
filesystem. Timed cases have no live Observation subscriber; notification
behavior is verified separately.

Shared cases retain only the initial result snapshot. After its first
copy-on-write, a burst generally mutates uniquely owned replacement storage.
This does not model a new retained snapshot after every intermediate event.
Shared first mutation can still copy O(n) dictionary storage, and partially
invalidated tables can retain capacity for later repair. Complete clearing
releases table storage. No resident-memory reduction is claimed.

Fixed-seed, warm-cache fixtures establish a component cost difference, not the
prevalence of these cache sizes in real libraries. Iteration/restoration caps
leave some candidate and control samples short, with clock overhead retained.
Small control differences require caution. The study does not measure
end-to-end event latency, live UI interaction, playback smoothness, frame rate,
whole-player CPU, or energy use.

See the [method and reproduction instructions](README.md) and
[evidence retention notes](evidence/README.md).
