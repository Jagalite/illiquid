# Pinned mpv-versus-Superplayr differential test plan

Plan baseline: Superplayr `fbdc699627bebf4298a630004ca31a31b0ec5df4`,
2026-07-19.

Current status (2026-07-20): the FC/IS authority migration is complete at
`6825c6b`; this differential harness is the next qualification phase, not a
prerequisite still blocking the completed authority switch. All deterministic
fixture, policy, race, schema, and threshold-contract work in this plan is now
implemented. Gates that require a valid Apple renderer, a pinned oracle build,
redistributable bitmap-subtitle inputs, or physical devices remain explicitly
blocked or unmeasured. Exact results are maintained in
[QUALIFICATION_STATUS.md](QUALIFICATION_STATUS.md).

Implementation update (2026-07-20): `SuperplayrDifferentialHarness` now emits
the complete dependency-ordered semantic artifact matrix with raw logs, FFprobe
truth, normalized monotonic timelines, explicit dispositions, and fault-policy
records. Fixture generation accounts for every required row with generated,
adapter-covered, or explicitly blocked status. Renderer-clock observation,
normalized chapters, reflected display matrices, safe track-ID rejection,
explicit bitmap/interlace policy, control-priority queues, commit barriers,
staged input, external SSA/WebVTT, package/player smoke, and normal/ASan/TSan
50-cycle qualification attempts are automated. Machine-readable deterministic
race, semantic-policy, and acceptance reports prevent missing measurements from
masquerading as live parity. See
[DIFFERENTIAL_HARNESS.md](DIFFERENTIAL_HARNESS.md) for commands and
[QUALIFICATION_STATUS.md](QUALIFICATION_STATUS.md) for truthful gate results.
This does not reopen the completed FC/IS authority migration.

## Purpose

mpv is a behavioral oracle, not a runtime dependency or specification of every
product choice. The harness should identify disagreements, preserve artifacts,
and require an explicit disposition:

- Superplayr bug;
- intentional product difference;
- dependency/version difference;
- nondeterministic platform behavior;
- oracle limitation;
- fixture defect.

No test may silently declare parity merely because both processes exited.

## Prioritized next-phase sequence

### P0 — Freeze the oracle contract and prove one end-to-end artifact

1. Pin/build the mpv executable described in [SOURCE_PINS.md](SOURCE_PINS.md)
   and record its binary hash, configuration, dependency versions, AO/VO, and
   options.
2. Add the immutable fixture/run manifest and FFprobe truth dump.
3. Adapt current core/runtime diagnostics into the common result schema without
   treating submission PTS as visible/audible proof.
4. Run one H.264/AAC load → exact seek → pause/resume → EOF smoke through both
   runners and retain `result.json`, normalized timeline, logs, and disposition.

This closes harness plumbing before fixture breadth or tolerance tuning can hide
basic identity/provenance errors.

### P0 — Lock fixture truth and provenance

Make fixture generation fail when the asserted property is absent. Start with
the nominal VFR fixture, non-zero/negative origin, unknown duration,
corrupt/truncated input, delayed decoder/resampler tail, and midstream format
change. Replace the current system-font dependency with a pinned redistributable
font or explicitly keep that case local-only. Emit checksums, generator command,
license/origin, and relevant FFprobe assertions for every fixture.

### P1 — Add semantic differentials in dependency order

1. open/probe, playable A/V rejection, catalog, and selected-stream policy;
2. timeline origin and unknown-duration capability behavior;
3. exact/keyframe/preview seek landing, including sample-accurate audio floors;
4. decoder/converter/presentation drain and clean versus truncated EOF for A/V,
   audio-only, and video-only media; and
5. track/subtitle selection, delay, rollback, and stale-output exclusion.

Compare observable outcomes and eligible frames/samples, not identical internal
seek points or mpv object state.

### P1 — Translate fault and race scenarios

Reuse the production driver/native fault seams for delayed, duplicate, stale,
failed, cancelled, blocked, and reordered outcomes. For faults a live mpv
process cannot deterministically inject, compare Superplayr policy to the pinned
mpv/FFmpeg/libass behavior record rather than manufacturing a false process
parity result.

### P2 — Calibrate presentation and physical gates

