# Font copies in auxiliary media inputs

## Qualification outcome

The native experiment reduces live malloc ownership but increases retained
resident memory and physical footprint in all 36 paired comparisons involving
16/64 MiB font fixtures. Opening-time results are mixed. Debug and release
regression checks pass. This candidate is retained for research; a production
memory-performance PR is withheld. See the
[complete findings](../../Documentation/AUXILIARY_FONT_ATTACHMENT_MEMORY.md)
and [archived evidence](evidence/native-20261024).

## Candidate

Illiquid's primary input supplies embedded fonts to the main and Picture in
Picture subtitle pipelines. Before this change, every additional demuxer also
copied supported font attachments into Swift `Data`, even when the reader used
only packets, codec parameters or stream timing. The separate embedded-subtitle
input, delayed-audio input and cached thumbnail decoder could therefore retain
additional copies of the same font payloads.

The new `includeFontAttachments` initialization option defaults to `true` in both
`FFmpegDemuxer` and `FFmpegInputExecutor`. Auxiliary callers explicitly pass
`false`. Only the owning Swift attachment projection is omitted: all stream
descriptors, selected tracks, chapters, timing, codec parameters and packet
behavior remain available. The primary input and diagnostic defaults preserve
their existing attachment behavior and font admission limits.

FFmpeg continues to read and own the container's attachment extradata. This
change does not remove that native storage, the primary Swift copy, or libass's
registered fonts.

## Reproduce on macOS

Use the repository's pinned native SDK and Xcode selection, as in
`.github/workflows/auxiliary-font-attachments.yml`. The pinned baseline commit
must be available in the local Git object database:
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`.

```sh
python3 Benchmarks/AuxiliaryFontAttachments/generate-fixtures.py \
  --output /tmp/auxiliary-font-fixtures
python3 Benchmarks/AuxiliaryFontAttachments/run.py \
  --fixtures /tmp/auxiliary-font-fixtures \
  --output /tmp/auxiliary-font-results --pairs 6
ILLIQUID_AUXILIARY_FONT_FIXTURES=/tmp/auxiliary-font-fixtures \
  swift test --force-resolved-versions --no-parallel \
    --filter AuxiliaryFontAttachmentTests
```

Use new or empty fixture and results directories. The benchmark accepts
`--ffmpeg-prefix` and `--swiftc` for explicit native toolchain selection. It
requires macOS; syntax checks on Linux are not native execution evidence.
When the repository's shared Kyoto queue is available, submit the benchmark
and Swift test commands through that queue as described in `AGENTS.md`. The
hosted workflow uses an isolated runner and executes its builds sequentially.

## Workloads and controls

The generator creates short video/audio/ASS Matroska files with six attachment
inventories: no attachments, 2 MiB of fonts, 16 MiB of fonts, 64 MiB of fonts,
unsupported attachments only, and mixed font/non-font attachments. Large font
payloads are dense deterministic bytes labeled as supported fonts. They test
copying and ownership, not font parsing or visual subtitle quality. The 64 MiB
stress case matches the aggregate font budget for successful subtitle-pipeline
configuration, split into individually admitted font sizes. That budget does
not bound raw demuxer allocations before subtitle validation.

Nineteen scenarios exercise the complete production demuxer and executor:

| Reader layout | Backend | Fixtures |
| --- | --- | --- |
| One auxiliary reader | Direct demuxer | All six |
| Primary plus one auxiliary | Serialized executor | All six |
| Primary plus two auxiliaries | Serialized executor | No attachments; 2, 16 and 64 MiB fonts |
| Primary only, unchanged default | Direct demuxer | No attachments; 2 and 16 MiB fonts |

The multi-input layouts represent input ownership in sessions with embedded
subtitles and, optionally, nonzero audio delay. They instantiate those input
objects without a full player, decoders or renderers. The one-auxiliary layout
models the extra demuxer retained by a thumbnail decoder or opened by a probe.

## Measurement method

The runner compiles complete, unmodified production source files from the
pinned baseline and candidate into separate optimized modules. Small required
presentation-error and bitmap packet declarations are extracted verbatim from
their production files. The benchmark driver uses `BASELINE` only to call the
older initializer without the new argument; candidate auxiliaries opt out, and
candidate primaries use the default initializer.

Each observation runs in a fresh process. The default six pairs alternate
baseline/candidate and candidate/baseline order; scenario order also reverses
on alternate pairs. All 228 observations are retained, including adverse
controls. There is no sample selection or timing calibration. Open time is a
secondary, single-operation measurement and may be noisy for small controls.

The driver records memory before opening, while all designated input objects
are alive, and after their release. Live-memory samples precede metadata
serialization, payload hashing and packet validation. Metrics are:

- **Swift font payload bytes:** exact sizes of owning `Data` values returned by
  the actual production metadata. This describes logical ownership, not RSS.
- **Heap bytes in use:** native malloc statistics summed across all zones while inputs are retained.
- **Current resident bytes and physical footprint:** process-level native
  measurements while the input objects are retained.
- **Peak resident bytes:** process-lifetime high water mark, retained separately;
  it is not the metric used to claim live retained-memory savings.
- **Open wall and process CPU time:** opening/probing the designated inputs.

The after-release observation supports lifetime inspection. It follows
variant-dependent attachment hashing and receipt construction; baseline inputs
have more font payloads to hash. Small JSON receipts remain alive, and allocators
may retain freed pages. This is not an isolated production teardown comparison
and must not be used to claim post-close memory savings.

Summary values are medians per variant and medians of paired reductions
`baseline - candidate` (or `100 * (1 - candidate / baseline)`). A median paired
percentage can differ from a percentage computed from the displayed medians.
Ranges describe the observed pairs, not statistical confidence intervals.

## Correctness and provenance

Each input's complete non-font metadata, codec-private bytes and packet trace
before/after seek must match across both variants and both backends. Default
primary attachment names, MIME types, order, bytes and hashes must remain
unchanged. Auxiliary candidates must retain zero font payload bytes. The native
test suite additionally covers caller behavior and default ownership after
input destruction.

The runner records the compiler and native library/header hashes, baseline
commit, candidate commit/status, production source hashes, original source
snapshots, driver, fixture manifest, binaries, executed commands and every
measurement. It verifies unchanged source/fixture inputs after measurement.

Native results and their qualification limits are documented in
[`../../Documentation/AUXILIARY_FONT_ATTACHMENT_MEMORY.md`](../../Documentation/AUXILIARY_FONT_ATTACHMENT_MEMORY.md).
