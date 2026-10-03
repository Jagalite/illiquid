# mpv reference qualification status

2026-09-04 update: the original findings below predate embedded PGS/DVD support.
`Scripts/generate-bitmap-subtitle-fixtures.py` now authors original bitmap
compositions and generated MKVs; `BitmapSubtitleTests` checks decoder pixels,
forced flags and seek restoration. DVB and external VobSub pairs remain
unsupported. This separate synthetic evidence does not mark the historical
real-media/mpv differential or physical-output gates as passed. See the current
[findings register](../ROBUSTNESS_REVIEW_MPV_IINA.md).

Status date: 2026-07-20. Foundation baseline: `99a49c9`.

The latest host run is retained under
`QualificationArtifacts/final-plan-verified-5/` (ignored by Git). Its
`qualification-summary.json` is the authoritative machine-readable gate
summary. The runner is reproducible with:

```sh
Scripts/run-mpv-reference-qualification.sh
```

## Implemented

- The fixture contract now accounts for every row in the required matrix: 33
  generated cases, five deterministic adapter cases, and three explicit blocked
  cases. Every generated media file has a hash, command, origin/license, FFprobe
  truth, and asserted property. Generation fails when required AV1 support or a
  truth assertion is missing.
- Added stable 8/10-bit AV1 and VP9, CFR/fixed-GOP, audio disposition, SSA,
  WebVTT, missing-glyph, video pixel/color change, audio rate/layout change,
  180/270-degree rotation, anamorphic SAR, BT.601/709 range, SDR BT.2020,
  chroma-siting, and interlaced TFF/BFF fixtures.
- Added fixture-derived semantic coverage for stream selection flags, AV1/VP9
  codec identity, audio converter revision/clock continuity, 90/180/270-degree
  geometry, anamorphic display geometry, external ASS/SRT/SSA/WebVTT, and
  missing-font fallback.
- Added WebVTT-to-ASS preparation and enabled `.ssa`/`.vtt` external subtitle
  intake. Unsupported bitmap subtitle extensions remain rejected.
- The dependency-ordered semantic matrix writes 21 live mpv/native artifacts,
  two in-process external-subtitle records, and one deterministic race-policy
  record. Unknown-duration input now reports unsupported seeking without
  aborting the rest of the run.
- Added deterministic commit barriers for video, audio, subtitle, rate change,
  dual A/V EOF, hardware failure, open, seek, decode, presentation, and blocked-
  input cleanup. Queue invalidation now revokes producers waiting on obsolete
  data capacity. Added deterministic staged-input retry, exhaustion, and
  cancellation.
- Added machine-readable deterministic race, semantic-policy, and acceptance
  reports. Track commit/rollback, subtitle delay, final near-EOF seek, malformed
  IDs, bitmap capability, quiescence, and every acceptance threshold are
  executable contracts rather than prose-only rows.
- Non-zero-origin chapters are normalized into product time and reflected
  display matrices no longer become spurious 180-degree rotations. TFF/BFF and
  unsupported bitmap codecs produce explicit product policy; invalid native
  track IDs cannot trap during narrowing.
- Expanded the common result schema with hardware configuration/actual output,
  staged EOF timing, track switch, subtitle, memory/queue, and recovery facts.
- Renderer readiness and EOF are derived from renderer-clock crossings after an
  accepted enqueue. Enqueue alone remains explicitly `unmeasured`. The native
  renderer command is wired through the real presentation coordinator.
- Added one-command collection for hardware/software identity, fixture checks,
  Homebrew and pinned-oracle attempts, renderer smoke, 50-cycle normal/ASan/TSan
  replacement stress, all Swift tests, architecture validation, app packaging,
  signature verification, packaged-app launch, and the physical qualification
  questionnaire.
- The qualification runner rejects a pre-existing artifact destination so an
  acceptance report can never consume stale `result.json` files from an older
  semantic run.
