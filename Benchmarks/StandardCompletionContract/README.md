# Shared standard completion-contract storage

This experiment measures the allocation cost of constructing the standard
one-shot completion contract used by `PlaybackEffect`. The baseline computes a
new three-token `Set` on every access to `EffectCompletionContract.standardOneShot`.
The candidate stores the same immutable value in a `static let`, so standard
effects share its backing storage. Explicit custom contracts keep their existing
construction and value semantics.

The baseline is pinned to
`4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. The runner stages the complete production
playback core and state-space sources. The only different compiled source file
between its two arms is `Sources/IlliquidPlaybackCore/EventsAndEffects.swift`.
The actual `MediaTrack.swift` supplies the core's sole dependency on
`IlliquidCore`; there are no model stubs or platform replacements. Both arms run
the same current test files, including the new completion-contract regressions.

## Linux result

The recorded cohort uses Swift 6.3.2 in release configuration on x86_64 Linux
with glibc 2.39. All 96 fresh-process observations produced identical complete
canonical effects and state for their scenario/count. The values below are
medians of four observations per arm at 4,096 effects; bytes are unrounded.

All staged playback-core and state-space tests passed in **baseline release,
candidate debug and candidate release: 106 tests in nine suites per run**. Each
run includes the new standard-completion suite. The final source and measured
binary immutability checks passed. These results qualify the isolated component;
they do not constitute a complete player application build.

Committed evidence: [summary](evidence/linux/summary.json),
[raw observations](evidence/linux/observations.json),
[verification and test receipts](evidence/linux/verification.json),
[manifest](evidence/linux/manifest.json),
[exact commands and output](evidence/linux/commands.jsonl), and
[published-source provenance](evidence/linux/provenance.json).

| Scenario | Successful `malloc`/`calloc`/`realloc` requests, baseline → candidate | Requested bytes, baseline → candidate | Incremental allocator-accounted bytes, baseline → candidate |
| --- | ---: | ---: | ---: |
| Default effects retained | 4,096 → 0 | 1,441,792 → 0 | 1,504,752 → 0 |
| Explicit custom effects retained | 8,192 → 8,192 | 1,277,952 → 1,277,952 | 915,952 → 915,952 |
| Pending core checkpoints | 24,600 → 20,504 | 13,132,200 → 11,690,408 | 5,817,496 → 4,312,712 |
| Completed core checkpoints | 24,576 → 20,480 | 5,177,344 → 3,735,552 | 0 → 0 |

The completed-checkpoint workload removes 4,096 successful requests (16.7%) and
1,441,792 requested bytes (27.8%). At every tested count, every pair in both the
direct-default and completed-checkpoint scenarios avoids exactly one request
and 352 requested bytes per effect. The zero settled allocator delta for both
churn arms is consistent with the baseline freeing its temporary sets; the
optimization removes repeated allocation work rather than fixing a leak.

The small cases are included in the evidence. A single default effect shows
allocator deltas of **0 → 0**, while requests fall **1 → 0** and requested bytes
fall **352 → 0**. At 128 retained default effects the allocator delta is
44,528 → 0. The warm-up allocation and allocator caching explain why the
incremental readings should not be interpreted as cold whole-process savings.

The pending-checkpoint allocator saving has a paired median of 1,504,792 bytes
and range 1,488,384–1,504,832 bytes. Its paired requested-byte saving ranges from
1,409,344 to 1,441,792 bytes, with median 1,441,792. Other runtime allocations
vary between fresh processes; the receipt retains that variation. A median of
paired differences need not equal the difference between the two arm medians.
The custom control has identical request counts and requested-byte totals in
every pair. At count 128, one control pair has a 16-byte adverse allocator
difference; the control medians are equal. No observation is discarded.

The measured working-tree candidate matches every compiled source, test and
harness hash in published source commit
[`68b6de16807e67a1472908981233b73f9a8c477e`](https://github.com/Jagalite/illiquid/commit/68b6de16807e67a1472908981233b73f9a8c477e).
The raw manifest's `candidate_head` is still the baseline because the run began
before a local commit; `candidate_sources: current worktree` and the source
hashes identify what was actually compiled. The separate provenance receipt
records the published-source mapping without changing that raw manifest.

These are Linux component results. Native macOS qualification runs separately
in [the dedicated workflow](https://github.com/Jagalite/illiquid/actions/runs/40103198203);
no native pass or matching macOS allocation size is inferred from this cohort.
The effect-creation frequency of real playback was not profiled here, so the
absolute player-level benefit remains workload-dependent.

## What the measurements mean

The primary routine-workload benefit is avoiding one freshly constructed
terminal-token set per default effect. This reduces allocation requests while
effects are issued and completed. It is not an accumulating-leak fix: a baseline
set can be released when its last effect or copy is released.

The candidate keeps one shared set for the rest of the process after first use.
Warm-up initializes that set before measurement. Consequently, a measured saving
for one effect describes an incremental allocation avoided inside the window;
it does not imply a whole-process memory reduction for a process with only one
live default effect. Conceptually, N simultaneously live default effects share
one backing set instead of owning N independently constructed sets.

`retainedAllocatorDeltaBytes` is the allocator reading after the workload minus
the reading for its prepared, empty fixture. The fixture remains alive through
the second sample. This is **incremental allocator-accounted bytes after warm-up**,
not a count of exact live Swift-object bytes or process RSS:

| Platform | Recorded allocator reading | Qualification |
| --- | --- | --- |
| Linux with glibc 2.33+ | `mallinfo2.uordblks + mallinfo2.hblkhd` | Allocator chunk sizes, rounding and caching affect the reading. Freed tcache entries can remain included. |
| macOS | `malloc_zone_statistics(NULL).size_in_use` | Native allocator accounting; sizes need not match Linux. |

Linux additionally interposes `malloc`, `calloc` and `realloc` and counts
successful requests and their requested byte sizes during the workload. These
are not counts of every possible allocation API, live objects, or net retained
memory. A `realloc` counts as a request even if it reuses a block. macOS omits the
two request-counter fields rather than reporting artificial zeroes. The exact
metric and availability flag accompany every observation.

`meteredWallNanoseconds` is diagnostic only. The Linux atomic request counters
add work, and shared-host load can affect timings. This experiment makes no
uninstrumented speedup, playback-latency, cold-start, whole-player, RSS, decoder,
or replay-storage claim. Canonical replay already stores sorted token arrays;
changing the default set's construction does not remove that replay storage.

## Scenarios

Every scenario runs in a fresh process at 1, 128 and 4,096 effects. Each cell has
four pairs in alternating baseline/candidate and candidate/baseline order, giving
96 observations across the four scenarios.

| Scenario | Work inside the measured window | Retained population at the second sample |
| --- | --- | --- |
| `defaultEffects` | Construct actual `PlaybackEffect` values using the default contract. | All effects in a preallocated array. The equal array allocation is outside the window. |
| `customEffects` | Construct effects with an explicit one-token custom contract. | All custom effects in the same kind of preallocated array; unchanged control. |
| `pendingCheckpoints` | Send `.checkpoint` to a prepared, paused production `PlaybackModelRuntime`. | All issued effects remain pending in the actual runtime and core outstanding-effect state. |
| `checkpointChurn` | Send `.checkpoint`, then complete its effect before issuing the next checkpoint. | The settled runtime; no pending or outstanding effects. |

Core fixtures complete a synthetic load through the real model runtime before
measurement. Replay recording is disabled. The runtime does not execute media
I/O, so these are component workloads. The large pending/retained populations
are scaling experiments and do not represent a measured normal-player backlog.

## Correctness and evidence

After each measured fixture is released, a separate validation fixture repeats
the same workload. It verifies the work count and effect-ID checksum, all exact
completion tokens, effect and state Codable round trips, and the expected
pending/outstanding populations. It writes complete canonical effects and final
core state with stable JSON key ordering. The runner compares every byte of this
output against a common reference for that scenario/count; it does not compare
only an aggregate digest or selected fields. Diagnostic copies and encoding do
not enter the measurement window.

One gzip-compressed complete reference per scenario/count is retained in
`semantics/`. Each observation records its uncompressed SHA-256 and byte count;
`verification.json` also records compressed hashes and lengths. A single
reference per cell avoids keeping eight identical large snapshots.

`--run-tests` runs all staged playback-core and state-space tests for baseline
release, candidate debug, and candidate release, with warnings treated as
errors. Test builds have separate scratch roots and cannot replace the measured
release modules. The added tests cover all three standard terminal outcomes,
wrongly scoped tokens, duplicate results, mutation of extracted sets, explicit
custom/phased/subscription contracts, legacy Codable data and canonical replay
equality. Raw `Set` element order is not a serialization guarantee; the schema
and value semantics remain unchanged.

The output contains:

- `manifest.json`: pinned baseline, worktree identity, compiler/platform, all
  staged source and test hashes, harness hashes, generated package hash, and
  release-binary hashes.
- `commands.jsonl` and build/test logs: exact commands, return codes and complete
  output, including build options and each fresh benchmark invocation.
- `observations.json`: raw allocator readings, request counts, instrumented
  times, workload receipts and semantic-reference hashes.
- `summary.json`: per-arm medians/ranges and paired savings recomputed from the
  raw observations. Zero baselines do not become invented percentage savings.
- `verification.json` and `semantics/*.json.gz`: semantic equality, successful
  test receipts and the complete canonical references. `complete` is written
  only after all requested work and final source/binary immutability checks pass.

The staged candidate is identified by exact file hashes even when measurements
start from an uncommitted worktree. Published source can be checked against those
hashes. The runner rejects changes to measured sources, tests, harness files or
binaries during the run. Documentation and evidence files are outside the
compiled-source identity.

The separate [legacy source-boundary receipt](evidence/linux/legacy-source-boundary.json)
qualifies the companion `RuntimeLeaseHistory` harness compatibility fix. It
records successful preparation and resumption against that harness's historical
pinned baseline, including equal hashes for the exact `ExecutorKind` prefix it
compiles. This is a Python source-boundary check, with no Swift compilation or
memory measurement; it is separate from the completion-contract results above.

## Reproduce

Use the shared Kyoto queue when it is available, as required by `AGENTS.md`.
The dedicated GitHub workflow submits this command through Kyoto when present
and otherwise uses isolated direct builds on its hosted runner:

```sh
python3 Benchmarks/StandardCompletionContract/run.py \
  --output /tmp/illiquid-standard-contract-results \
  --pairs 4 --counts 1,128,4096 --run-tests
```

Choose a new, empty output directory. Builds and tests are serialized within
each run, use two build jobs, and need no third-party package downloads. Use
Python 3.10+ and the Swift toolchain recorded with the evidence. The isolated
package declares Swift tools version 6.1 and Swift 6 language mode; that
declaration is not a compatibility test of every older compiler. Unsupported
allocator platforms fail rather than emit zero memory measurements.

The dedicated native workflow runs on pushes to the research branch and by
manual dispatch. This fixed historical-baseline experiment is not a general
future-PR gate: it deliberately rejects unrelated production-source changes.
The regression tests remain part of the ordinary playback-core test suite.

## Metric and language references

- [Swift type properties](https://docs.swift.org/swift-book/LanguageGuide/Properties.html)
  documents lazy, once-only initialization of stored type properties, including
  simultaneous access from multiple threads.
- [glibc malloc statistics](https://sourceware.org/glibc/manual/latest/html_node/Statistics-of-Malloc.html)
  defines the `uordblks` and `hblkhd` allocator-accounting fields used here.
- [Apple's malloc API header](https://github.com/apple-oss-distributions/libmalloc/blob/main/include/malloc/malloc.h)
  documents the native `size_in_use` field and the sum across zones when the
  zone argument is `NULL`.
