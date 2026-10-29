# Source-browser row-storage evidence

The [research report](../../../../Documentation/SOURCE_BROWSER_SEARCH_ROW_STORAGE.md)
contains the conclusions, full case matrix, reproduction commands and limits.

## Completed Linux CI evidence

Run [40635349272](https://github.com/Jagalite/illiquid/actions/runs/40635349272),
Linux job `122640937482`, qualified production commit `e9dad9dc39ac96c6796ebffed970d809d94e28c4`
against baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

- [Provenance](linux-ci/provenance.json): workflow, artifact, source and archive hashes.
- [Environment](linux-ci/environment.json): compiler, runner, affinity and source hashes.
- [Complete retained evidence](linux-ci/evidence.json.gz): all 105 original artifact text files, including 216 timing records, 72 allocation records, four test receipts/logs, build receipts, exact compiled sources, full timing/allocation summaries and completion markers.

The archive is gzip-compressed JSON mapping each original relative artifact path
to its unchanged text. Inspect it with Python's standard library:

```python
import gzip
import json
from pathlib import Path

path = Path("Benchmarks/SourceBrowserSearch/evidence/row-storage/linux-ci/evidence.json.gz")
files = json.loads(gzip.decompress(path.read_bytes()))
print(files["timing/completion.json"])
print(files["allocations/completion.json"])
print(files["timing/summary.json"])
print(files["allocations/summary.json"])
```

The downloaded GitHub ZIP was verified against SHA-256
`00e749b43ea1ef52722ab871d93ec966af7f23531121d198e27a0098589e93ab`.
The repacked JSON archive's SHA-256 is `3f5dbe2871a827fec66e68a3b8d837695c20decb67a4e029411f610b1b55728f`.
Both identities are retained in the provenance file; the archive preserves every
UTF-8 file from the original ZIP, so evidence remains available after CI artifact
retention expires.

## Preliminary local evidence

[Local provenance](local/provenance.json) and its
[retained archive](local/evidence.json.gz) contain the four successful local
Swift 6.3.2 regression runs plus an allocation run that stopped on ENOSPC after
60 of 72 records. The latter has an explicit `aborted.json`, a truncated original
summary, and no completion marker. It is supplementary, not the source of the
published performance conclusions. Local uninstrumented timing was not run.

## Native status

The macOS job in the same workflow was still queued when this evidence was
prepared. A queued job is not a native qualification result. Live UI/playback
was not exercised by this component harness.
