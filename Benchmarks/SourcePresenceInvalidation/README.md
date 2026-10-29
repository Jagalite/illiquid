# Source-presence invalidation study

Directory-listing changes call `SourceMediaPresenceScanner.invalidate` on the
main actor. The original implementation searches every cached summary and
every cached result, even when there is no watched subtree to invalidate.
Only the changed directory and its ancestors lose their result values in that
case; cached descendants and unrelated folders remain reusable.

The candidate skips the redundant summary pass and finds existing ancestor
result keys from the changed paths. It uses literal UTF-8 slash boundaries,
the original containment predicate, and Swift dictionary equality. It does
not standardize input paths or substitute byte equality for Unicode equality.
It collects keys before one observed mutation, so events that remove no result
retain the existing no-notification behavior. Subtree and full-root events
continue to use the original filtering path. Empty result/summary tables are
released; partial result tables may retain capacity for subsequent repairs.

## Reproduce

Use Swift 6.1 or newer and Python 3.10 or newer. The native workflow uses the
repository's macOS 26 / Xcode 26.6 configuration. No native media SDK is needed
for the isolated component package. The separate native job builds the actual
application dependency graph and exercises scanner filesystem integration.

```sh
python3 Benchmarks/SourcePresenceInvalidation/run.py \
  --output /tmp/source-presence-invalidation --pairs 10 --target-ms 100

python3 Benchmarks/SourcePresenceInvalidation/run.py \
  --output /tmp/source-presence-invalidation-tests --tests-only
```

Use a fresh output directory for each run. Submit the complete command through
the repository's Kyoto queue when it is available. Builds inside the runner
are serial and use isolated packages and caches. `--swift` or `SWIFT` selects a
toolchain. Linux uses its real Foundation and Observation implementations;
Linux results are separate from macOS qualification. The integrated SwiftPM
driver is used on Linux for compatibility with container process inspection.

## Comparison and correctness

The frozen baseline is the complete production scanner from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its Git blob and SHA256, unchanged
supporting source hashes, and the exact shared identity declaration are pinned
in `baseline/manifest.json`. The runner rejects changes to those dependencies
until the comparison is deliberately requalified.

Each variant compiles the complete scanner. `Support.swift` is appended as a
test-only same-file extension to set up private state and inspect it; no
production method, property, scheduling operation, or Observation macro is
replaced. The benchmark driver imports the resulting module separately.

Before timing, debug and release builds run the repository's recomputation,
snapshot reuse, and invalidation tests. Differential traces compare all result
and summary values, original key spellings, pending repairs, revisions, roots,
completed roots, job counts, task presence, and scanning state. Cases include
false results, unavailable summaries, changed directories, queued-scan bursts,
removed subtrees, full roots, ignored events, queue collapse, `/`, prefix
siblings, and Unicode paths. New filesystem tests verify retained snapshots,
repair completion, and changed versus unchanged Observation notifications.

An additional 1,464-input lexical corpus invokes the actual scanner with
Unicode, repeated separators, raw relative segments, and canonically equivalent
stored keys. It checks every surviving result/summary field and raw key/child
spelling against the original filter predicate, plus first-change and repeated
no-op notification counts. This oracle is confined to verification code.

## Timing boundary and ownership

The timed interval is the **complete synchronous `invalidate` call**, including
directory/subtree classification, revision updates, summary and result changes,
repair queuing, and scheduling. A burst is multiple complete calls. Time is
reported per call, with operation counts retained so sequence totals can also
be reproduced.

Fixture generation, restoration, warmup, final-state snapshots, checksums, and
task cancellation/draining are outside timing. The main actor does not yield
inside a timed sequence. Afterward, the actual queued task is canceled before
yielding and awaited; an assertion verifies it never started a scan. Thus
filesystem traversal is excluded without replacing the scanner's worker.

Two explicitly labeled ownership conditions are tested:

- **Unique:** both dictionary tables belong only to the scanner when timing
  starts; the fixture template uses independently constructed tables.
- **Shared:** another owner retains the initial result dictionary, as a
  projection or cursor can do. Private summaries and revision maps remain
  unique. The first result mutation may still copy O(n) dictionary storage.
  Later calls in a burst generally own the replacement table uniquely; this
  does not model a new UI snapshot retained after every intermediate change.

The workloads span 32, 1,000, 10,000, and 100,000 cached folders, individual
events, batched changes, bursts, Unicode, and subtree/full-root/no-op controls.
They are synthetic warm-cache component workloads, not measurements of the
prevalence or size of real user libraries. No live Observation subscriber is
installed in timed cases; notification semantics are checked separately.
The 16-call bursts revisit four directories, so later calls include already
invalidated paths. Their per-call averages should not be mistaken for first-event
latency. The queued-burst worker has not begun traversal; no I/O contention is
measured. Fixed fixture seed 41 and deterministic hashing keep paired inputs
reproducible rather than sampling a population of library shapes.

Every timed observation runs in a fresh process. Baseline-first and
candidate-first pairs alternate, and workload order rotates between rounds.
Both variants restore the same fixture and execute the same complete event
sequence per iteration. Iteration counts are calibrated independently and
reported explicitly; times and paired ratios are normalized per invalidation.
This avoids repeating a much slower baseline for minutes to obtain a useful
candidate interval. Every sample's checksum must equal its verified single-cycle
checksum multiplied by its iteration count, with identical final-state receipts.
Process CPU and monotonic wall time are retained, including clock-read overhead;
no overhead is subtracted and no samples are discarded. Calibration targets the requested
duration but caps restoration work at 1,000 iterations and five million input
entries per dictionary per sample (excluding warmup). The 100,000-folder case
therefore caps at 50 iterations. `--maximum-iterations` and
`--maximum-restored-entries` adjust those limits. Requested/capped counts and
actual short samples are explicitly recorded; short controls require caution.

## Evidence and scope

The runner retains the exact compiled sources, toolchain/platform details,
source and executable hashes, command receipts, debug/release test logs,
complete differential traces, calibration observations, every raw timing
sample, paired summaries, and a completion receipt. Summaries show independent
variant medians and median paired reductions, which need not be the same ratio.
The workflow also publishes the full artifacts and a compact log bundle.

These measurements address main-actor invalidation work. They do not establish
end-to-end filesystem-event latency, SwiftUI render time, whole-player CPU or
memory use, frame rate, playback smoothness, or energy savings. Partial table
capacity reuse and copy-on-write behavior are implementation tradeoffs, not a
claim of lower resident memory.

Native results and the research decision will be recorded after qualification.
