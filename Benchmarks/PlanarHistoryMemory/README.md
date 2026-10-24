# Planar ownership history memory

This experiment compares the production ownership ledger before and after
removing its redundant historical identity set. `lastCheckoutByBuffer` already
retains exactly the same historical keys; its values also identify the latest
checkout. The candidate derives distinct identity count and reuse detection
from that one dictionary without changing release or flush semantics.

See the [research report](../../Documentation/PLANAR_HISTORY_MEMORY_PERFORMANCE.md)
for production scope, the representation invariant, and measured results.

## Reproduce

Run from a checkout containing the candidate and the pinned baseline commit:

```sh
python3 Benchmarks/PlanarHistoryMemory/run.py --output /tmp/planar-history-new
```

Use a fresh output directory. On a machine with the repository's shared Kyoto
queue, submit the command through that queue as directed in `AGENTS.md`.
The hosted macOS workflow uses an isolated build when Kyoto is unavailable.

The default run uses six alternating baseline/candidate pairs, 16, 128, 1,024,
and 8,192 historical identities, five 2,000-operation trace seeds in debug and
release, and 50,000 measured lifecycle operations after 5,000 warmup operations.
Every measurement runs in a fresh process. `--tests-only` runs qualification
without timing or heap measurements. Ordinary PR jobs use that option; full
measurements run only on the named research branch or manual dispatch.

## What is measured

The runner compiles the complete production ledger from pinned baseline
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` and from the candidate checkout.
Both variants use identical harnesses, framework boundary, optimization,
compiler, and fixtures. Source, harness, test, runner, and binary hashes are
recorded in `evidence/manifest.json`.

`Harness.swift` preallocates and keeps alive distinct, tiny pixel buffers before
the initial allocator checkpoint. It then creates a ledger and performs one
serial checkout/release per identity, followed by a second pass reusing every
identity. Both passes finish with zero known owners. Live heap is sampled after
temporary autorelease pools drain; a separate checkpoint after ledger
destruction checks whether the measured memory follows the ledger lifetime.
Pixel-buffer allocation is outside the measured delta. The high-cardinality
cases are synthetic identity-churn stress, not a claim about normal pool size.

The macOS run uses real CoreVideo buffers, CoreMedia sample attachments, and
`malloc_zone_statistics(NULL).size_in_use`. Linux runs replace only the framework
boundary with existing identity/sample stubs and report `mallinfo2` allocator
statistics. Those statistics include glibc thread-cache residue, so small Linux
deltas may not isolate live storage. Inspect the destruction checkpoint; native
results qualify the memory claim. Peak RSS includes fixtures and is auxiliary.

Lifecycle timing uses the existing `PlanarOwnership` harness without its
allocation meter or per-step trace recording; production signposts remain.
It runs
with pipeline and mixed-ownership workloads at 1, 16, and 32 live owners.
Summary percentages are medians of paired changes, with all pairs and ranges
retained. These measurements do not establish whole-player RAM, frame-rate,
latency, or statistically significant throughput improvements.

## Correctness and evidence

The established trace harness exercises checkout reuse, phase transitions,
overlapping and renderer-only ownership, stale callbacks, flushes, generations,
pool timeouts, and ARC destruction. Both variants must have identical counters,
flags, and optional timing presence at every snapshot. Timing values must be
finite and nonnegative; actual wall-clock durations are not compared for equality.
The complete equal traces are retained once in compressed form, with both
command outputs independently hash-bound in `commands.jsonl`.

On macOS, the production ledger and signpost source are also compiled into an
isolated native test package. Both the existing transition suite and the new
history suite run in debug and release. The two new tests guard lifetime history
after all owners release, flushes, and generation changes.

The evidence directory contains raw memory and timing rows, paired summaries,
full differential traces, test logs, compile logs, provenance, and a completion
receipt. No sample is removed because its result is unfavorable. The workflow
uploads that directory; its compressed log export is an additional transfer
mechanism for the same evidence.
