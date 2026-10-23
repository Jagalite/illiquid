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
candidate tests in debug and release mode. An identical deterministic replay and semantic-output
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

## Native macOS results

macOS 26.6.2 on arm64, Apple Swift 6.3.3, optimized builds. Baseline
`af1c1add701e49b355448cf8983eaed1e7623108` and candidate
`386c1160c934472c83ac1045aed4f50945e0150c` used identical benchmark sources.
The [native workflow](https://github.com/Jagalite/illiquid/actions/runs/40004876258)
passed both component and app integration jobs. There are six alternating pairs
per workload and size, 144 fresh-process observations in total.

| Workload at 32,768 cycles | Completed effects | Baseline retained bytes | Candidate retained bytes | Reduction |
| --- | ---: | ---: | ---: | ---: |
| Transport | 65,538 | 1,118,272 | 36,928 | 96.70% |
| Source replacement | 65,538 | 1,118,272 | 36,928 | 96.70% |
| Out-of-order checkpoint burst | 32,770 | 611,264 | 70,592 | 88.45% |
| Unclosed-gap control | 65,538 | 1,118,272 | 1,118,272 | 0.00% |

These allocator deltas include other model/runtime allocations. In particular,
the candidate's aggregate macOS fixture total varies across workload sizes;
the result does not establish constant memory for the whole fixture. The
verified consecutive completed-ID prefix itself occupies one counter, while
sparse completed IDs continue to occupy a Set.

Median component wall-time changes for these longest workloads were -6.34%,
-3.50%, -0.52%, and +0.24%, respectively. The short gap control increased by
4.71%, and timing ranges overlap. This study supports a retained-memory
improvement without a demonstrated large timing regression, not a statistically
established speedup or whole-player playback claim. All sizes, raw observations,
CPU timings, ranges, source hashes and test logs are in
[`evidence/macos-arm64/`](evidence/macos-arm64/).

Native qualification passed:

- 88 baseline core/state-space tests in release mode.
- 100 candidate core/state-space tests in both debug and release mode.
- Identical deterministic replay/semantic output and all measured-pair checks.
- A complete native app graph build using the repository's pinned SDK, followed
  by 186 selected release tests across core, state-space, coordinator, renderer
  recovery and relative-seek lifetime suites. See
  [`native-integration-job.log`](evidence/macos-arm64/native-integration-job.log).

## Portable results

Linux x86_64, glibc 2.39, Swift 6.3.2, optimized builds. These are medians
from six alternating baseline/candidate pairs per workload and size; all 144
observations and their ranges are included in
[`evidence/linux-x86_64/`](evidence/linux-x86_64/).

| Workload at 32,768 cycles | Completed effects | Baseline retained bytes | Candidate retained bytes | Reduction |
| --- | ---: | ---: | ---: | ---: |
| Transport | 65,538 | 1,072,256 | 2,608 | 99.76% |
| Source replacement | 65,538 | 1,072,256 | 2,608 | 99.76% |
| Out-of-order checkpoint burst | 32,770 | 571,944 | 35,504 | 93.79% |
| Unclosed-gap control | 65,538 | 1,072,256 | 1,072,256 | 0.00% |

The transport and replacement candidate retained delta was 2,608 bytes at all
three tested sizes: 32, 4,096 and 32,768 cycles. The gap control deliberately
demonstrates the remaining linear-storage case. The checkpoint workload also
retains model and diagnostic allocations unrelated to the completed-ID Set;
the table reports the entire fixture rather than attributing every byte to
one field.

For the longest workloads, median component wall time changed by -8.46%
(transport), -7.64% (replacement), -6.81% (checkpoint burst), and -0.62% (gap
control). Smaller controls included changes of +1.83% and +1.87%. These timings
are observations from one environment, not a player throughput or frame-rate
claim; the retained-memory result is the purpose of the change.

The baseline passed all 88 existing core/state-space tests in release mode.
The candidate passed all 100 tests, including 12 new history regressions, in
both debug and release. The deterministic replay/semantic output was identical
between implementations, and every measured pair passed its semantic checks.
The run began from an uncommitted candidate worktree above the baseline HEAD;
[`receipts.json`](evidence/linux-x86_64/receipts.json) subsequently verifies every
candidate bundle and harness hash against published source commit
`386c1160c934472c83ac1045aed4f50945e0150c`.

## Evidence

Final native and portable results, source receipts, and test summaries are stored
under `evidence/`. See those receipts for the measured candidate source hashes and
exact scope; benchmark counts are synthetic stress workloads, not inferred user
session durations.

Verbose observations, replay output and command transcripts are stored as
deterministic gzip files to keep the review focused on source changes. Their
compressed and original SHA-256 hashes are in each platform's `receipts.json`.
For example, `gzip -dc evidence/macos-arm64/observations.json.gz` prints every
native observation. The runner itself writes ordinary uncompressed JSON.

The native workflow runs the full paired experiment on this research branch and
on manual dispatch. Subsequent pull requests run the exact-source correctness
gates with `--tests-only` plus native integration; they do not treat noisy timing
percentages as a pass/fail performance threshold.
