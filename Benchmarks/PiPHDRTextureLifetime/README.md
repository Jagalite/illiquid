# PiP HDR texture lifetime experiment

Measures the HDR compositor's directly retained Metal working texture after
Picture in Picture stops. See the
[research report](../../Documentation/PIP_HDR_TEXTURE_LIFETIME.md) for the ownership
argument, results, and limitations.

## Run

Use macOS 26, the repository's pinned Xcode/native SDK and resolved dependencies.
On a workstation where Kyoto is available, submit the entire experiment through
the shared queue, then inspect its job status and logs:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/PiPHDRTextureLifetime/run.py \
  --pairs 3 --output /absolute/path/to/new-results-directory
```

If Kyoto is unavailable, run the same Python experiment command directly.
It compiles the baseline and candidate serially, each in a separate scratch
directory. The output directory must not already exist.

The GitHub workflow checks that Kyoto is absent before direct builds on its
ephemeral macOS runner. It installs the pinned native SDK and runs both the
ownership comparison and the existing native PiP regression suites.

## Comparison

`instrumentation.json` pins the old production source and adds observation-only
accessors plus a one-shot completion gate. The candidate uses identical hooks.
The driver checks the exact source difference before compilation, saves both
variants and the diffs, then validates every native result.

Four workloads cover 64×32 PQ, 1920×1080 PQ, 3840×2160 PQ, and 3840×2160 HLG.
Three alternating pairs produce 24 measured process executions; the two build
probes are separate. All returned visible P010 planes are hashed, excluding row
padding, and output color tags must match before stop, after stop, and after
paused reentry.

Important output files:

- `summary.json`: verified per-workload ownership results.
- `observations.jsonl`: all native measurements.
- `source-receipt.json`, `environment.json`, `commands.json`: exact inputs and execution.
- `sources/`, `baseline-instrumentation.diff`, `retirement.diff`: reproducible source comparison.
- `regressions.json` and native logs: executed regression results.

The measurements report logical pixel bytes, Metal's allocation size, and weak
object lifetime. They are not RSS, physical-footprint, latency, or FPS results.
