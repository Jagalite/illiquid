# Scalar-rank portable evidence

This directory records the completed
[Linux qualification run](https://github.com/Jagalite/illiquid/actions/runs/40639259602)
for `4272fc9ce7188e4eeddff46ac8c1de317eed8ad3`, comparing the actual production
selection function with pre-change main `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

- `receipt.json` preserves the compact research receipt emitted by the job:
  source/compiler/build provenance, all 320 final observations, calibration
  observations, iteration counts, full summary, differential count/hash, and
  the four complete test logs with their source/build manifests.
- `summary.json` contains the same full sixteen-workload timing summary for
  convenient inspection.
- `audit.json` records the independent recomputation of all medians, ranges,
  changes, paired ratios, counts, measurement order, source hashes, and tests.
- The complete
  [CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40639259602/artifacts/12795265392)
  additionally retains staged baseline/candidate/driver/test/runner inputs,
  complete selected-ID verification receipts, and individual process logs.

Artifact ID: `12795265392`; compressed size: `350891` bytes; SHA-256:
`7a6e8fdafbca68dee62d1aa69193451a5940c037631202644fd24ae6fa45e1ae`.
The uploaded artifact expires November 27, 2026; the files in this directory
remain part of the repository. Exact sources can also be recovered from the
recorded commits and checked against the receipt's SHA-256 hashes.

The four test runs each passed 13 tests, including the new 32-valid-language
boundary test. Complete differential comparison passed for 55,296 selections.
Source and summary recomputation were independently reviewed before this
evidence was added to the PR.

To regenerate the timing summary from the retained raw rows:

```sh
mkdir -p /tmp/track-rank-recomputed
python3 - <<'PY'
import json
from pathlib import Path
receipt = json.loads(Path("Benchmarks/TrackSelectionRanking/evidence/scalar-rank-linux/receipt.json").read_text())
Path("/tmp/track-rank-recomputed/measurements.jsonl").write_text(
    "".join(json.dumps(row) + "\n" for row in receipt["measurements"])
)
PY
python3 Benchmarks/TrackSelectionRanking/run.py summarize --output /tmp/track-rank-recomputed
```

See the [research report](../../../../Documentation/TRACK_SELECTION_RANK_STORAGE_PERFORMANCE.md)
for scope, the full result table, and the automatic-subtitle regression.
These results use Linux x86_64 with Swift 6.2.1. They do not qualify macOS
performance or end-to-end playback. Native qualification is tracked by
[run 40636409015](https://github.com/Jagalite/illiquid/actions/runs/40636409015).

The earlier [container setup failure](https://github.com/Jagalite/illiquid/actions/runs/40637894299)
occurred before compilation and produced no timings.
