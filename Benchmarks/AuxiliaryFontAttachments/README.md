# Auxiliary input font ownership

This native study compares main `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`
with the working-tree demuxer and input executor. It asks how much memory is
retained when auxiliary readers copy embedded fonts they do not consume.

Both libraries compile complete production demuxer, executor, packet, queue,
stream-info, media-time, error, and font-store sources. The shared source inventory
and guarded `PresentationError`/PGS declaration extraction come from the earlier
`AttachmentAdmission` harness. That historical experiment is unchanged. Only
`FFmpegDemuxer.swift` and `FFmpegInputExecutor.swift` may differ between the two
libraries. No production source is rewritten or replaced with a benchmark model.

The baseline calls its original constructor. The candidate uses
`loadFontAttachments: false` for the auxiliary case and its unchanged default
constructor for the control. Full/default and explicit-true construction are
also verified through both the direct demuxer and the serialized executor.

## Run

On macOS with Swift 6.1 or newer and the repository's pinned FFmpeg SDK:

```sh
python3 Benchmarks/AuxiliaryFontAttachments/generate-fixtures.py \
  --output /tmp/auxiliary-font-fixtures
python3 Benchmarks/AuxiliaryFontAttachments/run.py \
  --fixtures /tmp/auxiliary-font-fixtures \
  --output /tmp/auxiliary-font-results --pairs 6
```

Every output directory must be new or empty. `--ffmpeg-prefix` defaults to
`/opt/homebrew/opt/ffmpeg`; `--swiftc` selects another compiler. `--mode verify`
builds both variants and performs full correctness comparisons without measuring;
`--mode build` only compiles. This harness deliberately requires native macOS.

## Fixtures and correctness

The four measured Matroska files contain two seconds of 64×36 MPEG-4 video,
FLAC audio, ASS subtitles, and two chapters. Their supported-font payloads total
0, 2, 16, or 64 MiB. The largest case uses four 16 MiB entries, staying within
the existing count, per-font, and total-font admission limits. These deterministic
font-labeled payloads test admission and copying; they are not valid font files.
The 64 MiB case is an explicit stress case, not a claim about a typical film.

For each file, verification compares twelve complete traces: baseline and
candidate × direct demuxer and executor × default, explicit true, and auxiliary
construction. It checks every stored `FFmpegMediaInfo`/stream field and relevant
derived properties, chapters, exact attachment filenames/MIME/byte counts/SHA-256,
codec parameters and codec-private bytes, the complete packet sequence through
EOF, packet side data, packets after a seek, and active subtitle reconstruction.
Only the candidate auxiliary Swift attachment array may become empty. The
underlying native attachment codec data must still match. Font hashes must also
match the generator's manifest, providing an oracle independent of the baseline.

Two additional files are excluded from the measured matrix:

- `attachment-admission.mkv` preserves the earlier audio-only mixed-attachment
  regression fixture and its exact tiny font bytes.
- `embedded-ass-font.mkv` embeds the repository's real Noto Sans font and selects
  it in ASS cues, for native main/PiP rendering qualification.

`integration-manifest.json` and `generator-receipt.json` record these inputs.

## Memory boundary

Each memory observation is a fresh process. It opens one default main input,
then retains 1, 2, or 3 additional serialized input executors simultaneously.
The main input continues to own its full font inventory. A default-policy
control also opens one additional input with fonts enabled in both versions.

Native checkpoints are taken before the main input, after the main input, after
all additional inputs, after releasing those inputs, and after releasing the
main input. Construction drains an outer autorelease pool before each live
checkpoint. Deinitialization uses the real executor's synchronous teardown.
No payload hashing, packet tracing, or JSON serialization occurs before these
checkpoints. Small inventory checks verify expected retained font bytes and
unchanged metadata consumption in every sample.

The primary retained metric is the change in
`malloc_zone_statistics(NULL).size_in_use` from after the main input to after the
additional inputs. This includes native FFmpeg buffers and Swift-owned memory;
it is not an allocation-request counter. Current RSS uses
`task_info(MACH_TASK_BASIC_INFO).resident_size`. Peak RSS uses `getrusage` at the
live checkpoint and includes startup/probing/transient history. These measures
need not move by the same amount. Allocator caching and VM residency mean release
does not promise that RSS immediately returns to its previous value.

Skipping the Swift font copy does not remove the attachment data already loaded
by FFmpeg. The experiment cannot claim that an auxiliary demuxer has no font
memory, or that the same percentage applies to total player memory.

## Timing boundary and ordering

Timing observations run in separate fresh processes. One default main input is
held alive while a batch of 1, 2, or 3 additional inputs is opened and closed.
One warmup batch is excluded. A single paired calibration chooses a shared
iteration count targeting 100 ms for the faster variant, capped at 1,000 batches.
The measured interval includes normal open/probe, metadata construction, small
inventory/checksum consumption, and teardown. It excludes main-input setup,
hashing, packet tracing, and encoding.

Both cohorts use six balanced AB/BA pairs for each of sixteen fixture/policy/count
combinations: 192 memory processes and 192 timing processes, plus 32 calibration
and 8 verification processes. All observations, including adverse controls, are
retained. Percent reductions are medians of within-pair changes, not ratios of
independently computed medians. No performance threshold gates correctness.

## Evidence

`observations.jsonl` retains all raw memory/timing/calibration observations.
`parity.json`, verification stdout files, `summary.json`, and per-command logs
record comparisons and outcomes. `manifest.json` records the exact baseline,
working-tree source hashes, compiled source inventory, driver/helper hashes,
compiler/SDK/host identity, dynamic library hashes/linkage, and executable hashes.
The runner verifies source, driver, binary, and fixture stability at completion.
The results describe this native component and synthetic workload, not playback
frame rate, display latency, battery life, or a universal player speedup.

Recorded native results, controls, and limitations are described in
[`Documentation/AUXILIARY_FONT_MEMORY_PERFORMANCE.md`](../../Documentation/AUXILIARY_FONT_MEMORY_PERFORMANCE.md).
The study finds fewer live allocator-accounted bytes and less auxiliary input
open/close work for font-bearing fixtures. Current RSS is approximately 16 MiB
higher in the larger fixtures, and peak RSS is essentially unchanged; do not
interpret the allocation reduction as an equivalent physical-memory saving.
The [evidence index](evidence/README.md) explains the retained measurements,
verification traces, test logs, source receipts, and archive omissions.
