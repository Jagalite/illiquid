# Initial lazy-loop comparison against PR #124

This completed component experiment compares measured local candidate
`5d532aa4b877e47db23b9ba59972aa3f30f71def` against PR #124 at
`9f21c84bbe097984642c8fc08b7c8c1fd31a6c41`. The fetched published candidate
`b0416ee6b1c07af2424230b281b59f22743fc5df` has the identical tree:
`64915e0f2a25c11d38250671ce39c6e7e9cace20`. The packager verified candidate production, harness,
runner and test snapshots directly against both local and published commits;
baseline production snapshots were verified against the pinned PR #124 commit.
The raw manifest identifies the measured local commit directly.

This directory preserves the measured lazy-loop candidate. Earlier main-based
experiments have separate evidence directories; their observations must not be
pooled with this cohort. The subsequently reviewed two-phase variant was
unmeasured and discarded.

## Preserved cohort

- Four successful baseline/candidate debug/release test runs, reporting
  37 tests per run.
- **10 workloads**, six balanced AB/BA pairs per workload, and **120
  fresh-process measured observations**.
- **52 calibration observations**, kept separately from the measured summaries.
- **58 complete canonical session-output comparisons**, byte-identical between
  baseline and candidate.
- The runner's completed final source/binary guard receipt is retained. Every
  included command stdout/stderr hash, paired semantic result and alternating
  pair order was independently checked during packaging.

The top-level observations, summary, manifest and calibration files are exact
copies from the completed run. The archive retains every non-build log,
command receipt, source snapshot, verification output, workload definition,
calibration record, observation, summary and manifest. Build products and
binaries are omitted; their original hashes and explicit omission map remain
in the receipts.

These are **Linux Swift component measurements**, not macOS/full-application or
live UI qualification. Earlier eager-source and interrupted revised-vs-main
campaigns are historical evidence and must not be pooled into this direct
comparison against PR #124.

## Reconstruct and verify

`evidence.tar.xz` uses deterministic tar headers and content-addressed blobs.
`INDEX.json` maps every logical path to its byte size, SHA-256 and blob member;
empty files are retained too. Every reconstructed path was compared with its
original bytes. This example writes a new `unpacked` directory:

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

`SHA256SUMS` covers every delivered file except itself. `receipt.json` records
archive hashes, cohort counts, source correspondence and omissions.
