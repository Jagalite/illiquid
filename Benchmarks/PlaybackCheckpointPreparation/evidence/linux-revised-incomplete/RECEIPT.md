# Incomplete revised-vs-main checkpoint experiment

**This run failed. It is secondary historical evidence, not a completed
qualification or the incremental comparison against PR #124.**

The owning process (exec session 27940) exited with code 1 after `OSError:
[Errno 28] No space left on device`. The external run log also records failure
while trying to save the final manifest. The raw `manifest.json` is **zero
bytes**. The raw summary still says `running` and contains **41/58** workload
summaries; this is a stale checkpoint, not evidence the process is still alive.
`external-status.json` records the observed failure without changing either raw
file. There is no completed final source/binary guard receipt.

## Preserved material and limits

- **492 measured observations** and **225 calibration observations** are retained
  exactly as written before failure. No missing observations are invented.
- The command ledger has **743 complete records and a truncated 744th record**.
  The truncated bytes remain untouched in the archive.
- The four previously recorded baseline/candidate debug/release test runs each
  report 27 passing tests. The canonical verification files contain 58 matching
  full outputs. These earlier checks do not make the interrupted campaign pass.
- Timed all-unsupported-item cases were **not reached**. This partial campaign
  cannot qualify the revised unsupported-item fix.
- Every existing non-build source snapshot, log, command ledger, verification
  file, workload definition, calibration record, observation, summary, and empty
  manifest is retained byte for byte. The external
  `checkpoint-linux-revised.log` is included separately under `external/`.
- Build products, compiler caches, modules, libraries and binaries are omitted.
  The missing final binary hash/provenance manifest is not reconstructed.

The candidate source snapshots match commit
`3d01b46eced987a6e32285f9ac5425c76feb24eb`, tree
`e84619f1c33deb8bb24764e8c88e63ccf4a5112e`; the baseline was original main
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Snapshot correspondence was checked
at packaging time and is explicitly separate from the lost end-of-run guard.
The accepted eager-source cohort remains in `../linux-eager`. The direct
comparison against PR #124 is a separate experiment and must not be pooled with
these partial results.

## Reconstruct and verify

`evidence.tar.xz` uses deterministic tar headers and content-addressed blobs.
`INDEX.json` maps every logical path to its byte size, SHA-256 and blob member;
empty files are mapped too. Every reconstructed path was compared with the
original bytes. To reconstruct into a new `unpacked` directory:

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

The four top-level JSON/JSONL files are exact copies, including the empty raw
manifest. `SHA256SUMS` covers every delivered file except itself. Archive hashes,
counts and status are in `receipt.json` and `external-status.json`.
