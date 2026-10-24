# Retained Linux evidence

This directory preserves the completed 2026-10-24 component experiment against
baseline `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`. The measured production
candidate is `597a53ef2c6e799486abf7e6b59aa13f86bad87e`; the manifest also freezes
the initially uncommitted Linux drivers by SHA-256 and source snapshot.

The experiment completed 216 observations, 108 balanced paired comparisons and
18 fixture/auxiliary-count groups. See the
[research report](../../../../Documentation/AUXILIARY_FONT_MEMORY_RESEARCH.md)
for results and the [benchmark README](../../README.md) for reproduction.

| Record | Contents |
| --- | --- |
| `observations.jsonl` | Every scalar process observation; no exclusions. |
| `pairs.json` | All baseline/candidate comparisons, including slower or worse secondary metrics. |
| `summary.json` | Medians, paired reductions and improved/worse pair counts for all 18 groups. |
| `completion.json` | Successful final counts and validation/hash equality flags. |
| `validation.json` | Complete normalized validation receipt for each group, including metadata, codec/extradata hashes, font hashes and packet-trace hashes/counts. |
| `manifest.json` | Platform, source adaptations, original/staged source hashes, driver/binary/library/header hashes and worktree provenance. |
| `fixture-manifest.json` | File hashes and exact attachment inventories for all six performance fixtures. |
| `native-build-receipt.json` | Verified FFmpeg 8.1.2 source/build, compiler, library/header hashes and successful runtime probe. |
| `toolchain-download.json` | Official Swift archive URL, size and measured SHA-256. |
| `independent-audit.json` | 3,460 independently reconstructed checks; zero failures. |
| `independent-audit.py` | Verbatim independent audit script used for that receipt. |
| `finalization.json` | Independent verification that final driver packaging only removes one extra trailing blank line; measured source is preserved verbatim in the archive. |
| `full-receipts.json.gz` | 509 text files: every final subprocess stdout/stderr, command, build log, exact original/staged source snapshot and driver. |
| `exploratory-receipts.json.gz` | Two earlier smoke cohorts, kept separate from final statistics. |
| `index.json` | Packaged-file byte counts and SHA-256 hashes, excluding the index itself. |

Compiled binaries, module caches and large generated fixtures are not committed.
Their hashes are recorded; fixture generation and native build commands are
preserved. The complete production source is available at the pinned commits.
The compressed records are deterministic gzip-compressed UTF-8 JSON. The full
bundle has `schema_version`, `scope` and `files` keys; `files` maps each relative
path to its exact text. The exploratory bundle has a `cohorts` map instead.

For example, inspect a final raw process receipt without extracting the bundle:

```python
import gzip
import json
from pathlib import Path

root = Path("Benchmarks/AuxiliaryAttachmentPolicy/evidence/linux")
bundle = json.loads(gzip.decompress((root / "full-receipts.json.gz").read_bytes()))
names = sorted(name for name in bundle["files"] if name.endswith(".stdout"))
print(names)
print(bundle["files"][names[0]])
```

The independent audit script retains its original absolute workspace and output
paths as evidence. Repeating its complete provenance audit requires the
referenced generated fixtures and build outputs, including binaries. On another
machine, use a copy with the root paths adjusted; the committed script hash
identifies the script that produced the retained audit. The report's packet
equivalence claim is based on complete trace hashes and counts, not a separately
performed second demux or independently stored per-packet payloads.

These files qualify the Linux FFmpeg-open/projection component only. They do not
represent executed macOS application, serialized-executor, native-seek,
real-font rendering or UI tests. Those require the separate native workflow.
