# Loading and demux

## Verdict

Keep FFmpeg as the only container demuxer. Add a cancellable, staged
`MediaSourceOpener`, an explicit timeline origin, and queue budgets owned by the
player. Do not reproduce mpv's full multi-range cache for the initial local-file
product, but preserve an interface that can add one later.

## Responsibility map

| Area | Primary implementation owner | mpv adds | Superplayr current state | Recommended owner |
| --- | --- | --- | --- | --- |
| Local file open | FFmpeg `avformat_open_input` | async cancellation, options, fallback hooks, lifecycle | synchronous on `@MainActor` | FFmpeg mechanics; Superplayr cancellable state |
| Format probe | FFmpeg `av_probe_input_buffer2` / stream-info analysis | probe policy and partial-result handling | one fixed `avformat_find_stream_info` call | FFmpeg with staged app budgets |
| Container parsing | FFmpeg demuxers | wrapper and cache | delegated | FFmpeg |
| Packet timestamps/durations | FFmpeg parsers/demux heuristics | discontinuity policy and diagnostics | raw values; no timeline normalization | FFmpeg inference plus Superplayr mapper |
| Initial best stream | FFmpeg generic scoring | language/default/forced/external policy | direct `av_find_best_stream` | Superplayr product policy over FFmpeg candidates |
| Dynamic streams | FFmpeg reports new streams/events | updates tracks during playback | static snapshot at open | FFmpeg event + Superplayr track revision |
| Packet cache | — | count/byte/time budgets, multiple ranges, pruning | fixed item-count queues | Superplayr bounded queues; ranges deferred |
| Seek in cache | — | range/keyframe-aware cached seek | none | deferred for local files |
| First-frame readiness | decoder/presenter result | coordinates required tracks | one sample submitted per active stream | Superplayr presentation state |

## FFmpeg's actual contract

### Open and probing

`avformat_open_input` initializes duration/start fields to unknown, identifies a
demuxer through name or bounded probing, opens IO, reads the container header,
and queues attached pictures. A successful call does not prove that every
stream has usable codec parameters.

`avformat_find_stream_info` accumulates packets under `probesize` and
`max_analyze_duration`, retries codec probes as buffers cross powers of two, and
may open a decoder and decode a frame to discover parameters. General, subtitle,
FLV, and MPEG-family inputs have different analysis defaults. `EAGAIN` can mean
that more bytes may produce more information. Inputs marked `AVFMTCTX_NOHEADER`
can add streams during ordinary reads.

Sources: `FFmpeg:libavformat/demux.c::init_input,avformat_open_input,
probe_codec,avformat_find_stream_info,try_decode_frame @
162c2784f90969ae53c1f4aa36d22ef93945a293` (LGPL-2.1-or-later).

Implication: “missing metadata after the first probe” is a state, not always a
terminal error. Superplayr should use explicit stages:

```text
created -> openingIO -> headerReady -> probing -> tracksReady
                         |              |
                         +-> failed     +-> partialMetadata
any nonterminal state -> cancelling -> closed
```

For a local, stable file, use a normal bounded probe first. If the only failure
is incomplete essential parameters and more data is available, allow one larger
documented budget. Do not retry malformed/unsupported input indefinitely. If
the file's size or modification time grows, expose a user-driven “retry growing
file” path rather than polling forever.

### Packet and timestamp behavior

FFmpeg makes returned packets refcounted, can retry internal `FFERROR_REDO`, and
propagates `EAGAIN`. A corrupt flag is informational unless the caller enables
discard-corrupt policy. At EOF/error it flushes parser state; an underlying AVIO
error is distinguishable from clean EOF. If a parser is unavailable, packets
can pass through with a warning even though times may be poor.

FFmpeg also:

- corrects timestamp wraparound;
- intentionally preserves valid negative timestamps in some formats;
- backfills queued packet origins and durations when later evidence arrives;
- estimates duration from parser/frame-rate where safe;
- notices non-monotonic DTS and can invalidate DTS rather than invent an order;
- avoids unsafe one-packet/one-frame interpolation for reordered codecs such as
  H.264, HEVC, and VVC;
- optionally buffers for `GENPTS` to infer missing PTS;
- resets frame-rate estimation after extreme discontinuities.

Sources: `FFmpeg:libavformat/demux.c::ff_read_packet,handle_new_packet,
read_frame_internal,update_wrap_reference,update_timestamps,
update_initial_timestamps,update_initial_durations,compute_pkt_fields,
av_read_frame @ 162c2784f90969ae53c1f4aa36d22ef93945a293`
(LGPL-2.1-or-later).

FFmpeg's internal raw/probe/GENPTS buffers are not an application playback cache
and provide no player backpressure or multi-range seek guarantee.

### Dynamic metadata and tracks

`AV_PKT_DATA_NEW_EXTRADATA` can reset FFmpeg's internal parser/probe decoder and
mark a stream's context for update. `AVFMT_EVENT_FLAG_METADATA_UPDATED` reports
container-level metadata changes. A newly observed stream is appended by the
demuxer. None of those events rebuilds Superplayr's codec context, audio
resampler, subtitle track, or Apple format description.

