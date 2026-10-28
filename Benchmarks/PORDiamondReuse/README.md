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
large qualification profile. Results will be recorded after execution.
