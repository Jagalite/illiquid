# Bounded runtime lease release history

## Finding and scope

The native runtime retained every completed resource-lease record for its entire
lifetime. Each subsequent session replacement scanned that growing dictionary
when superseding the old session's authority. This investigation separates
unresolved custody from completed diagnostic evidence.

The baseline is commit `68274d1b09dcc866296321a5a8858efc297c4f19`, after the
October 17 integration. The only changed production file is
[`PlaybackRuntimeMetadata.swift`](../Sources/IlliquidNativePlayback/Runtime/PlaybackRuntimeMetadata.swift).
Earlier shortcut research mentioned lease history as a deferred opportunity;
it did not implement or qualify a change to its diagnostics contract.

Before publication on October 19, the change was applied to current main
`33fff16155c3472960f88e04c72dfdfdefd56dcf`. All four production source files
used by the component experiment are byte-identical between that main commit
and the recorded baseline. The retained October 17 measurements therefore
still compare the exact current component implementation; native qualification
uses the complete current app graph.

`PlaybackRuntimeMetadataDirectory.beginSession()` acquires a worker lease for
each native session. Source changes and audio-track replacements can create new
sessions within one runtime lifetime. The native runtime's existing cleanup
paths request release and acknowledge physical release after workers or
platform borrows settle. On the baseline, acknowledgement changes the record's
disposition to `.released`, but leaves the full record in the dictionary.

The baseline `supersede(authority:)` therefore visits both unresolved and all
previously completed records. `snapshots()` also materializes and sorts the
entire lifetime inventory. This is retained bookkeeping; the record does not
own a decoder, media buffer, or native worker.

## Implementation and diagnostic contract

The dictionary now contains every unresolved lease. A successful physical
release moves its complete immutable snapshot into a recent-history array.
The array grows as completions arrive, then overwrites its oldest completion
after reaching 128 entries.

The contract is:

- Every `.current`, `.superseded`, and `.releaseRequested` record remains
  visible, regardless of age or the number of later completions.
- Release still requires an explicit request and an empty active-borrow set.
- Removal from live custody and insertion into release history happen under
  the same existing lock.
- The latest 128 confirmed releases remain available with their complete
  provenance. Retention follows completion order, including late completion
  of a low-numbered lease.
- Returned snapshots remain sorted by lease ID.
- Repeated or unknown release callbacks return `false`. Completed IDs cannot
  be borrowed, resurrected, or refreshed in recent history by late callbacks.

The intentional observable change is the historical diagnostic window after
more than 128 releases. The snapshot type and accessors are internal. Current
consumers are the runtime testing accessor, authority-fence tests, native
replacement/shutdown tests, and deterministic race qualification. No product
UI, persisted schema, or public diagnostics payload consumes the lifetime
history.

The native quiescence helper requires a nonempty snapshot list and every
record to be released with no active borrows. Retaining a nonzero recent
history preserves that evidence; retaining all unresolved records means a
failed or delayed cleanup still prevents that predicate from passing. The
runtime registry does not replace the core's shutdown authority.

The structural entry bound is **all unresolved leases plus 128 completed
records**. Dictionary capacity may remain allocated after a historical peak
of concurrently unresolved leases. The entry bound is therefore distinct from
allocator bytes, resident memory, or a whole-player memory ceiling.

## Experiment design

[`Benchmarks/RuntimeLeaseHistory`](../Benchmarks/RuntimeLeaseHistory/README.md)
contains the reproducible runner, harness, and source receipts. The component
build uses the actual production ledger and metadata directory, playback
identity types, and Foundation locking. It does not open media or simulate
decoder performance.

The benchmark seeds completed history, retains application-level resources,
then measures a batch of complete session-bookkeeping cycles. History setup
uses the normal acquire/request/acknowledge APIs; supersession is omitted only
during setup because every seeded record ends fully released. The measured
cycles include supersession. Each result records the starting history and
number of additional cycles so the growing baseline is explicit.

Fresh processes run in balanced baseline/candidate and candidate/baseline
pairs. Small histories and a large unresolved-lease control are retained in
the results. Snapshot cost is measured separately from replacement cost.
Allocator samples are collected outside timed loops and before snapshot
materialization. They describe component-process allocator occupancy, not
physical footprint, media-memory retention, or energy use.

Canonical comparisons preserve every unresolved record and select the most
recent 128 baseline release completions before comparing full snapshots.
This qualifies the new diagnostic contract; it does not claim equality of
the deliberately removed older history.

## Linux component results (October 17, 2026)

The formal run used Swift 6.3.2 release optimization on an AMD EPYC 9V74
x86-64 host with glibc 2.39. Six balanced AB/BA pairs for each of six cases
produced 72 fresh-process observations. Each process measured 128 replacement
cycles followed by 16 separate snapshot calls. A separate disposable fixture
warmed the code before constructing the measured fixture.

The table reports medians of each process's average time per call, in
microseconds. The percentage compares the baseline and candidate medians;
it is not the median of within-pair percentage changes. Raw wall and CPU
observations, all ranges, allocator samples, and compiler/source identities
are retained in the
[Linux evidence](../Benchmarks/RuntimeLeaseHistory/evidence/linux-20261017/summary.json).

