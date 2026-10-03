# mpv differential harness

2026-09-04 update: the original findings below predate embedded PGS/DVD support.
`Scripts/generate-bitmap-subtitle-fixtures.py` now authors original bitmap
compositions and generated MKVs; `BitmapSubtitleTests` checks decoder pixels,
forced flags and seek restoration. DVB and external VobSub pairs remain
unsupported. This separate synthetic evidence does not mark the historical
real-media/mpv differential or physical-output gates as passed. See the current
[findings register](../ROBUSTNESS_REVIEW_MPV_IINA.md).

`SuperplayrDifferentialHarness` is a test-only executable. It does not link mpv
into the product. It can run the same generated fixtures through mpv JSON IPC
and Superplayr's native FFmpeg path, compare normalized semantic results in
dependency order, exercise the real Apple presentation coordinator, and write
immutable artifact directories. The original H.264/AAC smoke remains available
as the smallest end-to-end check.

The artifact contains:

- `result.json` and `run-manifest.json`;
- the unmodified timestamped `mpv-ipc.jsonl` stream;
- `mpv.log` and `superplayr.log`;
- `fixture.ffprobe.json`;
- `normalized-timeline.txt`; and
- `fault-policy-records.json` for deterministic faults that a live mpv process
  cannot inject honestly.

The common player result also carries hardware request/configuration/actual
output, demux/decoder/resampler/presentation EOF timing, track-switch outcome,
subtitle capability/output, memory/queue facts, and typed recovery. A fact that
the selected runner cannot observe stays absent with a limitation; enqueue is
never substituted for presentation.

## Fixture provenance and truth

`Scripts/generate-native-fixtures.sh` writes `fixture-manifest.json` and a
`Truth/` FFprobe dump per fixture. Manifest creation fails unless every file has
a SHA-256, generator command, license/origin, a truth dump, and passing
assertions. The self-checks currently prove:

- stable 8/10-bit AV1 and VP9 identities and CFR/fixed-GOP controls;
- irregular VFR timestamp deltas;
- positive and negative packet origins, including all 90 negative-origin frames;
- non-monotonic packet timestamps;
- unknown raw-stream duration;
- deterministic corrupt-packet and truncated-input diagnostics;
- an audio tail that extends beyond video;
- multiple decoded video sizes/pixel-color configurations and audio formats;
- audio default/commentary disposition flags;
- anamorphic SAR, BT.601/709 range, SDR BT.2020, chroma siting, and TFF/BFF
  interlace metadata; and
- external SSA/WebVTT plus missing-font input.

The embedded system-font fixture is explicitly `local-only` and is not claimed
as redistributable. No system font is copied into Git.

Generate and verify with:

```sh
SUPERPLAYR_NATIVE_QUALIFICATION_DURATION=60 \
  Scripts/generate-native-fixtures.sh TestFixtures/Generated

.build/debug/SuperplayrDifferentialHarness verify-fixture-manifest \
  --directory TestFixtures/Generated

.build/debug/SuperplayrDifferentialHarness fixture-matrix \
  --directory TestFixtures/Generated
```

The fixture matrix contains every required plan row. A row must provide
generated file paths, deterministic adapter evidence, or a blocker. PGS,
VobSub/DVD, and DVB are blocked because neither a truthful authoring tool nor a
pinned CC0 source is available. The embedded system-font case remains
explicitly local-only.

## Semantic and renderer runs

Run the dependency-ordered semantic matrix with an installed mpv:

```sh
.build/debug/SuperplayrDifferentialHarness semantic-matrix \
  --directory TestFixtures/Generated \
  --output QualificationArtifacts/semantic-matrix \
  --mpv /opt/homebrew/bin/mpv
```

An unpinned executable is hashed and identified but cannot claim pinned parity.
When using an executable built by `Scripts/build-pinned-mpv-oracle.sh`, also
pass `--mpv-source-revision 94335ab87ab225ca3e36e0faeac831639d3e1d4e`.

Renderer-backed readiness and EOF use renderer-clock crossings, never enqueue
timestamps. Exercise that path with:

