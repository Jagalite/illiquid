# Screenshot Core Image context reuse

## Question and decision criteria

`NativeScreenshot.png()` creates a Core Image context when converting the current
video frame into a PNG. The candidate reuses a context between screenshots. This
experiment measures the complete existing PNG path, including image conversion,
geometry, subtitle composition and PNG encoding, to determine whether avoiding
repeated context setup has a meaningful benefit.

Apple recommends [reusing Core Image contexts](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/CoreImaging/ci_performance/ci_performance.html)
and documents that [a context can render concurrently](https://developer.apple.com/documentation/coreimage/cicontext).
The candidate follows the existing thumbnail renderer's ownership pattern while
keeping the screenshot context lazy and `.cacheIntermediates` disabled.

Before measurement, the acceptance criteria are:

- Exact equality of decoded canonical RGBA pixels across the verification corpus.
- For warmed complete PNG captures, at least 10% lower median paired wall time
  **and** process CPU in at least two common 1080p cases, or at least 5 ms saved per
  capture, without persistent regressions greater than 5% in the other warmed
  workloads.
- Report first-use results separately, along with process memory observations.
- Native regression tests pass, including sequential and concurrent captures.

These are review criteria. CI does not fail on a timing percentage; it fails on
build errors, incorrect output, malformed evidence or failing regression tests.
The native qualification and its limitations are recorded in [RESULTS.md](RESULTS.md).

## Reproduce

On macOS with the required Xcode toolchain selected, from a checkout containing
baseline revision `7f9ba073394b77a908e0589447c6edc8d10b832c`:

```sh
python3 Benchmarks/ScreenshotContextReuse/run.py \
  --output /tmp/screenshot-context-results --pairs 6 --iterations 6
```

Use an empty/new output directory. `--prepare-only` stages and validates source
extraction without requiring Swift or claiming native compilation/execution.

The component benchmark uses only Apple frameworks. It does not download FFmpeg,
libass or other native dependencies. It compiles the complete production
`VideoPresentationGeometry.swift` and the verbatim `VideoAdjustmentState`
declaration into a minimal `IlliquidCore` module. The screenshot executable then
compiles the full `NativeScreenshot.swift`, full `SubtitleMemoryBudget.swift`,
verbatim `ASSRenderedRegion` and `PresentationError` declarations, and the same
`Harness.swift` for each variant. No replacement implementation is timed.

Baseline source comes from `git show` at the pinned revision. Candidate source
comes from the current working tree. The receipt records both revision and actual
input/staged-source SHA-256 hashes, so working-tree changes are identifiable.
Extraction fails if the production declaration boundaries change. Full application
regression tests run separately in native CI.

## Workloads and protocol

Five predeclared workloads cover BGRA 1080p, NV12 1080p, 10-bit P010 1080p, BGRA 4K,
and 1080p with subtitles. The 19-case verification corpus exercises the same pixel
formats at small and actual benchmark resolutions, plus geometry/subtitle cases.
Each variant decodes its generated
PNGs into a specified canonical RGBA representation. The runner compares every
output byte, decoded dimensions and color metadata, and records the output sizes
and SHA-256 values. This avoids treating
PNG encoder metadata or compression choices as image correctness.

For each workload, six pairs run in fresh processes, alternating baseline/candidate
then candidate/baseline: `ABBAABBAABBA`.

- **First use:** one complete capture with no screenshot warmup. Each process is
  new, but system and driver caches can remain warm across processes; this is not
  a cold-boot measurement.
- **Warmed:** two untimed captures initialize the path, followed by six timed
  complete captures. Each capture uses an autorelease pool. Fixture creation is
  outside the timer. The context is reused within the candidate process while the
  baseline creates its normal context on each call.

Both variants use the same iteration count and inputs. Raw observations retain
wall nanoseconds, process CPU nanoseconds, capture counts, PNG lengths, checksum,
process memory fields, pair and execution order. Timed PNG lengths/checksums must
match between variants; decoded image equality is established independently
before measurements. Summaries report normalized wall/CPU time per capture,
paired wall/CPU reductions, median/min/max values and memory observations.

The `maxrss_*` fields are Darwin peak resident-set size in bytes, sampled before
warmup, before timing and after timing. They include runtime and fixture costs;
they do not measure current post-capture residency or all GPU/device allocations.
Short-lived fresh processes cannot establish the long-term
memory residence of a shared Core Image context in a running player. Reusing that
context is a memory-lifetime tradeoff even if the observed RSS controls are flat.

## Evidence and limits

Outputs include `environment.json`, `receipt.json`, `verification.json`,
`measurements.jsonl`, `summary.json`, `completion.json`, compiler/verification logs,
the exact staged production declarations, driver/runner snapshots and decoded
RGBA verification files.
Executable hashes identify the measured builds. Raw observations retain the
complete run order; summaries use every recorded pair.

The measurement includes the entire synchronous `png()` component. It does not
measure the save panel, filesystem writing, interactive screenshot latency,
steady playback CPU, frame rate or battery use. Native regression tests and
decoded-output comparisons establish the stated behavior separately from timing.