Source: `FFmpeg:libavformat/demux.c::read_frame_internal @
162c2784f90969ae53c1f4aa36d22ef93945a293` (LGPL-2.1-or-later).

## What mpv adds

### Open lifecycle

mpv opens the demuxer on an asynchronous thread, owns an abort token, and can
cancel and join that opener. `cancel_open` itself has no deadline; forced
termination under `demux_termination_timeout` belongs to
`kill_demuxers_reentrant` for already-open demuxers. mpv separates “file opened”
from track initialization and initializes audio, video, and subtitles
independently; one failed track need not erase a playable other track. Dynamic
stream events update the track list while playing.

Source: `mpv:player/loadfile.c::open_demux_thread,open_demux_reentrant,
cancel_open,kill_demuxers_reentrant,add_demuxer_tracks,
update_demuxer_properties,play_current_file @
94335ab87ab225ca3e36e0faeac831639d3e1d4e` (LGPL-2.1-or-later).

### Track policy

mpv gives each player track an identity distinct from malformed or duplicated
container IDs. Selection considers explicit ID, external/manual status,
program, language preference order, forced/default flags, attached pictures,
dependent streams, and deterministic tie-breaking. It prevents the same track
from occupying both primary and secondary slots.

Source: `mpv:player/loadfile.c::compare_track,select_default_track,
check_previous_track_selection @ 94335ab87ab225ca3e36e0faeac831639d3e1d4e`
(LGPL-2.1-or-later).

### Track switching and external tracks

mpv switches only the affected chain. It clears/uninitializes the old audio
chain (and AO when audio is disabled), uninitializes the selected subtitle,
updates demux selection, then recreates the selected video, audio, or subtitle
chain. It rejects selecting one track into two slots. External track opening
runs outside the core lock under cancellation; after relocking, it rechecks
that playback is still live before adding streams. This avoids a whole-file
rebuild but is still coordination owned by mpv, not FFmpeg.

Source: `mpv:player/loadfile.c::mp_switch_track_n,reselect_demux_stream,
mp_add_external_file @` the pinned mpv SHA (LGPL-2.1-or-later).

### Cache and backpressure

mpv's demux producer owns packet queues and multiple cached ranges. It uses
forward/backward byte caps, time targets, and hysteresis; it marks streams
selected/eager/lazy, maintains keyframe reader heads, and computes an A/V
intersection for seekable ranges. New packets clear previous stream/global EOF.
Range joins are accepted only when overlapping packet position/timestamps are
repeatable. EOF clearing applies to ordinary streams; closed-caption
pseudo-streams can use `ignore_eof`. Attached-picture streams return one copied
packet and then EOF, while font/data attachments remain demuxer metadata rather
than packet streams.

Sources: `mpv:demux/demux.c::add_packet_locked,read_packet,
attempt_range_joining,find_seek_target,update_seek_ranges,
demux_get_reader_state @
94335ab87ab225ca3e36e0faeac831639d3e1d4e` (LGPL-2.1-or-later).

This is relevant as an edge-case catalog. A local-first Superplayr does not need
disk cache, reverse playback, or multiple ranges to fix its current correctness
gaps.

## Baseline Superplayr behavior (`fbdc699`)

### Open and first readiness

`FFmpegDemuxer.init` accepts only a file URL, calls
`avformat_open_input` and `avformat_find_stream_info` synchronously, then creates
a static media-info snapshot. `NativeAppleBackend.replaceSession` invokes that
path on `@MainActor`. There is no AVIO interrupt callback, cancellation token,
probe-stage event, larger second probe, or safe close-during-blocked-read path.

The selected video or audio decoder's initialization failure aborts
`MediaSession` construction rather than trying another track or retaining the
other playable medium. Conversely, construction permits both decoders to be
nil; a subtitle/data-only container then starts no A/V worker and can never
reach the current all-stream EOF condition. `firstFramePresented` is emitted
when a video frame has been submitted to Apple; it is not proof that a pixel was
displayed, and audio-only content cannot satisfy that event.