Only after semantic results are stable, calibrate A/V, EOF, color/HDR, scaling,
subtitle, memory, and latency tolerances. Then execute the supported Mac,
display, audio-route, sleep/wake, fullscreen, and PiP matrix. Mark Apple facts
that remain unobservable as `unmeasured` and keep their physical gate explicit.

### Landing order

- Per change: manifest/self-checks, core/driver regressions, and a small
  load/seek/EOF differential smoke.
- Dedicated Mac/nightly: full codec, subtitle, fault, replacement, sanitizer,
  and pinned-oracle artifact set.
- Release: physical display/audio/lifecycle matrix plus package/signature and
  live-app smoke.

## Immutable run manifest

Every run writes a manifest containing:

```text
harness revision
fixture-generator revision
fixture path, SHA-256, generator command, license/origin
Superplayr commit and app/binary SHA-256
mpv commit, binary SHA-256, build configuration, FFmpeg/libplacebo/libass versions
Superplayr runtime FFmpeg/libass versions and avcodec_configuration()
macOS build, SDK, Mac model, CPU/GPU, memory
display name/mode/refresh/EDR headroom/profile
audio device UID, route, sample rate, channel layout
all player options and environment variables
wall-clock start/end and monotonic event timestamps
```

The source-oracle pins are in [SOURCE_PINS.md](SOURCE_PINS.md). The current
Superplayr build uses system libraries, so the runtime library closure must be
recorded independently from the reference-source SHA.

## Harness layout

```text
FixtureGenerator
    -> fixtures/ + fixture-manifest.json

OracleRunner
    -> pinned mpv subprocess + JSON IPC/event/log capture
    -> optional FFprobe packet/frame truth dump

NativeRunner
    -> test-only Superplayr backend adapter
    -> structured state/queue/decoder/presenter/fault journal

Comparator
    -> semantic results + tolerances + intentional-difference allowlist
    -> machine-readable result.json
    -> human timeline, frame/subtitle artifacts, memory graphs
```

The mpv subprocess is test-only. No mpv library, output, or fallback is linked
into the planned Superplayr product.

## Runner modes

### 1. Deterministic semantic mode

Use synthetic inputs and test adapters. Run mpv with `--no-config`, a recorded
set of options, JSON IPC, and the actual selected AO/VO/hwdec recorded. Run
Superplayr with structured internal instrumentation. Compare load, tracks,
decoder, seeks, track changes, EOF, failures, and memory.

Do not use `--vo=null`/`--ao=null` for assertions that depend on output drain or
A/V coordination; null outputs change the behavior being measured. A headless
mode is acceptable only for demux/decoder-specific assertions and must be named
as such.

### 2. Fault-injection mode

Dependency adapters return controlled FFmpeg/OSStatus/libass outcomes or pause
at barriers. This is the only deterministic way to prove close-during-open,
check-then-enqueue races, stale EOF, output failure, and retry exhaustion.
Compare the resulting policy to the documented mpv behavior, not necessarily to
a live mpv process.

### 3. Visual/presentation mode

Run pinned mpv, Superplayr, and optionally QuickTime on the same Mac, display,
mode, brightness, and color profile. Use objective color patches, screenshots
where the path is meaningful, and a human grade. Record that screenshots may
exercise different composition/tone-map paths than the display.

### 4. Physical-device mode

Exercise built-in, HDMI/USB, and wireless audio; internal SDR/EDR and external
SDR/HDR displays; sleep/wake; disconnect/reconnect; fullscreen; PiP. These runs
cannot be replaced by SwiftPM tests.

## Common result schema

For every fixture, both players emit or derive:

