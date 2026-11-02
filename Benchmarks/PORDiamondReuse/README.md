# Partial-order diamond validation: first-step reuse

## Question and change

The playback state-space explorer validates independent event pairs by applying
both event orders and comparing final states and observations. Every pair begins
at the same input node, but the original reducer recomputes each candidate's
first transition and successor enabled-action list for each pair.

For n candidates, those first-step computations fall from n(n−1) to n when
reused locally. The two second-step transitions, pair ordering, enabled checks,
complete canonical-state comparisons, observation unions, and counters remain
unchanged. Zero/one candidate inputs return immediately. Two candidates use the
original uncached path because there is no first-step reuse opportunity.

This is a verification-tool optimization. It does not change the player runtime
or claim faster decoding, rendering, playback, UI interaction, or energy use.
The tradeoff is O(n) temporary successor storage for n > 2, scoped to one
validation call. The measured production models have five, seven and eight
candidate events; no persistent cache or cross-node invalidation is introduced.

Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Reproduce

Use Swift 6.2.1 or the recorded toolchain and Python 3, with a new output directory:

```sh
python3 Benchmarks/PORDiamondReuse/run.py \
  --output /tmp/illiquid-por-diamond-reuse --pairs 10 --target-ms 250
```

Follow AGENTS.md's Kyoto coordination rule when that queue is available. The
hosted workflow reports its absence before serial isolated builds. The workflow
runs on the exact research branch or by manual dispatch; a frozen historical
comparison is not imposed on unrelated future pull requests.

The runner compiles the full production PlaybackCore and PlaybackStateSpace
modules plus their unchanged MediaTrack dependency. Only the reducer differs
between the two arms. Tests and harness are identical. It records source,
compiler, binary, command and environment receipts, checks the source inventory,
and rejects unexpected source changes.

## Verification

All 24 existing state-space tests plus six focused regressions run against both
implementations in debug and release. The new cases compare with the original
uncached algorithm and assert independent expected counts for repeated
prerequisites, noncommuting queue operations, wrong-operation deduplication,
small inputs and disabled validation.

Complete semantic receipts cover all advertised seeds, reached seek/drain/queue
states, reversed and duplicated action lists, and four bounded explorer runs.
They retain ordered actions with enum payloads, complete canonical state keys,
graph edges, predecessor trees, failures, summary fields, node depths and
sequences. Only the known Set-backed JSON fields are sorted; other array order
is preserved. Wall-clock cutoffs are disabled so the searches are comparable.
Compressed complete receipts and their hashes are retained.

## Measurements

Nine workloads include the real five/seven/eight-candidate reductions; two, one
and zero candidates; validation disabled; and complete depth-three seek and
preroll searches.

Fixtures are prepared outside timing for reductions. Complete search timings
include seed construction and the actual explorer call. Eight reduction calls
or one full search warm each fresh process. Timed checksums consume every
returned action class and all reduction counters, or complete search summary
counts and the production canonical digest. Full enum/state/graph equality is
checked separately before timing.

Adaptive pilot batches reach at least 20 ms, then establish a common iteration
count targeting 250 ms for the faster implementation, with 30% margin. Ten
balanced AB/BA pairs run in fresh processes. All observations are retained;
output and warmup checksums plus deterministic work counts must match. Reports
include wall and process CPU times, ranges, paired changes, seeded bootstrap
intervals, and any duration shortfalls.

The results qualify these portable workloads on one hosted machine. They do not
establish macOS application performance, peak memory, or the cost of a complete
large qualification profile.

## Recorded result: 28 October 2026

