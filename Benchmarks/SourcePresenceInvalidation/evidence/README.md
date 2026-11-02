# Retained evidence

The Linux folders are exploratory runs, not native macOS qualification or
end-to-end player measurements. Every timing observation is retained; no timing
samples were removed. Command receipts are compressed byte-for-byte as
`commands.jsonl.gz`.

- `guard-exploration-linux`: the discarded candidate only guarded the summary
  filter. It used two timing pairs and skipped unit tests; the complete scanner
  was compiled in debug and release and differential output checks passed.
  Mixed, noisy timings did not justify selecting that candidate. Its exact
  compiled source snapshot is retained.
- `ancestor-exploration-linux`: the selected production change, with two timing
  pairs. All 26 unit tests passed in each baseline/candidate debug/release build,
  and exact differential output checks passed. Its iteration limits and runner
  snapshot predate the final native runner's independent calibration. These
  short local samples established a promising direction, not precise native
  effect sizes.

The guard run's duplicate full trace archive is omitted. All 28 of its traces
match the corresponding traces in `ancestor-exploration-linux/state-traces.json.gz`.
For the two burst traces, replace `active-burst-1000-16` with
`queued-burst-1000-16` in the trace key and its `case` value before comparison.
That rename corrected the description: the worker was queued, not performing
I/O during timing. The guard run's original trace hashes remain in its validation
receipt; its retained compiled sources reproduce the original spelling.

Toolchain, machine, exact compiled-source and executable hashes, original
commands, calibration decisions, timing boundaries, and completion status are
recorded within each folder. Test/build logs document what actually ran.

## Reproduce the omitted guard trace in memory

The [reuse manifest](guard-exploration-linux/state-traces-reuse.json) records the
source archive, original key inventory, two case-name substitutions, and original
compressed and uncompressed hashes. The derivation reproduced the omitted
archive byte-for-byte with Python 3.12.14 and zlib 1.3.2. The canonical JSON hash
verifies the trace independently of Python/zlib differences in gzip encoding.
From the repository root, this snippet checks that portable invariant, reports
whether the current gzip encoding also matches, and writes no archive:

```python
import gzip
import hashlib
import json
from pathlib import Path

folder = Path("Benchmarks/SourcePresenceInvalidation/evidence/guard-exploration-linux")
receipt = json.loads((folder / "state-traces-reuse.json").read_text())

def sha(data):
    return hashlib.sha256(data).hexdigest()

source_bytes = (folder / receipt["source"]["path"]).read_bytes()
inventory_bytes = (folder / receipt["keyInventory"]["path"]).read_bytes()
assert sha(source_bytes) == receipt["source"]["sha256"]
assert sha(inventory_bytes) == receipt["keyInventory"]["sha256"]
source = json.loads(gzip.decompress(source_bytes))
validation = json.loads(inventory_bytes)
keys = set(validation["baseline-debug"]["traces"])
assert len(keys) == receipt["keyInventory"]["count"]
assert all(set(build["traces"]) == keys for build in validation.values())

reconstructed = {}
for key in keys:
    ownership, original_case = key.split("/", 1)
    source_case = receipt["caseNameMapping"].get(original_case, original_case)
    trace = dict(source[f"{ownership}/{source_case}"])
    assert trace["case"] == source_case
    trace["case"] = original_case
    reconstructed[key] = trace

canonical = json.dumps(
    reconstructed, sort_keys=True, ensure_ascii=True, separators=(",", ":")
).encode("utf-8")
assert len(canonical) == receipt["original"]["canonicalJSONBytes"]
assert sha(canonical) == receipt["original"]["canonicalJSONSHA256"]
print("Verified canonical guard trace SHA256:", sha(canonical))
compressed = gzip.compress(canonical, compresslevel=9, mtime=0)
print("Current gzip encoding matches captured archive:",
      sha(compressed) == receipt["original"]["sha256"])
```