| Measurement | Definition |
| --- | --- |
| Open success | header/tracks ready, not merely process started |
| Selected streams | type, FFmpeg index, codec, language, dispositions, stable product ID, reason selected |
| First decoded | first accepted decoder output by type |
| First enqueued | first sample committed to current presentation epoch |
| First visible/audible readiness | renderer-backed observation; if unavailable, explicitly `unmeasured` rather than enqueue proxy |
| First-frame time | wall time from load request to first visible/readiness evidence; decoded/enqueued durations retained separately |
| Hardware decoder | requested, configured, actual emitted frame format, fallback/recreation reason |
| Seek result | mode, requested target, low-level target, actual video PTS, audio first sample PTS, completion reason/latency |
| A/V difference | initial landing and steady presentation estimate; submit horizon reported separately |
| EOF time | demux EOF, decoder EOF, resampler EOF, last enqueue, last presentation end, product EOF |
| Track switch | old/new IDs, preparation/commit times, actual active decoder, rollback/degraded outcome |
| Subtitle output | active cue IDs, region geometry, deterministic mask/color hash, visible-clear times |
| Decoder fallback | exact error domain/code, attempts, target decoder/frame format, recovery landing |
| Memory | queue bytes/duration, CVPixelBuffer count where possible, RSS high-water and post-close baseline |
| Error/recovery | typed fault, retry count, action, user outcome, final state, live worker/callback count |

## Comparison rules

1. Compare normalized media times, while retaining original PTS/DTS.
2. Map tracks by stream index/codec/metadata, not mpv's user-facing IDs.
3. An intentional unsupported feature passes only if capability and error are
   explicit; silent no-output is a failure.
4. Exact seek does not require numerically identical low-level seeks. It requires
   the same eligible landed video frame and no pre-target audio.
5. Pixel-perfect subtitle comparison is valid only with identical libass,
   fonts, frame size, and settings. Otherwise compare cue activation, geometry,
   and perceptual masks with documented tolerance.
6. Hardware decode parity is not mandatory when VideoToolbox is unavailable;
   correct software fallback is.
7. Clean EOF and read-failure-after-valid-data are different expected outcomes.
8. Apple presentation metrics that are not observable remain explicitly
   unproven and go to the physical gate.

## Initial acceptance thresholds

These are refactor gates to calibrate with the generated fixtures, not claims
about all media:

- selected streams match the documented Superplayr policy in 100% of fixtures;
- exact video seek lands on the same eligible frame as mpv, or within one frame
  when decoder timestamp repair differs, with the reason recorded;
- no audio sample before the normalized exact target is enqueued;
- steady A/V presentation difference stays within 50 ms, with no excursion over
  100 ms outside a declared seek/rebuffer window;
- product EOF is never earlier than the final required presentation interval
  minus one output quantum, and normally arrives within 500 ms after drain;
- preview storms do not commit more than a bounded visible cadence and the final
  exact target always wins;
- queue byte/time/count high-water marks are never exceeded;
- after 50 mixed replacements, post-quiescence RSS is within the larger of 10%
  or 32 MiB of the warmed baseline and has no monotonic per-replacement slope;
- every close reaches zero live playback workers, leases, and pending callbacks;
- no stale epoch emits a sample, subtitle event, rate change, failure, or EOF;
- unsupported bitmap/passthrough/etc. is reported before a misleading success.

## Existing generated coverage at the plan baseline

`Scripts/generate-native-poc-fixtures.sh` already creates copyright-safe
synthetic coverage for:

- H.264/AAC MP4 and MKV;
- HEVC 8-bit and HEVC 10-bit;
- VP9/Opus and optional AV1 video-only;
- multiple audio tracks;
- embedded/external SRT and ASS;
- an embedded font case;
- FLAC, Vorbis, MP3, PCM audio-only;
- video-only;
- a fixture named `variable-frame-rate.mkv` whose current `setpts=N/(12*TB)`
  expression produces evenly spaced 12 fps timestamps, so it is not valid VFR
  evidence;
- +2 second non-zero start;
- a discontinuity attempt;
- 90-degree rotation;
- HDR10/PQ P010 and HLG P010;
- 5.1 and 7.1 FLAC;
- heavy animated/karaoke ASS;
- long H.264, HEVC/P010, and an optional gap-bearing VFR-like A/V sync fixture.

Current tests prove useful decode/metadata/rendering facts, but many return early
if the fixture directory is absent. The nominal VFR test therefore validates a
CFR file despite its name; the optional long gap fixture is environment-gated
and lacks an irregular-PTS self-check or seek assertion. The non-zero test only
decodes a first frame; it does not prove normalized playback, exact seek, or
EOF. “A/V difference” is a difference between the last submitted audio/video
sample start PTS values. No test currently proves renderer-drained EOF.

