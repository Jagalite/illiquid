# Compare bitmap subtitle acquisition borrowing strategies

This is an independent Linux component study of three alternative implementations
of the same PGS/DVB acquisition check. It changes no application source or
application test target. Results are pending execution; source preparation alone
does not establish compilation, correctness, or a speedup.

| Arm | Pinned production revision | Strategy |
| --- | --- | --- |
| `copying` | `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` | Original `packet.data` getter followed by the existing `Data` parsers. |
| `raw_buffer` | `aa71f1df6045ef35301fb0a95518b571f02f23b7` | [PR #128](https://github.com/Jagalite/illiquid/pull/128): synchronous packet borrowing through `UnsafeBufferPointer`. |
| `data_nocopy` | `6275059f54fc9ec52873fb7d223ad6f598fd0c47` | [PR #137](https://github.com/Jagalite/illiquid/pull/137): scoped `Data(bytesNoCopy:count:deallocator: .none)` with the existing parsers. |

The two proposals remove the same explicit whole-payload copying getter at the
same seek-reconstruction call site. They are alternatives, not additive fixes.
Measurements from their earlier studies are not pooled into this experiment.

## Source identity and Linux boundary

`frozen/manifest.json` identifies every source revision, original full-file hash,
snapshot hash, and extraction byte range. `freeze_inputs.py` regenerates these
snapshots from the exact commits and refuses to replace differing frozen bytes.
The runner verifies all snapshots against the manifest and compares them with
their Git objects when those objects are available. Frozen bytes remain usable
if the original branches are later removed.

Both borrowing arms use their actual PR production code. The complete shared
`FFmpegPacket`, queue, ring-buffer, error, and timing files are frozen and identical
across the three source revisions. The classifier prefixes and raw-buffer packet
adapters are exact production declarations. For the third arm, the runner places
the exact static helper inside its original `FFmpegDemuxer` type declaration;
only the enclosing closing brace and separating whitespace are assembled.

The Linux build uses real Swift Foundation and real FFmpeg. It removes the unused
`CoreGraphics` import, selects the exact `FFmpegRational` and `MediaTime.seconds`
declarations instead of unused CoreMedia methods, and exposes the required exact
production C helpers through actual FFmpeg headers. No packet owner, FFmpeg API,
or platform type is replaced with a stub. These exclusions mean the study does
not build the macOS application or validate its native decoding/presentation graph.

## Correctness and timing protocol

The common driver preserves the corpus and measurement statements from the
independently prepared two-arm study at `2441293b7d84de9b32ea807cbd3ed739bec9ce57`;
its corpus suffix hash is frozen. Only the call-site adapter selects a strategy.
All three executables must produce identical complete traces across **605 cases**,
including **221 authored expected outcomes**. The corpus covers malformed input,
truncations, acquisition state bits, DVB page selection, maximal segment lengths,
missing/nonpositive payloads, and deterministic mutations.

The runner also executes PR #128's **seven unchanged tests** and PR #137's **eight
unchanged tests**, in separate generated release SwiftPM packages. These tests
exercise actual FFmpeg packet ownership and bounds without adding targets or
files to the application's test graph. Swift 6.3 or newer is required to preserve
PR #128's `weak let` test verbatim.

Eight workloads cover tiny PGS/DVB controls and each codec at approximately 4,
64, and 256 KiB. Every workload rotates sixteen preallocated real packets and
mixes positive and negative outcomes; large packets put acquisition first, last,
or omit an accepted acquisition. Object contents are synthetic with legal segment
framing and are not claimed to decode to subtitle pixels.

Each executable calibrates complete cycles of that identical distribution toward
240 ms. Six triplets use all six variant-order permutations: each arm occupies
each position twice, and each pair occurs in both relative orders equally often.
Every timed observation runs in a fresh process after fixture allocation,
validation, and warmup. Non-inlined adapters and an emitted checksum consume every
result. Both CPU and monotonic wall durations must reach 60 ms. No samples are
discarded. The default cohort contains **144 timed observations** plus retained
calibration trials; prior experiments are not reused as samples.

`summary.json` reports each arm's median and range in ns/check, plus normalized
ratios paired within each triplet for all three comparisons. A reduction is
`100 * (1 - median_paired_ratio)`. Timings include the common packet rotation,
adapter, and checksum overhead. Source, compiler, library, binary, test-log,
and command identities are retained with the raw observations.

## Reproduce

Use Linux, Swift **6.3+**, Python 3, Git, pkg-config, and the actual
`libavcodec-dev`/`libavutil-dev` libraries. Follow the repository's build
coordination guidance in [`AGENTS.md`](../../AGENTS.md). The hosted workflow
reports Kyoto's absence and runs builds sequentially. Each output directory must
be new or empty.

```sh
python3 Benchmarks/BitmapSubtitleAcquisitionComparison/run.py \
  --triplets 6 --target-ms 240 --minimum-ms 60 \
  --output /tmp/bitmap-subtitle-acquisition-comparison
```

`--prepare-only` audits and assembles sources without a compiler, sets
`complete: false`, and makes no execution claim. A successful full run emits
`completion.json`, `parity.json`, `test-results.json`, `summary.json`, every raw
measurement, calibration trials, source snapshots, and build/test receipts.
Triplet counts must be multiples of six to preserve order balance.

## Interpretation limits

The study measures Linux acquisition-classification time. It does not measure
allocation counts, peak/live memory, RSS, full seek latency, player CPU, decoding,
rendering, FPS, energy, or live UI behavior. `Data(bytesNoCopy:)` names an API
strategy; it does not prove zero allocation or universally zero copying for every
Foundation representation. Tiny `Data` values may use inline storage. Neither
borrowing strategy changes the retained reconstruction packet set. Native macOS
qualification remains separate, and its results cannot be inferred from this run.
