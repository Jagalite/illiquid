# Native qualification evidence — October 24, 2026

**Outcome: withhold a production PR.** Live malloc ownership decreases, while
retained RSS and physical footprint increase in every 16/64 MiB paired case.
Native debug and release regressions pass with the explicit skips recorded here.
See the [research report](../../../../Documentation/AUXILIARY_FONT_ATTACHMENT_MEMORY.md).

Measured candidate: `979bdd34a93af1c564d505b1b6a4f6b12de27379`.
Baseline: `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.
[CI run](https://github.com/Jagalite/illiquid/actions/runs/40101300598) /
[job log](https://github.com/Jagalite/illiquid/actions/runs/40101300598/job/120893823744).

| File | Contents |
| --- | --- |
| `summary.json` | Every scenario and metric; all observed paired ranges. |
| `manifest.json` | Source/compiler/library hashes, pinned revisions, host and protocol. |
| `independent-audit.json` | Recomputed summaries, provenance checks, individual adverse pairs, controls and limitations. |
| `native-evidence.json.xz` | Exact lossless bundle: raw observations, parity, fixtures, commands, manifest and summary. |
| `archive-receipt.json` | Original gzip, decoded-content and XZ checksums. |
| `native-test-summary.json` | Separate debug/release results and explicit skipped test names. |
| `tests-debug.log.gz`, `tests-release.log.gz` | Native build/test log sections, including every assertion outcome. |

The original CI gzip bundle checksum was verified before its exact decompressed
JSON bytes were repacked with XZ. This reduces archive size without selecting,
rounding, or removing observations. The bundle contains **228 observations** and
**396 reader receipts**. Readable manifest/summary copies match their archived
versions exactly. The native test logs are separate from the measurement bundle.

## Verify and unpack

From the repository root, using Python's standard library:

```sh
python3 - <<'PYCODE'
from pathlib import Path
import hashlib, json, lzma
source = Path('Benchmarks/AuxiliaryFontAttachments/evidence/native-20261024')
receipt = json.loads((source / 'archive-receipt.json').read_text())
packed = (source / 'native-evidence.json.xz').read_bytes()
assert hashlib.sha256(packed).hexdigest() == receipt['xz_sha256']
raw = lzma.decompress(packed)
assert hashlib.sha256(raw).hexdigest() == receipt['uncompressed_bundle_sha256']
files = json.loads(raw)
assert set(files) == {'manifest.json', 'summary.json', 'observations.jsonl',
                      'parity.json', 'fixtures.json', 'commands.json'}
target = Path('/tmp/illiquid-font-observations')
target.mkdir(exist_ok=False)
for name, content in files.items():
    (target / name).write_text(content)
print(target)
PYCODE
```

The after-release memory sample follows variant-dependent font hashing and
receipt construction. It supports lifetime inspection alongside the weak-owner
checks; it is not a production teardown benchmark. Do not use it to claim
post-close memory savings.