Sources: `Superplayr:Media/FFmpegDemuxer.swift::init`;
`Media/MediaSession.swift::init,startIfPrerolled`;
`Production/NativeAppleBackend.swift::replaceSession,tick @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

Classification: **partial** for local opening, **missing** for cancellation,
staged probe, and no-playable-A/V rejection, **requires physical/device
validation** for true first display.

### Static timestamps and unknown duration

The demuxer records `startTime`, but playback never rebases it. Container unknown
duration is converted to zero. Seeks clamp to `0...duration`, so an unknown-
duration file can only seek to zero. `MediaTime.seconds` maps invalid time to
zero, collapsing “unknown” and a real origin. The multiplication in timestamp
conversion also lacks an overflow-safe rescale.

Sources: `Superplayr:Media/FFmpegDemuxer.swift::makeMediaInfo,seek`;
`Media/MediaTime.swift`; `Media/MediaSession.swift::seek @` the Superplayr
baseline SHA.

Classification: **missing** timeline policy. This blocks correct non-zero and
negative start behavior even though a non-zero fixture decodes successfully.

### Packet queues

`PacketQueue` is an owning bounded FIFO with correct blocking push, close, clear,
and wakeup behavior. `FFmpegPacket` moves one `AVPacket` into its own allocation
and frees it on destruction. Those are strong foundations.

Limits are only item counts: 96 video packets, 192 audio, 64 subtitle, 12 video
frames, and 48 audio frames. A queue therefore has no stable memory or media-time
bound across codecs. Seek/stop directly clear or close queues and broadcast to
wake blocked pushes, so a full queue does not inherently deadlock control.
Control is nevertheless only **partially** prioritized: the demux loop observes
seek at its next iteration, and its generation-check-to-push sequence is not
atomic, allowing one stale packet to enter after a clear before downstream
generation rejection removes it.

Sources: `Superplayr:Playback/PacketQueue.swift`; `Media/FFmpegPacket.swift`;
`Media/MediaSession.swift::init @` the Superplayr baseline SHA.

Classification: ownership is **functionally close**; budgeting and atomic
control/data ordering are **partial**.

### Read errors, starvation, and EOF

`readPacket` treats exact `AVERROR_EOF` as EOF and any other negative result as
fatal. It recursively calls itself to skip invalid stream indices. This loses
`EAGAIN`/temporary starvation semantics, AVIO error classification, and bounded
skip logic. The demux loop sleeps after EOF but has no “new data invalidates
EOF” path for a growing or live-like input. All selected queues receive EOS at
once.

Source: `Superplayr:Media/FFmpegDemuxer.swift::readPacket` and
`Media/MediaSession.swift::demuxLoop @` the Superplayr baseline SHA.

Classification: **partial** for ordinary static files; **missing** starvation,
growing-input, and typed error behavior.

### Attachments and delayed tracks

The static snapshot filters common font attachment MIME/extensions and feeds
libass. Attached-picture video and delayed stream creation receive no distinct
runtime handling. Tracks cannot be added or metadata-updated after load. Track
IDs are generated from `streamIndex + 1`, which avoids duplicate container IDs,
but selection conversion later performs an unchecked `Int64` to `Int32`
subtraction.

Sources: `Superplayr:Media/FFmpegDemuxer.swift::makeMediaInfo`;
`Production/NativeAppleBackend.swift::streamIndex @` the Superplayr
baseline SHA.

Classification: font extraction is **functionally close**; cover art/delayed
streams/update events are **missing**; ID conversion is a correctness risk.

## Required invariants

1. Only `DemuxPipeline` touches one `AVFormatContext` after open.
2. Every blocking IO operation can observe session cancellation through an
   FFmpeg interrupt callback.
3. Open, header-ready, partial-metadata, tracks-ready, first-sample-enqueued, and
   first-sample-presented are distinct facts.
4. Unknown timestamp/duration stays unknown until a named inference policy
   supplies a value; it never silently becomes zero.
5. `TimelineMapper` records `mediaOrigin` and maps every selected stream onto a
   non-negative presentation timeline while retaining original times for logs.
6. A packet queue owns its packet from successful push until decoder consumption
   or explicit purge; a successful FFmpeg send then transfers semantic
   consumption while FFmpeg retains any needed reference.
7. Each queue is bounded by bytes, buffered duration, and item count. Crossing a
   high-water mark blocks production; a low-water mark releases it.
8. Stop/seek/reconfigure travels on a control path that cannot be starved by a
   full data queue.
9. Clean EOF, temporary starvation, cancellation, and IO failure are different
   events.
10. Any new packet for a generation invalidates that generation's demux EOF;
    old-generation data can never invalidate new-generation EOF.
11. Dynamic stream/extradata changes create a `TrackRevision`; downstream
    consumers either reconfigure atomically or reject the revision.
12. Product track IDs are stable, bounded internal IDs, never unchecked casts of
    dependency values.

## Scope choices

### Implement now

- async/cancellable local open and read;
- staged, bounded probe with partial metadata;
- timeline normalization;
- byte/time/count queue budgets and control priority;
- typed demux result (`packet`, `wouldBlock`, `cleanEOF`, `cancelled`, `failure`);
- stable track IDs and dynamic update plumbing;
- explicit attachment/cover-art classification.

### Defer

- multi-range packet cache and seek-within-cache;
- network prefetch policy and disk cache;
- growing-file follow mode;
- delayed remote playlist/HLS features.

### Intentionally unsupported in the planned local-first product

- DVD/Blu-ray navigation and optical-disc menus;
- archive navigation as a media library;
- obscure network protocols merely because FFmpeg/mpv supports them.

The FFmpeg protocol allowlist should be explicit. Supporting `file` now does not
foreclose a later, separately secured HTTP(S) source module.