| Completed history during batch | Extra pending workers | Replacement wall, baseline → candidate (µs) | Replacement wall reduction | Snapshot wall, baseline → candidate (µs) |
| --- | ---: | ---: | ---: | ---: |
| 0 → 128 | 0 | 9.669 → 1.519 | 84.29% | 54.275 → 7.807 |
| 32 → 160 | 0 | 13.881 → 1.372 | 90.12% | 85.491 → 11.291 |
| 128 → 256 | 0 | 26.979 → 1.257 | 95.34% | 99.245 → 6.979 |
| 1,024 → 1,152 | 0 | 145.030 → 1.262 | 99.13% | 543.926 → 6.957 |
| 8,192 → 8,320 | 0 | 1,561.964 → 1.263 | 99.92% | 5,445.424 → 7.124 |
| 8,192 → 8,320 | 256 | 1,382.627 → 33.164 | 97.60% | 5,289.816 → 216.900 |

For the 8,192-history case without extra pending workers, replacement CPU
time was 1,560.887 → 1.306 µs per cycle. Wall-time ranges across all six
processes were 1,277.104–1,746.103 µs for the baseline and 1.228–1.682 µs
for the candidate. The large separation supports removal of the growth
cost on this workload; these six pairs do not establish player-wide latency
percentiles or a universal speedup factor.

The zero-history control is a batch that accumulates 128 releases, not a
single-open or startup measurement. Snapshot work intentionally returns a
bounded history after the first 128 releases; it is not an equal-output
comparison against the old lifetime inventory.

Allocator readings use `mallinfo2.uordblks + mallinfo2.hblkhd`. The following
medians subtract the sample before fixture construction from the sample
after the cohort, before materializing snapshots:

| Starting completed history | Extra pending workers | Baseline allocator increment (bytes) | Candidate allocator increment (bytes) |
| ---: | ---: | ---: | ---: |
| 0 | 0 | 108,800 | 57,936 |
| 32 | 0 | 108,800 | 57,936 |
| 128 | 0 | 217,376 | 57,936 |
| 1,024 | 0 | 868,832 | 57,936 |
| 8,192 | 0 | 6,949,088 | 57,936 |
| 8,192 | 256 | 6,973,568 | 296,192 |

The ordinary fixture retains three application leases and one current worker.
After the 8,192-history batch, the baseline contains 8,324 records; the
candidate contains 132: all four unresolved records and 128 completed
snapshots. In the delayed-teardown control the candidate retains all 260
unresolved records and all 258 active borrows, plus the same 128 completions.
Its higher cost demonstrates that unresolved work remains visible and still
participates in custody scans. Allocator deltas include runtime and allocator
effects and are neither exact object sizes nor resident-memory measurements.

## Correctness qualification

The new `RuntimeLeaseHistoryTests` suite covers seven cases:

1. 4,096 session replacements retain exactly the latest 128 completed records.
2. 320 unresolved leases across all unresolved dispositions survive 1,024
   unrelated completions with their borrows intact.
3. Reverse-order completion proves eviction follows release time.
4. Mixed live/released snapshots retain complete nondefault provenance and
   ascending lease-ID order.
5. Supersession distinguishes application, session, generation, and revision
   authorities, and preserves requested release state.
6. Wrong IDs, multiple borrows, duplicate returns, expired callbacks, and
   earlier immutable snapshots preserve custody and release-history order.
7. 8,000 seeded operations agree with an independently maintained unbounded
   custody model that projects recent release history only when inspecting.

The baseline-compatible API lets the runner demonstrate the original growth
with an explicit negative control, separately from passing unchanged-contract
tests. Build errors or unrelated failures are not acceptable negative-control
evidence.

In the formal Linux run, all seven candidate tests passed in both debug and
release. Both unchanged-contract tests also passed on the baseline in each
configuration. The baseline history-bound negative control failed with
exactly the two intended count/history assertions. All 12 scenario/checkpoint
comparisons matched every projected snapshot field, and all 72 timed
observations passed operation-count and deterministic-checksum checks. The
[test receipt](../Benchmarks/RuntimeLeaseHistory/evidence/linux-20261017/tests.json)
and [canonical comparison](../Benchmarks/RuntimeLeaseHistory/evidence/linux-20261017/canonical-comparison.json)
record those results. Test builds use separate scratch directories; final
optimized measurement binaries are built and hashed after the tests.

## macOS qualification

Native execution results are pending the PR workflow. Linux component results
alone do not qualify the macOS app dependency graph.

The dedicated
[`runtime-lease-history.yml`](../.github/workflows/runtime-lease-history.yml)
workflow also generates the existing three-audio-track H.264/AAC fixture and
runs the actual native runtime tests for stopping during replacement, shutdown
during candidate preparation, and repeated audio-track replacement. It uses
the repository's checksum-verified native SDK and release app dependency
graph. The fixture exists and is supplied explicitly, so those selected test
bodies cannot silently return because the fixture directory is absent.

## Practical interpretation

The change removes completed-history growth from future custody scans and
bounds retained completed metadata. It is most relevant to a runtime that
undergoes many source or track replacements. It does not change video decoding,
rendering, physical worker cleanup, playback position, or resource admission.
Component results should not be presented as a measured reduction in total
player CPU, file-open latency, battery use, or resident media memory.