[Successful Actions run 40640741259](https://github.com/Jagalite/illiquid/actions/runs/40640741259)
measured candidate `28f9f053b79337ef738f7f72baaff489ee97781f` against the baseline above,
using Swift 6.2.1 on x86_64 Linux, an AMD EPYC 7763 host and four reported logical
CPUs. The evidence below is retained in this repository, independently of the
expiring Actions artifact. Subsequent commits add documentation and evidence;
the measured production code, tests, harness and runner are unchanged.

The three multi-candidate reductions used 41.65–60.86% less wall time. Complete
depth-three seek and preroll searches used 47.27% and 40.50% less wall time,
respectively. CPU-time changes closely matched wall time. These improvements
occurred in every measured pair for those five workloads.

| Workload | Baseline median | Candidate median | Wall change | CPU change | Paired wall 95% interval |
| --- | ---: | ---: | ---: | ---: | ---: |
| Seek validation · 8 candidates | 4.089 ms | 1.664 ms | -59.30% | -59.30% | -59.46% to -59.06% |
| EOF drain validation · 7 candidates | 2.085 ms | 0.816 ms | -60.86% | -60.86% | -61.09% to -60.63% |
| Preroll validation · 5 candidates | 0.468 ms | 0.273 ms | -41.65% | -41.65% | -41.87% to -41.28% |
| Two candidates | 144.364 µs | 145.830 µs | +1.02% | +1.02% | +0.53% to +1.81% |
| One candidate | 375.53 ns | 370.46 ns | -1.35% | -1.35% | -1.75% to -1.07% |
| Zero candidates | 116.79 ns | 115.81 ns | -0.84% | -0.84% | -2.92% to +0.80% |
| Validation disabled | 58.190 µs | 58.321 µs | +0.23% | +0.22% | -0.99% to +1.02% |
| Complete seek search · depth 3 | 127.290 ms | 67.121 ms | -47.27% | -47.27% | -47.50% to -46.84% |
| Complete preroll search · depth 3 | 51.673 ms | 30.746 ms | -40.50% | -40.50% | -40.94% to -40.18% |

Changes are candidate/baseline minus one, so negative values mean less time.
The change columns compare separate medians; the last column bootstraps the
median of the ten within-pair percentage changes. All 180 observations met
the 250 ms measured-batch target. No observations were removed. Absolute
invocation timings include the identical result-consumption work described
above, which can dominate the smallest controls.

The two-candidate control is a small observed regression: +1.02%, or 1.47 µs
per invocation, with a paired interval entirely above zero. That path avoids
building the cache but still passes through the new selection logic. Its
precise cause was not isolated. The one-candidate control improved by 1.35%;
zero candidates and disabled validation did not establish a directional
change in their paired intervals. These controls are reported rather than
described as uniformly unchanged.

### Correctness and work performed

All 30 tests passed for baseline and candidate in both debug and release:
120 test executions in total. This includes the 24 existing state-space tests
and six focused differential/regression tests.

All four binaries produced identical complete exported receipts for 49
reduction cases and four bounded searches. The shared uncompressed receipt
SHA-256 is `1ae5cfa41cff8bbf3b4ff88e4c85aa8352fef3f63569f2e96adf552d8667d33f`.
The receipts compare exported results and graph/state data; they do not
independently record each intermediate diamond verdict. Source review also
confirmed pure first-step reuse and unchanged second-step comparisons,
observation unions, pair order and counter updates.

The timed seek search retained 196 states, 519 edges, 784 validated diamonds,
and zero noncommuting diamonds. The timed preroll search retained 120 states,
340 edges, 350 validated diamonds, and 24 noncommuting diamonds. Both completed
within the configured bounds. Timed and warmup checksums and all deterministic
work fields matched for every observation.

All source and binary hashes matched before and after execution. The reducer
was the only differing production source between arms. An independent audit
reassembled and SHA-256-checked the emitted files, reproduced the four test
logs exactly, and recomputed the observation matrix, medians, paired changes
and duration accounting from the raw samples.

### Retained evidence

- [Summary](evidence/linux-20261028/summary.json) and
  [all 180 observations](evidence/linux-20261028/observations.json).
- [Calibration history](evidence/linux-20261028/calibration.json) and
  [all command receipts](evidence/linux-20261028/commands.json).
- [Source, binary and environment manifest](evidence/linux-20261028/manifest.json).
- [Test and parity verification](evidence/linux-20261028/verification.json),
  [completion receipt](evidence/linux-20261028/completion.json), and
  [independent audit](evidence/linux-20261028/independent-audit.json).
- [Complete compressed reference output](evidence/linux-20261028/reference-trace.json.gz).
  All four trace files listed in the verification receipt have identical
  compressed bytes; one copy is retained here.
- Exact [baseline debug](evidence/linux-20261028/tests-baseline-debug.log),
  [baseline release](evidence/linux-20261028/tests-baseline-release.log),
  [candidate debug](evidence/linux-20261028/tests-candidate-debug.log), and
  [candidate release](evidence/linux-20261028/tests-candidate-release.log) test logs.

The measured benefit qualifies these production verification workloads on this
host. It does not establish a speedup for every model, deeper searches, other
toolchains or macOS. Peak temporary memory was not measured.
