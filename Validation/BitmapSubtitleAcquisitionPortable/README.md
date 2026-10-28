# Optional supplementary Linux probe

This scratch-only probe compares baseline `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`
and candidate `2441293b7d84de9b32ea807cbd3ed739bec9ce57` using actual Swift,
Foundation, and FFmpeg. The native macOS workflow remains the qualification gate.

If selected, place `run.py` at `Validation/BitmapSubtitleAcquisitionPortable/run.py`
and `workflow.yml` at `.github/workflows/bitmap-subtitle-acquisition-portable.yml`
on the isolated `validation/bitmap-subtitle-acquisition-linux-20261028` branch.
No changes to the original native branch are required.

The runner reads every production input from the fixed Git commits. It reuses the
exact pinned native runner's verification, calibration, and measurement methods.
Its eight candidate ownership tests are the unchanged production test file.
It retains the complete `FFmpegPacket`, error, queue, and ring-buffer sources.
The receipt lists every omitted Apple import/declaration and records the actual
selected production code, generated C bridge, source hashes, and linked versions.
There are no fake platform types or translated parsers.

Only source preparation can be checked in the current environment:

```sh
python3 run.py --repository /path/to/illiquid --output /new/output --prepare-only
```

That mode explicitly reports `complete: false` and never claims compilation or
test execution. Without `--prepare-only`, the runner requires Linux with Swift
6.1+, Python, pkg-config, and actual FFmpeg development libraries; it executes
frozen-baseline parity, all eight release tests, and eight balanced timing pairs
per workload. Linux timing does not establish Apple Foundation allocation costs,
whole-player memory savings, or native seek latency.