```sh
.build/debug/SuperplayrDifferentialHarness native-renderer-smoke \
  --fixture TestFixtures/Generated/h264-aac.mp4 \
  --output QualificationArtifacts/native-renderer-smoke
```

The full host qualification, including 50-cycle normal/ASan/TSan stress and the
actual packaged player, is automated by:

```sh
Scripts/run-mpv-reference-qualification.sh
```

The runner exits nonzero if fixture truth, deterministic reports, the Homebrew
semantic/acceptance run, sanitizer builds, Swift tests, architecture validation,
or package verification fails. Pinned-oracle, renderer, replacement-run, and
physical gates retain explicit blocked or unmeasured results when the host
cannot execute them.

The deterministic prerequisites and threshold ledger can also run without a
display or audio device:

```sh
.build/debug/SuperplayrDifferentialHarness deterministic-races \
  --output QualificationArtifacts/deterministic-races.json

.build/debug/SuperplayrDifferentialHarness deterministic-semantic-policies \
  --output QualificationArtifacts/deterministic-semantic-policies.json

.build/debug/SuperplayrDifferentialHarness deterministic-acceptance \
  --output QualificationArtifacts/deterministic-acceptance.json

.build/debug/SuperplayrDifferentialHarness acceptance-report \
  --matrix-directory QualificationArtifacts/homebrew-semantic-matrix \
  --output QualificationArtifacts/acceptance-report.json
```

The deterministic report intentionally leaves six live/physical gates
unmeasured. The combined report adds selected-stream and exact-audio-floor
evidence from completed semantic artifacts; it still does not claim renderer
drain, physical A/V, decoded-frame parity, or replacement RSS when those facts
are absent.

See [QUALIFICATION_STATUS.md](QUALIFICATION_STATUS.md) for the latest evidence
and explicit blockers.

## Oracle identity

The required mpv source revision remains
`94335ab87ab225ca3e36e0faeac831639d3e1d4e`. Build it with:

```sh
Scripts/build-pinned-mpv-oracle.sh
```

The build script verifies the source checkout revision before configuring or
building. A run may claim that source revision only when it passes both the
built binary and `--mpv-source-revision` to the harness. Otherwise the manifest
sets the executable revision to `null`, records the expected source pin
separately, hashes the actual binary, and marks the binary revision unverified.

On the managed Mac environment used for the initial implementation, the exact
source checkout was present and verified, but Meson was not installed and
restricted DNS prevented installing it. The retained development smoke therefore
used the installed Homebrew mpv and must not be described as a pinned-binary
parity result.

## Environment limitations

Automated semantic runs are named `headlessSemantic` and record `--vo=null`,
`--ao=null`, and `--hwdec=no` for mpv. It does not claim visible or audible
readiness or renderer-drained parity.

The managed XCTest/executable environment also rejected VideoToolbox setup and
CoreVideo software pixel-buffer allocation (`CVReturn -6662`). The native runner
retains that exact failure, continues the audio floor and input/drain checks,
and requires an explicit `nondeterministicPlatformBehavior` disposition. It
does not convert the missing video observation into a pass.

The freshly packaged `Superplayr.app` was also launched directly with the
generated H.264/AAC fixture. This managed host rejected
`AVSampleBufferRenderSynchronizer.addRenderer` for the audio renderer with
`NSInvalidArgumentException`, before presentation could begin. The same process
accepted both the video renderer and display layer in isolation. This is an
observed host/audio-session limitation, not proof about display timing, audio
output, or physical hardware behavior.

Filesystem Unix-socket binding was unavailable in the same environment. The
harness therefore uses mpv's documented `--input-ipc-client=fd://0` over an
inherited bidirectional socket pair. This is real JSON IPC and preserves every
request, response, property event, and monotonic receive timestamp.

Display, EDR/HDR, audio route, physical audibility, sleep/wake, fullscreen,
PiP, and external-device results remain `unmeasured`. They belong to the
release physical matrix and cannot be proven by these artifacts.
