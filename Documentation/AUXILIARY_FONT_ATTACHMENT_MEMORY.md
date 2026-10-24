# Auxiliary input font attachment memory

## Finding

At baseline `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`, every
`FFmpegDemuxer` copies supported embedded-font attachment bytes into owning Swift
`Data` values in `makeMediaInfo`. The copy survives with its media-info owner.
Separate readers for subtitle packets, delayed audio, thumbnails, duration
probes, frame-step timestamps and VobSub stream discovery do not register fonts,
but previously performed the same projection.

The main and Picture in Picture subtitle pipelines both receive attachments
from `MediaSession`'s primary `mediaInfo`. The auxiliary subtitle input supplies
packet and codec-private bytes; neither it nor the delayed-audio input supplies
the font list. This makes their additional Swift font copies unnecessary.

## Change

`FFmpegDemuxer` and `FFmpegInputExecutor` gain a default-enabled
`includeFontAttachments` initialization option. Seven auxiliary constructor
sites opt out. Stream descriptors are appended before the payload-inclusion
check, preserving attachment stream metadata as well as video, audio, subtitle,
chapter and timing information. Primary/default construction keeps its previous
font ownership and validation behavior.

| Consumer | Font inclusion |
| --- | --- |
| Primary playback input | Default, enabled |
| Separate embedded-subtitle packet input | Disabled |
| Delayed-audio packet input | Disabled |
| External bitmap subtitle input | Disabled |
| Timeline thumbnail decoder | Disabled |
| Thumbnail duration probe | Disabled |
| Frame-step timestamp reader | Disabled |
| External VobSub `.idx` stream probe | Disabled |

The existing attachment-admission benchmark still tests the enabled default
against its historical baseline. Its dependency guard now permits the
executor's pass-through option; complete default output/payload equality remains
required.

## Qualification

The native experiment compiles the actual baseline and candidate input sources
against the same pinned FFmpeg SDK. It measures 19 input-ownership scenarios in
six alternating baseline/candidate pairs, preserving all 228 fresh-process
observations. Complete metadata, codec-private bytes, initial packet streams and
post-seek packet streams are compared outside the memory sampling region.

The new native regression suite also exercises the actual thumbnail, metadata
and frame-step readers. Generated fixtures use the same encoded video, audio
and subtitle streams with controlled attachment inventories. Linux generation
and syntax checks validate the experiment's preparation; they do not qualify
native playback behavior.

Native measurements and test results are pending the branch qualification run.
This document will be updated with observed results before the research PR is
opened.

## Interpretation limits

This removes extra Swift-owned copies. FFmpeg's original attachment extradata,
the primary Swift font projection and libass's registered font storage remain.
The font validator admits at most 16 MiB per font and 64 MiB in aggregate for
playback; demuxer materialization itself occurs before that validation, so these
limits are not universal bounds on arbitrary file-open allocations.

The benchmark retains real input objects without a full running player. Its
process memory measurements include native probing and runtime overhead. Large
font-labeled fixtures contain deterministic arbitrary bytes and establish
ownership/copy behavior, not real-font rendering performance. The 64 MiB fixture
is a stress case. Open timings are secondary single-operation observations.

See the [benchmark method and reproduction instructions](../Benchmarks/AuxiliaryFontAttachments/README.md).
