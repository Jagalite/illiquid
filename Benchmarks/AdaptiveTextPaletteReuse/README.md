# Reuse adaptive text legibility preparation

## Scope and hypothesis

`PlayerTextPalette.uncachedColors` used to initialize an
`AdaptiveTextLegibility` while resolving its primary foreground, then initialize
the same context again to calculate secondary and tertiary opacity. Each
initialization expands the sampled region into source, darkened, and lifted
backgrounds and calculates their luminances. The second initialization repeated
the region lookup and all of that immutable preparation.

The candidate prepares the local sample and context once, then passes them to
`resolvedComponents`. Hue-source lookup stays inside the component-cache miss
closure. The style cache still checks for a hit before preparing anything.
Color selection, contrast thresholds, opacity searches, cache keys, capacities,
previous-color history, reset behavior, and halo selection are unchanged.

This is separate from the earlier
[opacity-threshold optimization](../../Documentation/ADAPTIVE_TEXT_LEGIBILITY_PERFORMANCE.md).
Both sides of this experiment use that current optimized legibility algorithm.
The only production difference is context reuse in `PlayerTheme.swift`.

The expected benefit is lower CPU cost on uncached and new-revision style
calculations. A full style-cache hit does no context preparation. A
component-cache hit with a style miss already used only one context. Both are
included as controls. This does not establish a change in whole-player CPU,
frame rate, battery use, or rendered appearance.

## Reproduction

Follow the repository's `AGENTS.md` build coordination. If Kyoto is available,
submit the intended command through its shared queue. Otherwise use an isolated
checkout and serialize builds that share a build directory.

```sh
python3 Benchmarks/AdaptiveTextPaletteReuse/run.py \
  --tests-only --output /tmp/palette-reuse-tests

python3 Benchmarks/AdaptiveTextPaletteReuse/run.py \
  --output /tmp/palette-reuse-benchmark --rounds 6 --target-ms 100
```

On Linux, `--cpu N` pins measured child processes to an allowed logical CPU.
`--swiftc PATH` selects the compiler. Outputs must be empty directories.
`--receipts-only` compiles both variants and compares complete output receipts
without timing. `--cases` and `--kernels` permit small diagnostic runs; the final
cohort uses every predefined case and kernel.

For full native qualification, the dedicated workflow invokes:

```sh
bash Benchmarks/AdaptiveTextPaletteReuse/qualify-native.sh /tmp/palette-reuse-native
```

That runs baseline and candidate isolated tests in debug and release, the native
benchmark, and the actual application modules' adaptive-text test suites. The
native benchmark uses real SwiftUI `Color` values. The script uses the pinned
native dependencies already established by the repository.

## Source boundaries

The frozen baseline is `PlayerTheme.swift` from
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its SHA-256 is checked before every run.
The runner also verifies that all common supporting sources match that commit,
and that current `PlayerTheme.swift` differs only inside `PlayerTextPalette`.
The baseline source is preserved under `baseline/` so later changes cannot
silently redefine the comparison.

The harness extracts the actual theme, palettes, grid/contrast regions, style
and component caches, `PlayerTextPalette`, and `AdaptiveRainbowTextColor`
declarations. It compiles complete current `AdaptiveTextLegibility.swift`,
`VideoColorSample.swift`, and `PlaybackVideoColorStore.swift`. It calls the
production `colors` method rather than a handwritten copy of its call sequence.
All generated source bytes, compiler commands, flags, and binary hashes are
recorded.

On macOS these are real SwiftUI and AppKit declarations. Linux omits the unused
AppKit convenience accessors and provides `LinuxColor.swift`, a numeric value
stand-in for unavailable SwiftUI colors. Linux figures therefore describe an
adapted component, not native macOS UI performance. The palette, region,
legibility, and cache calculations are unchanged. Output comparisons are within
each platform; native resolved Float components are not compared to the Linux
stand-in's Double components.

## Cases and measured boundaries

There are 24 cases: 12 region/distribution combinations in rainbow and
monochrome modes. They cover one sample, 9-sample local regions, a 32-sample
leading region, a 24-sample bottom region, 96-sample overall regions, and a
224-sample letterbox stress case. Background distributions include bright,
dark, midgray, saturated, mixed, and varied colors. Each case cycles eight
deterministic input variants and all six production rainbow palettes.

| Kernel | Included work | Expected behavior |
| --- | --- | --- |
| `uncached` | Actual palette method without a store, region lookup, primary resolution, both opacity calculations, color construction, output consumption | Removes one duplicate context |
| `revision` | Store publication, revision invalidation, normal primary history lookup, complete style miss, output consumption | Removes one duplicate context |
| `hit` | Six prewarmed style keys, repeated style-cache lookup, output consumption | Unchanged control |
| `component_hit` | Publication, preseeded component-cache entry, style miss and opacity calculation, output consumption | One-context control |

Fixture generation, component-hit seed calculation, and cache prewarming occur
outside timing. The driver consumes all returned primary, secondary, tertiary,
and halo components plus halo radius. This checksum work is timed identically
on both sides; on native builds it includes SwiftUI color resolution. Keeping
the outputs observable prevents removal of work whose result is otherwise
unused. View rendering, decoding, and frame sampling are excluded.

Each workload is calibrated against the baseline, then both variants use the
same iteration count. Six fresh-process rounds alternate AB/BA order and rotate
the workload order. Both wall and process CPU time are retained, and every
pair must match measured and warmup checksums. Paired percentage changes are
summarized using their median; those percentages need not equal the ratio of
the two independently calculated timing medians. No timing outliers are
discarded. CPU affinity does not eliminate shared-host scheduling, frequency,
thermal, or allocator variability.

The current runner sets `SWIFT_DETERMINISTIC_HASHING=1` only in its child
processes, following [Swift's benchmark guidance](https://github.com/swiftlang/swift/blob/main/benchmark/README.md#deterministic-hashing-requirement).
This gives separately launched variants matching cache-key hashes and table
collision layouts. An untimed receipt records all 144 case/palette key hashes
and must match between executables. Production hashing is unchanged. The two
earlier randomized-hash cohorts remain in the evidence; their variable cache
controls motivated this correction. Fixed hashing controls one test layout and
does not establish performance for every production hash seed or eliminate
shared-host variability.

Before the final cohort, the intended acceptance criterion is a repeatable
reduction in the ordinary miss/revision paths, with exact output equivalence
and no demonstrated material regression in the controls. Small differences in
controls require interpretation against their run-to-run variability; this
research does not turn a noisy single measurement into a speed claim.

## Correctness

The same six `AdaptiveTextPaletteReuseTests` run against both representations
in debug and release. They retain the original two-context wrapper as a
reference and compare all four colors and halo radius exactly. Coverage includes
all modes and palettes, local/leading/bottom/overall regions, aligned and
clamped bounds, letterbox samples, prior-color history, ordinary and component
cache hits, cache overflow, source identity, generation resets, static themes,
and missing samples.

Separately, the two benchmark executables emit complete output-bit receipts for
deterministic sequences of normal misses, cache hits, source switches,
equal-counter source switches, reset generations, component hits, overflow, and
fallbacks. The runner requires byte-for-byte equality of those receipt streams.

## Evidence and results

Results, exact qualification status, and durable evidence are recorded in
[`RESULTS.md`](RESULTS.md). Reproduction outputs include source snapshots,
commands and logs, environment/compiler metadata, binary hashes, complete
receipts, calibration records, every raw timed observation, paired changes,
and summaries. The CI artifact additionally retains the native application
test log and tested revision.
