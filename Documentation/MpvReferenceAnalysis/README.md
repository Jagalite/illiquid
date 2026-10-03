# mpv reference analysis for Superplayr

Inspection date: **2026-07-19**

For the subsequent September compatibility, audio, subtitle, rendering and glass
font changes, use the current
[robustness findings register](../ROBUSTNESS_REVIEW_MPV_IINA.md). Capability gaps
below describe their dated inspection baseline; they are not a current feature
list. The [manual checklist](../MANUAL_PLAYBACK_CHECKLIST.md) records today's
supported operations and the remaining physical qualification tasks.

Superplayr baseline: `fbdc699627bebf4298a630004ca31a31b0ec5df4`

Implementation update: **2026-07-20**, completed at
`6825c6b90c9bfdcd3f80391c177edc22a2523513`.

The inspection baseline and every section labeled “Current Superplayr” remain a
dated description of `fbdc699`; they have not been rewritten as if the later
implementation already existed. The functional-core / imperative-shell (FC/IS)
authority migration, native-only runtime, reactive projection, and legacy
libmpv/OpenGL removal are now complete. The current ownership contract is
[FCIS_COMPLETION_MATRIX.md](../FCIS_COMPLETION_MATRIX.md), and the completed
verification record is
[NATIVE_PLAYBACK_QUALIFICATION.md](../NATIVE_PLAYBACK_QUALIFICATION.md).

## Decision

At the inspection baseline, the decision was: **refactor the native architecture
before adding more playback features.** That authority refactor is now complete.
Keep FFmpeg for containers and codecs, VideoToolbox as the preferred hardware
decoder, Apple's sample-buffer stack as the first presenter, and libass for ASS
layout and rendering. Do not retain libmpv or OpenGL in the planned runtime.
Do not start a Direct Metal/libplacebo presenter until pinned differential tests
show a material Apple-presentation failure that cannot be corrected through
metadata, configuration, or a focused preprocessing stage.

At `fbdc699`, the largest gaps were player-core semantics, not decoder breadth:

1. open/probe is synchronous and cannot be cancelled;
2. timestamp origin, unknown duration, and discontinuities do not have one
   explicit timeline policy;
3. queue bounds are counts rather than byte-and-time budgets;
4. generation checks are not atomic with shared renderer/subtitle mutation;
5. seek completion is enqueue readiness rather than a verified landing;
6. EOF is published before Apple's queued samples are known to have drained;
7. format changes and output-device changes have no typed reconfiguration path;
8. recovery is mostly log-and-continue, with insufficient fault classification;
9. text subtitle conversion, seek reset, and bitmap subtitles are incomplete;
10. color/HDR correctness is not yet proven on the required physical matrix.

The completed implementation resolves the authority, identity, cancellation,
seek/recovery/drain ownership, reactive-shell, and native-only packaging parts
of that finding. It does not make every fixture, oracle comparison, or physical
display/audio qualification item below complete. Those remaining evidence gaps
justify the next differential-test phase; they do not reopen the architecture
decision or imply that playback authority is still split.

## Scope and non-goals

This is a source-level behavioral study and architecture plan. It does **not**:

- change production playback behavior;
- copy mpv, FFmpeg, libass, or libplacebo implementation code;
- propose a legacy libmpv/OpenGL fallback;
- require feature parity with mpv's CLI, scripting, filter, or output ecosystem;
- treat a report as current when current source disagrees with it.

External repositories were checked out under `/tmp/superplayr-reference-src`,
outside the Superplayr worktree. They are analysis inputs only. Exact revisions,
licenses, and citation rules are in [SOURCE_PINS.md](SOURCE_PINS.md).

## How to read this set

| Document | Purpose |
| --- | --- |
| [SOURCE_PINS.md](SOURCE_PINS.md) | Exact source and toolchain baselines, license/provenance rules, history and issue references |
| [ARCHITECTURE_MAP.md](ARCHITECTURE_MAP.md) | mpv state machines, ownership, queues, invariants, teardown, and Superplayr's baseline topology |
| [LOADING_AND_DEMUX.md](LOADING_AND_DEMUX.md) | Open, probe, track discovery, buffering, packet ownership, damaged input, and dynamic streams |
| [SEEKING_AND_EOF.md](SEEKING_AND_EOF.md) | Seek modes, stale-state rejection, preroll, drain, EOF, looping, and replacement |
| [VIDEO_DECODING.md](VIDEO_DECODING.md) | Codec and VideoToolbox negotiation, fallback, frame lifetime, format changes, and corrupt frames |
| [AUDIO_AND_SYNC.md](AUDIO_AND_SYNC.md) | Clock ownership, A/V scheduling, underrun, rate, delay, format/device changes, and shutdown |
| [SUBTITLES.md](SUBTITLES.md) | Text/ASS/bitmap responsibilities, fonts, timing, track changes, geometry, and HDR composition |
| [ERROR_RECOVERY.md](ERROR_RECOVERY.md) | Fault taxonomy, recovery budgets, terminal policies, and user-visible outcomes |
| [PICTURE_QUALITY.md](PICTURE_QUALITY.md) | Apple direct display versus mpv/libplacebo and a product-value ranking |
| [DEPENDENCY_OWNERSHIP.md](DEPENDENCY_OWNERSHIP.md) | True behavior owners and delegation decisions |
| [SUPERPLAYR_GAP_MATRIX.md](SUPERPLAYR_GAP_MATRIX.md) | Baseline classifications plus current completion reconciliation and priorities |
| [TEST_FIXTURE_PLAN.md](TEST_FIXTURE_PLAN.md) | Pinned mpv-versus-Superplayr oracle harness and generated fixture matrix |
| [ARCHITECTURE_OPTIONS.md](ARCHITECTURE_OPTIONS.md) | Evaluated alternatives and why they were accepted or rejected |
| [RECOMMENDED_REFACTOR.md](RECOMMENDED_REFACTOR.md) | Target modules, state machines, milestones, acceptance criteria, risks, and omissions |

## Evidence model

External source citations use this form:

> `mpv:player/playloop.c::mp_seek @ 94335ab87ab225ca3e36e0faeac831639d3e1d4e`

Superplayr citations use the same form with its baseline SHA. A citation means
the behavior was inspected at that exact revision. It does not mean source was
copied. Where the behavior is primarily a dependency contract, the dependency
is cited even if mpv also coordinates it.

For compactness, a Superplayr path beginning with `Media/`, `Playback/`,
`Presentation/`, `Production/`, or `Subtitles/` is relative to
`Sources/SuperplayrNativePlaybackPOC/`; product-layer paths name their source
target explicitly when ambiguity would otherwise result.

Current source outranks the July 18 reports. For example, the report calls the
native implementation a qualified POC and the integration report describes a
legacy-default dual backend. Current source now includes more native integration
and tests, while the manual report still lists uncompleted physical checks.
Those reports remain valuable evidence, but not an authority for current
behavior.

## Bottom line

mpv demonstrates that a robust player is a coordination system around FFmpeg,
audio/video outputs, filters, clocks, and subtitle engines. Superplayr now has a
single deterministic playback authority around its macOS-native dependency
split. The next work is not another authority migration: it is the pinned
mpv/FFprobe oracle, self-verifying edge fixtures, differential scenarios, and
the remaining physical presentation matrix. The current sequence is in
[TEST_FIXTURE_PLAN.md](TEST_FIXTURE_PLAN.md); the completed refactor mapping is
retained in [RECOMMENDED_REFACTOR.md](RECOMMENDED_REFACTOR.md).
