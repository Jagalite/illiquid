# Effect settlement research evidence

The measured implementation and harness are pinned to commit
`427b1d2198aab101809f510cfde281b95778eb66`. The subsequent packaging commit
changes documentation, saved evidence, and workflow triggers only.

| Directory | Role and result |
| --- | --- |
| [linux](linux/) | Qualified 47-case cohort: 88 tests in nine suites in each of three configurations, 94 matching semantic traces, 564 timing observations, and 564 allocation observations. [Run 40642352444](https://github.com/Jagalite/illiquid/actions/runs/40642352444), Linux job 122663157712. |
| [exploratory-linux](exploratory-linux/) | Earlier unconditional `compactMap` candidate `6cba034d20ac0603904fada62601e287c5d6ace0`. Correctness and timing finished, but the missing C compiler prevented allocation measurement. Its manifest remains incomplete; these are not the final candidate's results. |

Each directory retains its original `manifest.json`, a provenance `receipt.json`,
and the exact compressed review bundle emitted in the job log. Linux additionally
exposes `summary.json` and `parity.json` for convenient review. The bundle hashes
in the receipts match the job's `EFFECT_SETTLEMENT_BUNDLE_SHA256` line.

The bundle is gzip-compressed JSON. Its `text_files` object maps relative result
paths to original UTF-8 text. It retains all timing and allocation observations,
calibration pilots, complete before/after traces, command records, and build,
test, and measurement logs. The summary contains every workload, including
controls and cases where allocation request counts increase.

To inspect the raw final observations without building anything:

```python
from pathlib import Path
import gzip
import json

path = Path("Benchmarks/EffectSettlement/evidence/linux/review-bundle.json.gz")
bundle = json.loads(gzip.decompress(path.read_bytes()))
timings = json.loads(bundle["text_files"]["observations.json"])
allocations = json.loads(bundle["text_files"]["allocation-observations.json"])
assert len(timings) == len(allocations) == 564
```

For historical reproduction, check out the recorded qualification commit before
following the [benchmark instructions](../README.md). The runner compares against
a fixed baseline and intentionally rejects unrelated production-source changes.
The manual workflow operates on the selected ref; running a later ref is a new
experiment, not reproduction of the saved cohort.

See the [research report](../../../Documentation/EFFECT_SETTLEMENT_MEMORY_PERFORMANCE.md)
for the mechanism, representative results, tradeoffs, and qualification limits.
At packaging time, macOS job 122663157300 was queued; no native measurements or
whole-player qualification are claimed here.
