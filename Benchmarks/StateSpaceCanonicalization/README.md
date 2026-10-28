# State-space pre-transition canonicalization

## Result

Deferring the pre-transition canonical key until a stale transition needs it
reduced the median paired wall time of the complete PR seed inventory by
**21.42%** on Linux x86_64 with Swift 6.2.4. The median run dropped from
**110.888 s to 87.116 s**, saving about 23.77 seconds per sweep.

This measures the playback state-space qualification tool. It does not measure
native media playback, rendering, memory consumption, or power use.

Evidence comes from the successful [GitHub Actions run 40640375360](https://github.com/Jagalite/illiquid/actions/runs/40640375360)
on October 28, 2026:

- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
- Measured candidate: `a913fe160dd995c7bb245f79691d210884410b96`, clean worktree.
- Host: Linux x86_64, Swift 6.2.4, target `x86_64-unknown-linux-gnu`.
- Container: `swift:6.2.4-noble@sha256:d6f8f6112e9a63da0a4a151d6b93acd16699d35c0b82531ac1a245f5af210197`.
- Four balanced baseline/candidate pairs, eight fresh serial processes.

| Metric | Baseline median | Candidate median | Median paired reduction |
| --- | ---: | ---: | ---: |
| Wall seconds | 110.888 | 87.116 | 21.42% |
| Child CPU seconds | 110.848 | 87.077 | 21.43% |

| Pair | Execution order | Baseline wall seconds | Candidate wall seconds | Reduction |
| --- | --- | ---: | ---: | ---: |
| 1 | baseline, candidate | 110.949 | 88.128 | 20.57% |
| 2 | candidate, baseline | 110.967 | 87.084 | 21.52% |
| 3 | baseline, candidate | 110.827 | 86.636 | 21.83% |
| 4 | candidate, baseline | 110.772 | 87.149 | 21.33% |

Every pair improved. The baseline wall range was 110.772–110.967 s and the
candidate range was 86.636–88.128 s. These are repeated samples on one runner,
not a population estimate across machines. The percentage above is
`100 × (1 − median(candidate / baseline))` over paired observations.

## Why this area

The state-space explorer evaluates a large number of outgoing transitions when
qualifying playback behavior. Its `apply(action:to:configuration:)` function
previously normalized the entire input state before every action. That work
includes building canonical arrays and strings and sorting identifiers. The
pre-transition key was only consumed by the stale-transition invariant check.

The change moves that computation into the existing `if case .stale` branch
and computes it from the original `input`. Before the original computation,
the only modification was incrementing `node.depth`; depth is not part of the
canonical key. Keeping the original input therefore preserves the same
pre-transition key for the check. Computing it from the post-transition node
would incorrectly hide mutations.

The production diff moves one key computation and adds an explanatory comment.
Canonicalization rules, model versions, action ordering, search bounds,
partial-order reduction, and the playback reducer remain unchanged. The
recorded source hashes show that the explorer is the only production source
file that differs between the two measured packages.

## Correctness evidence

Both baseline and candidate passed **108 core/state-space tests in debug and
108 in release**, with Swift warnings treated as errors. Both packages used
the same current tests, including the added stale-generation result cases
(direct and retained late delivery) and stale-overlay bookkeeping case. Those
regressions also check that applying an edge leaves its predecessor unchanged.

All eight timed sweeps processed the same 40 model/seed combinations:

| Model | Seeds | States per sweep | Edges per sweep |
| --- | ---: | ---: | ---: |
| eof-drain | 12 | 31,472 | 340,432 |
| preroll-buffering | 8 | 20,632 | 260,578 |
| recovery | 5 | 43,843 | 409,327 |
| seek | 4 | 35,456 | 310,591 |
| stop-shutdown | 8 | 8,027 | 93,881 |
| track-subtitles | 3 | 12,498 | 109,502 |
| **Total** | **40** | **151,928** | **1,524,311** |

Every sweep completed within the configured bounds and had no reported
invariant violations, stuck states, closed nonterminal strongly connected
components, or noncommuting-diamond findings. The runner compared all summary
and progress fields, seed inventory, and canonical digests exactly after
removing only source revision/dirty provenance. All eight semantic receipts
have SHA-256
`8fb7693aeacc1ae5cb46e5c04f26d2968b9555d3123949a98e8562a4e8ee59ee`.

The PR profile remains a bounded search. Its depth limit is unchanged, and
18,374 states per sweep remain classified as unmeasured depth cutoffs. This
result is not an unbounded correctness proof. No timed sweep hit a time,
state, or edge termination cap.

Additional validation compared 18 small, depth-three searches: the first seed
of each of six models, with partial-order reduction disabled, conservative,
and validation modes. Exact serialized graph, predecessor, and ordered
state-key SHA-256 receipts matched between versions, as did their summary and
progress reports. This full-graph check is separate from the full PR sweeps'
summary/progress comparison.

Three synthetic failure cases exercised artifact creation, minimization, and
replay. Each produced the same serialized artifact on both versions and
reproduced its injected failure. Each witness was already one step long, so
these receipts establish parity for that path without demonstrating a
nontrivial trace reduction.

The experiment invokes the actual CLI with `--profile pr --all-seeds`.
It does not run the shell wrapper's frozen trend-baseline gate.

## Measurement method and scope

The runner copies production source files into two dependency-free Swift
packages: all playback core and state-space sources, plus the actual
`MediaTrack.swift` dependency. It does not build the full application or
substitute model stubs. Both variants use the same parity driver and tests.

The CLI is byte-identical to the repository source on macOS. On Linux, only
its Darwin import is adapted to Glibc and stderr logging uses Foundation.
Search logic remains unchanged; original and staged file hashes and the
transformation are recorded. No playback core or state-space source receives
a portability rewrite.

Tests and release builds run serially in isolated package directories.
Ordinary release executables are rebuilt after testing and their executed
bytes are hashed. Compilation, tests, small parity searches, and one excluded
seek/ready-playing warm-up per variant are outside primary timing.

Each timed observation launches a fresh release CLI process for the full
inventory. Wall time includes process startup, search, progress analysis,
summary writes, and teardown. CPU time is the change in child resource usage.
JSON comparison and hashing occur after the timed subprocess returns.
AB/BA ordering balances the four pairs.

The production PR profile's state, edge, and depth bounds and 60-second
per-seed time limit are unchanged. A failing or time/state/edge-capped sweep
is rejected as performance evidence. The small parity searches disable the
wall-clock limit on both sides. No timing threshold is a correctness gate.

Native macOS execution and full-application tests were not completed for this
experiment. Playback frame rate, startup latency, energy use, and
wall-clock-limited nightly search coverage are outside these measurements.
The measured improvement applies to the recorded Linux toolchain and host.

## Reproduce

Use macOS 26 or Linux with Swift 6.1 or later, Python 3.10 or later, and a Git
checkout containing the pinned baseline commit:

```sh
python3 Benchmarks/StateSpaceCanonicalization/run.py \
  --pairs 4 --output /tmp/illiquid-state-space-key-results
```

Use a new output directory. When Kyoto is available, submit the entire command
through the shared queue and inspect its show/logs/wait results as required by
`AGENTS.md`. On isolated CI where Kyoto is unavailable, builds run directly
and serially in separate baseline and candidate scratch packages.

The manual `State-space canonicalization performance` workflow reproduces the
Linux cohort. It is deliberately a research workflow: its fixed historical
baseline must not become a permanent PR gate that rejects intentional future
semantic changes. The original successful run used a temporary branch push
trigger; the final documentation/evidence commit removes that trigger without
changing the measured source, tests, or harness.

## Retained evidence

The six JSON files under [evidence/linux](evidence/linux) preserve the values
emitted by the successful run, formatted for review:

- [manifest.json](evidence/linux/manifest.json): commits, host/compiler, source,
  harness, and executed-binary hashes.
- [tests.json](evidence/linux/tests.json): all four test completion receipts,
  commands, and log hashes.
- [parity.json](evidence/linux/parity.json): both small-search and injected
  failure receipts.
- [canonical-results.json](evidence/linux/canonical-results.json): the shared
  full PR qualification output.
- [measurements.json](evidence/linux/measurements.json): all eight raw timed
  observations and their semantic hashes.
- [summary.json](evidence/linux/summary.json): medians, ranges, and paired ratios.

The Actions artifact `state-space-canonicalization-linux` additionally contains
all command logs and full per-run output directories, with 30-day retention.
Paths in the committed receipts refer to that artifact's review directory.
The emitted JSON receipt also remains in the completed job log. Later
documentation and evidence commits do not change the measured implementation.
