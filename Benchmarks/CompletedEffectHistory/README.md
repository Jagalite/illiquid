# Completed-effect history memory research

This experiment measures the playback state machine's completed-effect history.
It does not measure decoded frames, renderer resources, the process resident set,
or whole-player playback performance.

## Problem and change

The production core remembers every completed effect ID so that late repeated
callbacks remain duplicates. Previously, `PlaybackCoreState.completedEffectIDs`
retained a hash-set entry for every completion for the application's lifetime.
Disabling replay recording does not disable this history.

The candidate stores a **verified consecutive prefix starting at ID 1** in a
counter and keeps every other completed ID in a normal Set. For example,
completions `1, 2, 4` produce prefix `2` and sparse set `{4}`. Completing `3`
advances the prefix to `4` and releases the sparse entry. No completion is inferred
from the allocator, and no old ID expires. ID zero and arbitrary legacy IDs keep
their exact Set semantics.

A property wrapper preserves the public `Set<PlaybackEffectID>` property and
initializer, its value-copy and `inout` behavior, and the existing Codable array
field. Core insertion, duplicate checks and invariant checks use compact
operations directly. Canonical replay still contains the complete sorted list.

This is not a fixed upper bound on every possible history. An uncompleted or
never-issued gap blocks the prefix, and later completions remain in the sparse
Set until that gap closes. Explicit public Set reads, encoded checkpoints and
canonical replay snapshots still enumerate the full history for compatibility.

## Reproduction

From a checkout containing the baseline commit and candidate sources:

```sh
python3 Benchmarks/CompletedEffectHistory/run.py \
  --output /tmp/illiquid-completed-effect-history \
  --pairs 6 --cycles 32,4096,32768
```

The script requires Swift 6.1 or newer. It compiles the complete, unchanged
production `IlliquidPlaybackCore` and state-space modules, plus their actual
`MediaTrack.swift` dependency, in a temporary Swift package. It fetches no Swift
dependencies and uses no model or platform stubs. On Linux the compiler must be
installed separately; use `--swift /absolute/path/to/swift` if necessary. Full-app
qualification uses the repository's pinned native SDK on macOS.

The default baseline is `af1c1add701e49b355448cf8983eaed1e7623108`.
Sources are copied byte for byte from that commit for the baseline and the current
worktree for the candidate. `manifest.json` records hashes, compiler, platform,
the baseline and candidate revision, and measured binary hashes.

## Workloads and measurement

- **Transport:** a paused load, then play/pause pairs and their real completions.
- **Replacement:** a paused load, then alternating source loads, allowing the
  production model to allocate and settle each replacement normally.
- **Checkpoint burst:** checkpoint effects complete out of order in bounded
  batches, exercising temporary gaps and their later collapse.
- **Unclosed gap:** a deliberately seeded allocator starts at ID 2; transport
  then completes normally. ID 1 is never reported complete, so this control must
  preserve sparse Set storage instead of claiming all prior IDs completed.

Each observation runs in a fresh process. Baseline/candidate execution order
alternates AB/BA. A separate small fixture warms framework and diagnostic paths.
The measured fixture records no replay steps. Its retained allocator sample is
taken while explicitly keeping it alive, before any public Set read, canonical
snapshot or JSON encoding. The release sample follows destruction of that
fixture. Only then does an untimed second fixture produce semantic receipts.

The retained metric is the allocator's total live-byte change from before fixture
creation to the end of the workload:

- macOS: `malloc_zone_statistics(NULL).size_in_use`.
- Linux/glibc: `mallinfo2().uordblks + mallinfo2().hblkhd`.

This includes the whole model fixture and allocator effects. It is neither an
exact per-object size nor RSS. Wall and process CPU timings cover the command and
completion loop, excluding initial load and diagnostic serialization. Short
controls are particularly susceptible to timer and scheduling noise.

## Correctness gates

The runner executes existing baseline core/state-space tests in release mode and
candidate tests in debug and release mode. A byte-equivalent deterministic replay
comparison covers duplicate callbacks, unknown IDs, out-of-order completions,
stale contexts and source replacement. Every timed pair must agree on command and
completion counts, effect-ID checksum, final canonical state digest, Codable
round-trip digest, and absence of invariant violations.

Dedicated candidate tests cover long histories, gaps, sparse Set release,
arbitrary legacy IDs, zero and `UInt64.max`, randomized reference-Set parity,
public Set mutation and `inout`, copied states, checkpoint compatibility, and
recognition of the oldest completion after a long session.

## Rejected approach

An initial implementation stored arbitrary disjoint intervals in a sorted array.
It compacted sequential and bounded-out-of-order workloads, but exploratory
optimized Linux tests found globally shuffled sparse insertion roughly 5–8 times
slower at 10,000–20,000 IDs because insertion shifted the interval array. That
approach was rejected. Keeping a verified prefix plus a Set for the remainder
avoids that shifting behavior and retains the existing data structure for
unusual sparse histories.

## Evidence

Final native and portable results, source receipts, and test summaries are stored
under `evidence/`. See those receipts for the measured candidate source hashes and
exact scope; benchmark counts are synthetic stress workloads, not inferred user
session durations.