- Required automated gates now determine the runner's exit status from the
  immutable per-gate exit-code artifacts; a failed fixture,
  semantic/acceptance report, sanitizer build, Swift test, architecture check,
  app build, or signature check cannot leave a successful top-level
  qualification command.

## Latest automated results

The latest run was on a MacBook Air `MacBookAir10,1`, Apple M1, 8 GB, macOS
26.5.2 (`25F84`).

| Gate | Result |
| --- | --- |
| Fixture manifest and truth | pass |
| Homebrew mpv semantic matrix | 21 artifacts written; executable is explicitly unpinned |
| Combined acceptance ledger | 7 pass, 0 fail, 4 renderer-only gates unmeasured |
| Deterministic races | 11 of 11 scenarios pass |
| Deterministic semantic policies | 6 of 6 scenarios pass |
| Swift tests | 153 tests in 21 suites passed |
| Fixture-required semantic tests | 26 tests in 1 suite passed |
| Architecture validation | pass |
| App build and signature verification | pass |
| Pinned mpv build/parity | blocked before build |
| Native renderer smoke | host abort, exit 134 |
| Packaged-player smoke | host abort, exit 134 |
| Normal 50-cycle replacement stress | build pass; host abort before cycle one |
| ASan 50-cycle replacement stress | sanitizer build pass; host abort before cycle one |
| TSan 50-cycle replacement stress | sanitizer build pass; host abort before cycle one |

The Homebrew matrix is useful differential evidence but is not pinned-oracle
parity. Video-backed disagreements carry explicit dispositions because this
host rejects VideoToolbox/CoreVideo output allocation; audio-only results still
run through both players normally. The combined acceptance ledger merges those
live artifacts with deterministic evidence: all 21 measured selected-stream
cases match the product-configured oracle and the worst exact-audio floor emits
no pre-target sample. Exact decoded-video landing, steady renderer A/V,
renderer-drained EOF, and 50-cycle memory remain unmeasured.

## Remaining blocked or unmeasured items

- **Pinned oracle:** the exact mpv source checkout is present at revision
  `94335ab87ab225ca3e36e0faeac831639d3e1d4e`, but Meson is absent. Homebrew
  installation is denied by the managed filesystem lock, and direct download
  is denied by restricted DNS. No pinned parity result is claimed.
- **Apple renderer and actual-player gates:** this host throws
  `NSInvalidArgumentException` from
  `AVSampleBufferRenderSynchronizer.addRenderer` when the audio renderer is
  attached. The same exception blocks the renderer smoke, actual packaged app,
  and all three replacement stress runs before presentation begins. Fixture-
  required video decoding also observes `CVReturn -6662` when software pixel-
  buffer allocation is attempted.
- **Memory slope and 50 successful replacements:** the runner records RSS and
  sanitizer logs, but the renderer abort prevents any replacement cycle, so the
  acceptance threshold is unmeasured rather than passed.
- **Bitmap subtitle composition:** PGS, VobSub/DVD, and DVB assets remain
  provenance-blocked. The repository has neither a truthful composition
  authoring path nor a pinned CC0 fixture; the installed FFmpeg encoders cannot
  generate these assets. Their unsupported product capability is explicit and
  cannot silently select a no-output text path.
- **Presentation-only properties:** midstream video reconfiguration, chroma
  reconstruction, actual interlaced source-field presentation, color/HDR/HLG
  output, first visible/audible readiness, and renderer-drained EOF remain
  blocked on a host that can construct valid sample-buffer renderers.
- **Physical qualification:** built-in/external SDR/EDR/HDR, speakers,
  headphones, HDMI/USB/wireless audio, sleep/wake, display reconnect,
  fullscreen, PiP, subjective scaling/subtitle/color grades, power, and thermal
  behavior are explicitly `unmeasured`; they require devices and human grading.
- **External subtitle live-oracle attachment:** conversion/rendering is covered
  in-process, but combined runtime attachment to both live players remains a
  separate renderer-capable-host measurement.
- **Font redistribution:** the embedded system-font fixture remains explicitly
  local-only, as permitted by the plan. It is not a redistributable committed
  asset.
