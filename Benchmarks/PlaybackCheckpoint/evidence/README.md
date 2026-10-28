# Native checkpoint research evidence

Each cohort keeps its manifest, qualification outcome and timing summary as
readable JSON. `review-bundle.json.gz` permanently retains the exact review
bundle emitted by that GitHub Actions run: raw observations, calibration,
verification fingerprints, commands/return codes and all four test logs, along
with the same manifest and summaries. No samples were removed.

`exploratory-macos` belongs to the first candidate and eight 80 ms target pairs.
Its small-playlist control prompted a revision; those results are not final
candidate claims. The revised implementation's sixteen 200 ms target pairs
are still awaiting a native runner, so no final cohort is published here. See the
[research report](../../../Documentation/PLAYBACK_CHECKPOINT_PERFORMANCE.md)
for exact candidate commits, workflow runs, source hashes and interpretation.

To unpack a cohort into a new directory and independently recheck its ordered
observations and summaries, run from the repository root:

```sh
python3 - <<'PY'
import gzip, json
from pathlib import Path
source = Path('Benchmarks/PlaybackCheckpoint/evidence/exploratory-macos/review-bundle.json.gz')
output = Path('/tmp/illiquid-checkpoint-review')
output.mkdir()  # Refuse to overwrite existing evidence.
for name, text in json.loads(gzip.decompress(source.read_bytes())).items():
    relative = Path(name)
    assert not relative.is_absolute() and '..' not in relative.parts
    path = output / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
PY
python3 Benchmarks/PlaybackCheckpoint/run.py \
  --mode summarize --output /tmp/illiquid-checkpoint-review
```

This revalidation needs Python only. Executing the measured production Swift
components requires macOS and the toolchain described in the benchmark README.
The workflow artifact also retains full source snapshots and compressed exact
serialized outputs while GitHub's artifact retention period remains active.
