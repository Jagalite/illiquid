# Superseded eager-source checkpoint experiment

This directory preserves the original eager-source candidate, commit
`0a49d55a79b2163e5a2c8fc730ab17a809da72cc`, against baseline
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. The measured sources also equal
local commit `305731d` (both trees are `b8c23c18cbef8d5e4f23542c52b78057a973682b`).
Original manifests were captured before the candidate commit and therefore
record the baseline HEAD plus worktree changes; `receipt.json` records the
independent postcommit source/hash verification.

This is historical evidence. Eager target normalization regressed the
all-unsupported-item singleton control. The later lazy-source candidate has
a separate cohort. Do not pool the two implementations or substitute these
results for the revised implementation. No adverse observations were removed.

## Preserved cohorts

- `full/`: 58 workloads, six balanced AB/BA pairs per workload, 696 fresh-process
  observations, and 308 retained calibration observations. Both variants passed
  all 58 complete canonical session-output comparisons. This campaign used
  `--skip-tests` after the matching smoke/test run.
- `smoke-tests/`: four successful baseline/candidate debug/release test runs,
  each reporting 27 tests; 50 short smoke workloads with two balanced pairs
  (200 observations), plus 260 calibration observations. All 58 complete
  output comparisons also matched. These short timings remain separate.

The four top-level JSON/JSONL files are byte-exact copies from `full/`. The
archive also retains all non-build logs, command receipts, source snapshots,
verification outputs, workload definitions, calibration, raw observations,
summaries and manifests from both cohorts. Builds and binary files are omitted;
their hashes and the explicit omission list remain in the receipts.

## Reconstruct and verify

`evidence.tar.xz` uses deterministic tar headers and content-addressed blobs to
avoid duplicate source and verification storage. `INDEX.json` maps **every
logical path** to its byte size, SHA-256, and blob member. Empty files are retained
as mappings too. The packaging check reconstructed and compared every mapping
with its original bytes. The following example writes a fresh `unpacked` folder:

```python
import hashlib, json, pathlib, tarfile

root = pathlib.Path("unpacked")
root.mkdir(exist_ok=False)
with tarfile.open("evidence.tar.xz", "r:xz") as archive:
    index = json.load(archive.extractfile("INDEX.json"))
    for relative, entry in index["files"].items():
        path = pathlib.PurePosixPath(relative)
        assert not path.is_absolute() and ".." not in path.parts
        raw = archive.extractfile(entry["blob"]).read()
        assert len(raw) == entry["bytes"]
        assert hashlib.sha256(raw).hexdigest() == entry["sha256"]
        target = root.joinpath(*path.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
```

`SHA256SUMS` covers every delivered evidence file except itself. `receipt.json`
records the archive hashes, cohort counts, source correspondence, and omissions.

## Initial failed sandbox build

`sandbox-build-failure.tar.xz` is a separate, directly addressed archive of the
initial failed attempt's original manifest, summary, command ledger, and failed
test-command stdout/stderr, plus its own path/hash index. Compilation terminated
with signal 4 before any completed test run or benchmark measurement. The logs
do not by themselves establish the cause. This failure is excluded from both
accepted cohorts above and is not a performance observation.