Sources: `Superplayr:Scripts/generate-native-poc-fixtures.sh`;
`Tests/SuperplayrNativePlaybackPOCTests/{NativePlaybackFoundationTests,
NativePlaybackFixtureIntegrationTests}.swift @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

At the 2026-07-20 implementation revision the generator and test target are
named `Scripts/generate-native-fixtures.sh` and
`Tests/SuperplayrNativePlaybackTests`. Fixture-required qualification now runs
instead of silently accepting a wholly absent fixture directory. The fixture
matrix below is machine-accounted by `fixture-matrix.json`; presentation and
physical rows that cannot execute on this host remain explicit blockers rather
than implicit passes. Current row-level outcomes are summarized in
[QUALIFICATION_STATUS.md](QUALIFICATION_STATUS.md).

## Required fixture matrix

| Fixture | Construction/origin | Required assertions | Current status |
| --- | --- | --- | --- |
| H.264 8-bit CFR + AAC | lavfi `testsrc2`/tone, x264/AAC | VT actual frame, first frame, exact/keyframe seek, EOF | generated; open/selection/exact landing/drain artifacts and renderer command exist; actual VT/presentation stays host-gated |
| HEVC 8-bit + audio | generated | VT path, fallback, drain | generated with live artifact and explicit hardware/software identity |
| HEVC 10-bit/P010 | generated | actual 10-bit CV format, HDR/SDR metadata variants | generated with HDR and SDR variants; actual P010/EDR stays renderer/display-gated |
| VP9 8/10-bit | generated libvpx | VT availability or correct SW fallback | stable 8/10-bit fixtures and codec identity records |
| AV1 8/10-bit | generated when encoder present | actual decoder selection, bounded SW/VT result | stable 8/10-bit fixtures; generation fails if required AV1 encoding is unavailable |
| CFR controls | generated exact timebase/GOP | frame-duration and seek truth | uniform 24 fps deltas and fixed GOP are generator-enforced; exact seek is in the semantic matrix |
| VFR | concat/rate segments; generator fails unless `ffprobe` proves non-uniform PTS deltas | no avg-FPS landing assumption, exact frame parity | generated and self-checked; both runners produce exact-seek artifacts, while mpv JSON IPC cannot expose decoded-frame identity |
| +non-zero start | timestamp offset, ffprobe assertion | player time zero mapping, chapters/resume/seek | generated with source-time chapters; decoded audio, published chapters, resume time, and low-level seek targets are normalized |
| negative start | negative `setpts`/container preserving it; generator fails if normalized | player non-negative mapping, no sample loss | generated; negative packet origin and retained frame count asserted |
| non-monotonic PTS/DTS | deterministic packet timestamp rewrite; verify `-show_packets` | repair/discontinuity policy, no hang | generated and rejected unless packet PTS actually regresses |
| missing duration | raw elementary stream or finite named-pipe/live-like adapter | unknown remains unknown; playback/EOF/seek capability | raw H.264 remains unknown; open/decode/EOF continue and seeking reports unsupported without aborting the run |
| corrupt packets | FFmpeg noise bitstream filter or deterministic bit flips in generated payload | skip/count versus fallback; bounded terminal policy | generated with decode-error truth, distinct read-failure outcome, and typed bounded recovery policy |
| truncated file | byte-truncated generated original at several boundaries | queued data drains, final outcome is read failure | deterministic truncation and clean-versus-read-failure regression exist; renderer drain remains open |
| growing/unreadable-then-readable | test AVIO adapter or temp-file writer | staged probe/read retry and cancellation | deterministic retry, exhaustion, and cancellation adapter plus report coverage |
| midstream resolution change | concatenated compatible elementary/TS segments; frame probe verifies both sizes | decoder/presenter/UI revision, no stale geometry | generated with both decoded resolutions; format-revision barrier exists; live presenter/UI remains renderer-gated |
| midstream pixel/color change | generated segment change with verified frames | atomic reconfigure/no stale attachments | generated with multiple decoded configurations and the same format-revision barrier |
| multiple audio tracks | generated languages/default/forced/commentary metadata | deterministic selection and switch/rollback | default/commentary flags, stable selection, two-phase commit, and rollback are covered |
| malformed/duplicate track IDs | custom tiny container or demux adapter | stable IDs, no trap | bounded mapping rejects zero, negative, and overflowing IDs without narrowing traps |
| multichannel 5.1/7.1 | generated independent channel tones | contribution, labels, no clipping; stereo/multichannel policy | generated independent-channel inputs, source layouts, bounded stereo conversion, and clipping checks |
| audio sample-rate/layout change | concatenated stream or decode adapter | resampler drain/rebuild and clock continuity | two configurations, format revisions, drain, and monotonic output clock are covered |
| embedded/external SRT | generated cues including markup/position/UTF variants | FFmpeg conversion, delay, switch, seek cue | embedded and external conversion/rendering, delay ownership, switch, and seek invalidation covered |
| embedded/external ASS | generated effects/karaoke/overlap | timing/geometry/mask hashes at fixed times | simple plus 120-event animated/karaoke stress at fixed viewport sizes |
| external SSA/WebVTT | generated text cues with extension and codec truth checks | product intake, FFmpeg conversion, timing, explicit capability result | generated, accepted by UI/product intake, converted, and rendered in-process |
| font attachments | use a redistributable SIL OFL font pinned by hash | attachment limits/fallback/session release | local-only system-font fixture is explicitly non-redistributable; bounded attachment/session release is covered |
| missing glyph/font | generated ASS with known coverage gaps | CoreText fallback and diagnostic | generated missing-font/glyph input renders through bounded CoreText fallback |
| PGS | generate if a licensed encoder/tool is available, else a tiny CC0/public-domain fixture with checksum/license | decode, regions, seek reset, forced flags | redistributable input remains provenance-blocked; codec is explicitly unplayable and never advertised as text |
| VobSub/DVD | same provenance rule | palette/canvas/PAR/reset | redistributable input remains provenance-blocked; codec is explicitly unplayable and never advertised as text |
| DVB subtitle | same provenance rule | composition/end-display/reset | explicitly deferred pending scope evidence and redistributable input; codec is never advertised as text |
| rotation 90/180/270 + mirror | generated display matrix | video geometry, upright subtitle, all viewport sizes | all quarter turns plus horizontal reflection are generated, truth-checked, and applied separately from subtitles |
| anamorphic SAR/clean aperture | generated test grid | correct display aspect and subtitle storage | non-square SAR and display geometry are truth-checked; physical subtitle grade remains display-gated |
| BT.601/709/2020 limited/full | lossless tagged color patches | pre-present numeric values and displayed grade | tagged limited/full fixtures and pre-present metadata checks exist; displayed grade remains physical |
| chroma siting | saturated boundary patterns | correct attachment/reconstruction | left/center tags are generated and asserted; reconstruction grade remains physical |
| HDR10/PQ | generated ramps/color patches with mastering/CLL | metadata, EDR, tone-map grade, subtitle white | P010 plus mastering/CLL metadata is generated; EDR/tone-map/subtitle-white grade remains physical |
| HLG | generated ramps | transfer/EDR/SDR grade | P010 HLG metadata is generated; EDR/SDR grade remains physical |
| SDR BT.2020 | generated | not mislabeled HDR | BT.2020 primaries with BT.709 transfer are generator-enforced |
| interlaced TFF/BFF | generated moving wedges | detection/deinterlace or explicit unsupported | generated and field-order checked; product emits explicit source-field-composition/no-deinterlacer policy |
| audio-only | generated multiple codecs | only audio renderer attached; readiness ignores video; first-audible state and EOF | codec matrix, renderer membership, exact audio floor, and clean EOF covered; physical audibility remains unmeasured |
| video-only | generated | no audio renderer attached; host clock, exact seek, EOF | renderer membership, exact seek, and clean EOF covered; visible readiness remains renderer-gated |
| rapid seeking near EOF | reuse CFR/VFR and script input | final request/EOF outcome, no hang | deterministic sequence proves the final exact request replaces preview work; live renderer run remains host-gated |
| repeated file replacement | mixed generated matrix | stale epoch/rate/failure/EOF exclusion, memory | all stale commit boundaries and terminal leases are deterministic; 50-cycle RSS remains a live renderer gate |
| close during load/seek/decode/present | fault adapters and barriers | cancellation, zero callbacks/workers, no timeout lie | close barriers cover open, seek, decode, present, and blocked input with cleanup-only custody and zero leases |

## Copyright and fixture provenance

Do not commit copyrighted movie/TV samples. Preferred order:

1. generate audio/video from lavfi patterns and tones;
2. generate subtitle text and bitmap art in the repository;
3. use a redistributable font with its license and exact hash;
4. when a codec has no practical encoder, document a minimal public-domain/CC0
   source URL, license evidence, checksum, extraction command, and expected
   output; download it only in an explicit fixture-preparation job;
5. never rely on a movable URL or unrecorded system font.

The current embedded-font generator should not turn a system Arial installation
into a committed fixture. Replace it with a pinned SIL Open Font License font or
generate the fixture only locally and record that it is non-redistributable.

## Deterministic race tests

Add test-only barriers at commit boundaries:

1. old video passes decode, block before presentation commit, seek/flush, release;
2. same for audio, subtitle event, `startIfPrerolled` rate change, and EOF;
3. block old media session, replace file, release old work;
4. inject old hardware error after replacement and prove it cannot seek/flush;
5. let both old A/V EOS callbacks pass preliminary checks, perform seek, then
   release and prove they cannot mark new generation ended;
6. fill a data queue, issue control, and prove stop/seek does not wait for data
   capacity;
7. close while AVIO read is blocked and prove interrupt/join order.

These are more valuable than probabilistic “rapid seek 100 times” tests because
they force the exact interleaving that current source permits.

`SuperplayrDifferentialHarness deterministic-races` writes every forced
interleaving above as a machine-readable report. Queue invalidation revokes a
producer waiting on obsolete data capacity, so seek/close cannot wake it and
admit one stale element. The semantic-policy report separately records track
prepare/commit/rollback, subtitle-delay acknowledgment, malformed ID rejection,
bitmap capability policy, and final near-EOF seek ownership.

## Acceptance contract execution

Every initial threshold above is encoded by `DifferentialAcceptanceEvaluator`.
Its report contains exactly one record per threshold and permits only `passed`,
`failed`, or `unmeasured`. Deterministic qualification passes preview ownership,
queue bounds, terminal quiescence, stale-epoch exclusion, and unsupported-
capability reporting. The combined report consumes semantic artifacts for
selected-stream parity and the worst observed exact-audio floor. Decoded-frame
landing, physical A/V, renderer-drained EOF, and 50-cycle memory slope consume
live renderer evidence and remain `unmeasured` when that evidence is absent.
The retained 2026-07-20 host report passes seven gates with no failures and
leaves exactly four renderer-only gates unmeasured.

## CI and physical qualification split

### Every change

- fixture manifest verification and generator self-checks;
- foundation/state-machine/fault-injection tests;
- key codec/decode/seek/EOF differential subset;
- architecture check, build, complete Swift tests;
- `git diff --check` and no external checkout inside production sources.

### Nightly or dedicated Mac runner

- full codec/subtitle/corrupt/format-change matrix;
- VT and software paths;
- 50+ replacement/seek stress;
- sanitizer/leak/memory slope;
- pinned mpv comparison artifacts.

### Release physical matrix

- Apple Silicon generations supported by product;
- current and oldest supported macOS;
- built-in SDR/EDR, external SDR, external HDR;
- built-in speakers/headphones, HDMI/USB, wireless route;
- sleep/wake, display disconnect/reconnect, device switch;
- subjective HDR/HLG/SDR, scaling, rotation/subtitle, PiP;
- power assertion/paused CPU and thermal behavior.

## Oracle limitations

- mpv's selected AO/VO, options, and build dependencies affect behavior.
- mpv's player policy is not automatically the desired Superplayr UX.
- Apple and mpv/libplacebo presentation pipelines can both be correct but
  visibly different.
- Subtitle pixels differ with font/library builds.
- Hardware decode can be resource-dependent.
- A source bug shared through the same FFmpeg build is not exposed by a
  differential test; retain spec-derived assertions and alternate versions.

The harness therefore records evidence and requires a disposition; it does not
reduce architecture decisions to “match every mpv number.”
