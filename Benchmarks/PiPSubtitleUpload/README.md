# PiP subtitle upload reuse

This experiment measures the native Metal resource work repeated while a PiP
caption stays unchanged. It compiles the production `PiPSubtitleUploadCache.swift`
as a separate optimized module and compares it with the actual prior upload and
vertex construction code from commit
`68274d1b09dcc866296321a5a8858efc297c4f19`.

Run on macOS 26 with the project's Xcode toolchain and that commit available in
Git history:

```bash
python3 Benchmarks/PiPSubtitleUpload/run.py --output /tmp/pip-subtitle-upload-results
```

The output must be new or empty. `--verify-only` performs the native resource and
rendered-pixel checks without timing. The runner requires Python 3 and a real
Metal device; it intentionally refuses Linux. It opens no media or application
and does not change user preferences.

`--prepare-only` may run on another host to inspect generated source and its
hash receipts. It compiles or executes nothing and does not establish native
correctness or performance.

## What is compiled

The candidate helper is copied byte for byte. The baseline retains the exact
block in `encodeSubtitles` before its render pass, the exact `SubtitleVertex`
declaration, and the exact `subtitleVertices` method. An immediately invoked
throwing Void closure preserves the old block's empty-frame return; a small
adapter returns the same resource and counter interface as the candidate. The
baseline's invalidation method does nothing because the old implementation
uploaded on every call. No replacement uploader stands in for the baseline.

Both modules use `-O -whole-module-optimization -swift-version 6` with warnings
treated as errors. A separately compiled harness imports the internal API using
`-enable-testing`; it cannot inline or delete the production resource calls.
Four shared prepared-frame declarations are extracted unchanged from production
and checked against the pinned baseline. The two used error cases have a narrow
standalone declaration because the full compositor error type depends on the
rest of the application.

## Correctness

Separate fresh processes exercise 18 transitions, including repeated unchanged
captions, same-size changed pixels, geometry and viewport changes, growth and
shrinkage of textures and quad buffers, R8/BGRA and bitmap-atlas changes, padded
source rows, an empty-caption invalidation, and source retirement.

Every nonempty step reads back the active texture and checks all bytes against
the input. Baseline and candidate must return byte-identical vertex buffers and
the same resource capacities. They also render with the exact extracted PiP
subtitle vertex and fragment shaders, using the production SDR blending and
sampler configuration, and must produce byte-identical rendered images. GPU
commands complete before another step can overwrite shared upload resources.
Unchanged-frame resource identity and upload counters are asserted separately.
An empty caption skips upload/draw, matching the compositor's call boundary.

The draw verification uses a black background and checks the helper's resources
with the production SDR shaders. Full playback, HDR/PiP routing, and compositor
invalidation integration remain covered by the app's native tests.

## Timing

Eight workloads cover R8 atlases of 64 KiB, 1 MiB and 4 MiB, plus a 1 MiB BGRA
control. Each size has an unchanged-caption case and a case invalidated on every
call with alternating pixels and geometry. Frames and resource capacity are
prepared before timing. The unchanged case therefore measures an already
uploaded caption reused for subsequent video frames. The changed case includes
the invalidation call and real texture replacement and vertex copying.

Each workload gets seven AB+BA pairs by default: 14 fresh process observations
per variant. Workload order rotates; each workload has equal baseline-first and
candidate-first observations. Calibration is excluded from the accepted cohort
and selects an even, fixed iteration count independently for each variant and
workload, targeting 80 ms of process CPU time. This keeps the cached fast path
measurable without forcing very long copies in the 4 MiB baseline. Results are
normalized by calls; counts and raw CPU/wall durations remain in every receipt.

The measured interval contains calls to the upload helper and collection of its
returned counters. It performs **zero GPU draws**. Exact active texture/vertex
checks occur after timing. The verification phase counts its actual draws
separately. These are synchronous component service costs, not whole-player CPU,
frame latency, memory footprint, energy, or GPU rendering savings.

## Evidence

- `source-receipt.json`: pinned baseline, extracted block/type/shader hashes,
  candidate source hash, compiler commands, module and executable hashes.
- `environment.json`: compiler, Xcode, OS, hardware, source revision and scope.
- `verification-*.json` and `verification.json`: exact resource/render receipts,
  upload counters, transition coverage and equality decision.
- `calibration.json` and `iteration-counts.json`: excluded probe results and the
  fixed normalization counts.
- `measurements.jsonl`: every accepted fresh-process result in actual run order.
- `summary.json`: median and range in ns/call, changes, and individual paired
  ratios for CPU and wall time.
- `validation.json`: completed cohort, uniqueness/order checks, equality status,
  and shortest accepted process CPU interval.
- `commands.jsonl`: all commands, exit codes, standard output and errors.

Failed runs retain their outputs and do not produce a successful final
validation file. No performance threshold is asserted: inspect the changed
caption controls and ranges before drawing conclusions.
