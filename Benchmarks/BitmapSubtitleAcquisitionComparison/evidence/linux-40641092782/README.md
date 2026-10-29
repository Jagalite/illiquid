# Qualified Linux comparison evidence

This directory preserves the successful common three-arm experiment from
[workflow 40641092782](https://github.com/Jagalite/illiquid/actions/runs/40641092782)
and [job 122659172327](https://github.com/Jagalite/illiquid/actions/runs/40641092782/job/122659172327).
The qualified study code is `fd50b1822cd388ecf587fb72ce6f6c893019cc2d`.
The [study README](../../README.md) explains the question, method, and results.

The host was Linux x86_64 (AMD EPYC 9V74), with Swift 6.3.2 and Ubuntu FFmpeg
`6.1.1-3ubuntu5`. This is acquisition-classification component evidence. It is
not macOS application, whole-player, allocation-count, or RSS qualification.

## Outcome

- Complete traces agree across all three arms for **605 cases**, including
  **221 authored expectations**: 148 true and 457 false outcomes per arm.
- All **15 release tests** executed and passed: the seven unchanged PR #128
  tests and eight unchanged PR #137 tests in separate generated packages.
- All **144 timed observations** and **49 calibration trials** are retained.
  Each workload used all six execution-order permutations exactly once.
- The shortest timed CPU observation was **253.573954 ms**; the shortest wall
  observation was **253.635124 ms**, both above the 60 ms floor.
- Raw-buffer borrowing was faster in all **48 CPU and 48 wall pairs against
  each other arm**. `Data(bytesNoCopy:)` was slower than copying in all 12 tiny
  pairs and faster in all 36 larger-packet pairs, on both clocks. Its tiny-case
  median CPU ratios were 5.42 for DVB and 5.57 for PGS.

The separate receipt audit recomputed all **672 numerical summary fields** and
checked every timed/calibration stdout hash and weighted checksum. It verified
all **33 frozen source records** against Git, equality of seven shared production
files, independent reconstruction of all **13 compiled-source hashes**, exact
driver/runner identity at the qualified commit, and both unchanged test sources
and their log hashes. The exact #137 helper and compiler conditionals were also
checked. This audit reanalyzed the same run; it was not another experiment or an
allocation profile.

## Receipt map

| Files | Purpose |
| --- | --- |
| [provenance.json](provenance.json) | Run/job/source identity, original bundle hash, per-file hashes, and audit inventory. |
| [completion.json](completion.json) | Successful component completion and explicit unqualified macOS status. |
| [summary.json](summary.json), [measurements.jsonl](measurements.jsonl), [calibration.json](calibration.json) | Normalized results and every original timed/calibration observation. |
| [parity.json](parity.json), [copying-trace.json](copying-trace.json), [raw_buffer-trace.json](raw_buffer-trace.json), [data_nocopy-trace.json](data_nocopy-trace.json) | Aggregate and complete per-case correctness outcomes. |
| [test-results.json](test-results.json), [raw_buffer-tests.log](raw_buffer-tests.log), [data_nocopy-tests.log](data_nocopy-tests.log) | Exact test-source identities, execution counts, and release build/test output. |
| [build-receipt.json](build-receipt.json), [input-manifest.json](input-manifest.json), [source-preparation.json](source-preparation.json), [commands.json](commands.json) | Source/extraction, compiler, library, binary, command, and stdout/stderr identities. |
| [copying/compile.log](copying/compile.log), [raw_buffer/compile.log](raw_buffer/compile.log), [data_nocopy/compile.log](data_nocopy/compile.log) | Complete compiler output for each benchmark executable. |

The readable receipt files are byte-for-byte copies of the 18 text members in
the original workflow bundle. Generated source trees, package build outputs,
compiler caches, and executables are not duplicated here; exact original inputs
are already retained in the study's [`frozen` directory](../../frozen/manifest.json).

## Exact original bundle

[`workflow-40641092782.bundle.json.gz`](workflow-40641092782.bundle.json.gz)
contains the original gzip-compressed JSON dictionary mapping receipt-relative
paths to their original text. It is **49,046 bytes**, retained without recompression.

SHA-256:

```text
a613f97cd8ab2d39138dc0885293910cbc4c167861ea62b42a07edbe6d7f7083
```

For example, inspect it without extracting executable files:

```sh
python3 - <<'PY'
from pathlib import Path
import gzip, hashlib, json
path = Path('workflow-40641092782.bundle.json.gz')
raw = path.read_bytes()
assert hashlib.sha256(raw).hexdigest() == 'a613f97cd8ab2d39138dc0885293910cbc4c167861ea62b42a07edbe6d7f7083'
files = json.loads(gzip.decompress(raw))
print(files['parity.json'])
print(files['summary.json'])
PY
```
