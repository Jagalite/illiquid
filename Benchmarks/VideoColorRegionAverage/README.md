# Video color region averaging

The adaptive text UI asks VideoColorSample for overall, leading, bottom, and
local averages. average() already clamps its rectangle bounds, but then calls
the public point lookup for every visited cell, clamping those coordinates again.

This candidate indexes the validated region directly, computing each row offset
once. It preserves the original row-major accumulation and division order and
keeps the public point lookup's clamping behavior. Reversed bounds still collapse
at the clamped minimum; they are not swapped. There is no added cache or storage.

## Reproduce

Use Swift 6 and Python 3.10+, with a fresh output directory:

~~~sh
python3 Benchmarks/VideoColorRegionAverage/run.py \
  --output /tmp/illiquid-color-regions --pairs 8 --target-ms 150
~~~

Use --tests-only for correctness checks without timings. Follow AGENTS.md and
submit the entire command through Kyoto on a host where that queue is available.
The isolated GitHub-hosted jobs explain its absence and build sequentially.

Both variants compile the complete VideoColorSample.swift as a separate dynamic
module. The driver is compiled separately without cross-module optimization.
The frozen baseline is verified against its recorded Git blob. Every source,
binary, command, compiler version, test log and raw observation is retained.

Seven independent regression tests run against baseline and candidate in debug
and release. They cover 10,000 deterministic rectangles across several shapes,
extreme and reversed coordinates, one-row/one-column samples, exact summation,
input clamping, UI regions, and public point lookup. Separate differential
receipts compare all Double bit patterns for 16,408 region results per build.

The ten timing cases use the actual production 12-by-8 grid: overall, leading,
bottom, local interior/edge, one cell, clipped and reversed rectangles, a
four-region palette workload, and an unchanged point-lookup control. Data setup,
warmup, process startup and output are outside timing. Every fresh-process pair
uses equal iterations and matching consumed output. AB/BA order balances across
eight pairs while workload order rotates. Wall and process CPU time are retained;
correctness tests impose no timing threshold.

These are component measurements, not measurements of visible UI latency,
decoding, playback FPS, energy or total application CPU. No larger grids are used
to inflate the measured result. Native and Linux results are reported separately.

## Results

Pending measurement. A PR will be opened only if the experiment establishes a
useful improvement while preserving correctness.
