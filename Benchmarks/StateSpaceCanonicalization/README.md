# State-space canonicalization

## Problem and change

The playback state-space explorer used to construct a full normalized pre-state
key at the start of every action. The key was only read when a production
transition was classified as stale. Canonicalization normalizes the active
session, outstanding effects, late results and resource leases, creates strings,
and sorts normalized records.

The candidate computes the pre-state key from the immutable input only inside
the stale-transition invariant check. The original early key was taken after
incrementing depth and before changing any other input fields; depth is excluded
from canonical state identity. The comparison still checks exactly lifecycle,
external wait, active session and leases, with the same post-state key and
violation. Accepted, rejected, executor-only and ingress-rejected actions avoid
the unused pre-state computation.

This changes verification throughput. It does not change the search abstraction,
action inventory, invariant policy or model versions, and makes no playback,
decoding, rendering or battery-life claim.

## Reproduction

From the repository root, on a host with Swift 6.1 or newer:

~~~sh
python3 Benchmarks/StateSpaceCanonicalization/run.py \
  --output /tmp/illiquid-state-space-canonicalization --pairs 6
~~~

Use an empty output directory. The default baseline is commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; use `--baseline COMMIT`
to explicitly select a different comparison. Fetch the baseline if using a
shallow checkout. Candidate sources come from the current worktree.

Follow `AGENTS.md`: submit the command through Kyoto when that queue is
available. The GitHub-hosted workflow uses serial isolated builds because the
shared Kyoto queue is unavailable on the hosted runner.

The runner copies exact production files into two dependency-free packages:
the playback core, the complete state-space module, and their actual
`IlliquidCore/Player/MediaTrack.swift` dependency. It applies no source
transformation or platform stubs. Both packages use the current regression
tests. Source, harness and executable hashes are recorded in `manifest.json`.

## Measurement and correctness

The release executable times an entire `PlaybackStateSpaceExplorer.run`, including
production transitions, state canonicalization, graph construction and the final
reachability digest. Graph verification and JSON serialization happen after the
timed region. Both wall time and process CPU time are recorded.

Each workload runs in fresh processes with balanced baseline/candidate and
candidate/baseline ordering. Both variants use identical bounds without a
wall-clock cutoff. A state/edge cap or an invariant finding fails the run.
The comparisons require identical summaries, invariant results, graph digests,
predecessor digests and the ordered per-node canonical digests across every run.

The workloads cover all six models plus partial-order validation:
seek, EOF/drain, recovery, track/subtitles, stop/shutdown, and
preroll/buffering. An additional external-subtitle search uses the full PR
profile (depth 12, two generations, 50,000-state / 500,000-edge limits), with
only the wall-clock cutoff disabled to keep the amount of work identical.
The selected seed, profile and depth for each are retained with the results. These bounded workloads do not prove equivalence for every possible
application state.

The regression gate runs the existing playback-core and state-space suites for
baseline release and candidate debug/release. Timing is observational, with no
noisy percentage threshold in CI. Retained evidence records individual samples,
medians and ranges, rather than claiming an application-wide speedup.

## Ordinary PR checks

`--tests-only` builds and tests current candidate sources in debug and release;
it does not require the historical baseline or compare historical search graphs.
The pull-request workflow uses this mode so future intentional behavior changes
are not frozen to this experiment. Pushes to the research branch and explicit
workflow dispatches run the full before/after investigation.

## Value semantics

The stale-result comparison reads the same immutable pre-transition core state.
The breadth-first search already retains each source node in its node array while
applying every outgoing action. Delaying the read therefore does not introduce a
new retained source snapshot in this path. The benchmark measures complete
searches, including their actual copy-on-write ownership, rather than isolated
calls with artificially consumed inputs.

## Completed native measurements

[Native run 40633644113](https://github.com/Jagalite/illiquid/actions/runs/40633644113)
completed successfully on macOS 26.6.2 / arm64 with Apple Swift 6.3.3.
The measured candidate was `6b10b7969deaf1de1e5383d2b9333fe1574b29b2`,
against baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
Six balanced pairs per workload produced 84 timed searches. Times below are
medians of whole-search elapsed time, in milliseconds.

| Workload | States / edges | Baseline ms | Candidate ms | Elapsed-time reduction |
| --- | ---: | ---: | ---: | ---: |
| Seek | 573 / 2049 | 52.083 | 41.003 | 21.3% |
| EOF / drain | 69 / 353 | 6.907 | 5.799 | 16.0% |
| Recovery | 8 / 20 | 1.504 | 1.412 | 6.1% |
| Track / subtitles | 127 / 426 | 9.406 | 7.826 | 16.8% |
| Stop / shutdown | 127 / 574 | 15.355 | 12.535 | 18.4% |
| Preroll / buffering | 34 / 183 | 6.202 | 5.150 | 17.0% |
| Stop / shutdown (POR validation) | 62 / 215 | 6.592 | 5.681 | 13.8% |

All seven workloads matched reachability summaries, invariant results, graph
and predecessor digests, and ordered node digests across every process.
The existing 106 tests in nine suites passed for baseline release, candidate
debug, and candidate release. The optimized production source is unchanged by
the subsequent harness and focused-regression additions.

The small recovery workload has only eight states and twenty edges; its timing
is especially sensitive to fixed startup cost. These selected bounded searches
support a verification-throughput improvement, not an application playback
performance claim. CPU medians and wall-time ranges are retained in
[evidence/native-initial/summary.json](evidence/native-initial/summary.json).
The source/compiler receipts and semantic counts are retained alongside it.
Individual initial samples and command logs are in the run's uploaded
`state-space-canonicalization-evidence` artifact (14-day retention).

### Expanded qualification

The current harness additionally measures the full PR-profile external-subtitle
search and prints individual samples in the job log. A focused regression
constructs a stale transition whose production invariant checker changes
lifecycle, requiring `staleResultChangedSemanticState` to remain detectable.

[Expanded run 40634994788](https://github.com/Jagalite/illiquid/actions/runs/40634994788)
was queued when this report was prepared. No measurements or pass claims from
that run are included in the table above.
