# Portable qualification receipts

Extracted without changing numerical values from the completed GitHub job log:

- Run: https://github.com/Jagalite/illiquid/actions/runs/40637410006
- Job: https://github.com/Jagalite/illiquid/actions/runs/40637410006/job/122647455578
- Tested commit: `a2237e438ce68e85c6c522b746ec57c27703105b`.
- Production change: identical to `1d358535eaba91ac342794c2219129df3f027e17`.
- Baseline: `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

`summary.json`, `receipts.json`, and `samples.jsonl` are the printed artifacts
with GitHub's per-line log timestamps removed. `tests.txt` contains result
excerpts in execution order: candidate debug, candidate release, baseline release.
The complete build/test logs and binaries were also uploaded by that run.

The Linux metric is the glibc allocator-in-use delta at the populated-map
checkpoint, including allocator caches. It is not a macOS or whole-player
measurement. See the parent research README for results, controls, and limits.
