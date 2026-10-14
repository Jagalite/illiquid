# Playback product work: partial implementation and qualification

Status: **partial; draft, not the completed product request**. Updated October 14, 2026.

Branch: `feat/playback-reliability-tools`, based on the still-unmerged
`fix/track-restoration-thumbnail-lifecycle` branch at `a753599e` (PR #1).
Neither PR #1 nor this branch was merged. No release or installed-user-state
mutation was performed.

## Committed scope

| Area | Delivered in this branch | Not yet delivered here |
| --- | --- | --- |
| Preference isolation | Volume/speed setters preserve history and restore-paused flags. Real-store tests exercise all ten setters and four flag combinations through flush/reload. | Full application privacy task qualification. |
| Per-file preferences | Sparse override model for tracks/languages, subtitle delay, speed and audio delay; explicit inheritance; legacy Off/zero decoding. | Coordinator application of the new speed/audio-delay/language fields and the new reset/inherit UI. |
| Caption navigation | Bounded text cues, search, delay-aware targets, cue replay and deterministic sentence grouping; external text parser and independent embedded-text decoder. | Player-facing transcript UI, jump/replay command wiring and source-scoped UI cancellation. |
| Native automation | Bounded local-file input validation, order-preserving deduplication, and versioned media/time reference serialization. | Acknowledged coordinator open/enqueue actions, App Intents adapters, metadata packaging and real Shortcuts qualification. |
| Recovery | Existing PR #1 migration fixes are inherited; selected existing coordinator regressions are exercised. | New checkpoint gating, serialized track restoration, failed-item Locate and interrupted-source recovery integration. |
| Seek and lifecycle | Existing seek/coordinator, PiP policy, renderer observation, authority fences and thumbnail lifecycle regressions are included in macOS CI. | New end-to-end rapid-scrub/display, physical sleep/wake, disconnected-volume and energy qualification. |

The core models and native caption reader are **not** equivalent to shipping
all requested features. Bitmap subtitles do not gain OCR. Sentence grouping is
a bounded subtitle-text heuristic, not speech recognition. Native cancellation
and scan budgets are not a hard guarantee that a blocked operating-system I/O
call has stopped.

## Recorded tests

**Tested source commit:** `9dde96b68a2e4d74a93ed87a8f4b42c0919d7560`.

[macOS CI run 38576537233](https://github.com/Jagalite/illiquid/actions/runs/38576537233)
completed successfully. The pinned dependency setup, small fixture generation,
full app/test dependency build and link, and selected test invocation succeeded.
The runner reported Apple Swift 6.3.3, arm64 macOS 26, and **167 tests in 17 suites
passed**. `realMediaTextSubtitleSeeksRemainUsable` and
`realMediaCancelledSubtitleReadsRecover` were explicitly skipped because their
separate real-media inputs were unavailable. The generated embedded-caption,
external-text, signed-audio-delay and selected lifecycle tests did execute.

The local Linux core-only run reported **110 tests in 27 suites passed**. It
uses actual source in the portable harness and excludes Darwin catalog scanning
and UI observation. These counts contain existing regressions and overlap the
macOS invocation: they are neither all-new tests nor additive totals. A full
all-target/state-space test run was not completed in this work.

The original volume/speed setters failed the new real-store preference regression;
the corrected setters passed. Invalid scalar, malformed reference, ambiguous
file-URL, caption bound, malformed ASS and legacy-settings cases are covered.

Reproduce the scoped portable run with:

```sh
bash Scripts/test-portable-playback.sh --filter IlliquidCoreTests
```

The macOS workflow records its exact filter, revision and toolchain, and uploads
the test log as `playback-product-macos`. Inspect skipped and environment-gated
tests rather than treating a green filtered run as complete native qualification.
Inspecting App Intents tool help in CI does not build or register App Intents.

## Commit review ledger

| Commit | Review and outcome |
| --- | --- |
| `1864da35` | Checked pinned actions, read-only permissions, branch scope and native SDK setup. Initial macOS baseline passed. |
| `3d0aadc7` | Checked scalar-only mutation, sanitization, all-field equality and actual store reload tests. Native CI exposed a portability regression: Foundation alone did not supply macOS CoreGraphics overlays. |
| `2d074068` | Restored the conditional CoreGraphics import while retaining Linux compatibility. Included in the final successful native build. |
| `22b1820b` | Checked legacy settings semantics, finite/bounded values, caller order, future reference schemas, file-URL boundaries, ASS parsing complexity and inverse subtitle-delay mapping. A null-byte URL test exposed Foundation representation differences; validation was corrected before this commit. |
| `7b2d29ff` | Checked independent caption input ownership, bounded output, partial-index reporting, cancellation and generated fixtures. Native CI exposed use of a failable subtitle decoder without unwrapping. |
| `9dde96b6` | Explicitly unwrap the throwing/failable decoder and report decoder unavailability. The complete filtered macOS run passed after this correction. |

This is a self-review record, not an independent reviewer approval. Intermediate
failing revisions remain visible with explicit correction commits.

## Uncommitted integration work

A separate 12-file development patch was retained with the conversation work
bundle. Its base is exactly `9dde96b68a2e4d74a93ed87a8f4b42c0919d7560`.
It contains candidate checkpoint/restore/recovery coordination, per-file
application, caption UI, ordered automation, App Intents types and transaction
tests. It is **not part of this PR** and must not be inferred from the feature
models in the branch.

The patch passed `git diff --check`, an apply check against the exact source
base, and Swift syntax parsing. It was **not** typechecked, linked or run as a
complete macOS application. App Intents metadata extraction/packaging remains
unimplemented even in that candidate. Its transaction tests have not run.

## Remaining acceptance gates

1. Build and test the integrated coordinator/native/AppKit/SwiftUI changes; review
   each remaining source commit and resolve failures before publishing it.
2. Inject termination after source commit and before resume seek acknowledgement;
   retain the last valid checkpoint through failed retry/Locate and drive loss.
3. Qualify A-to-B-to-A track choices, external subtitles, Off versus Automatic,
   per-file speed/audio delay, reset/inherit and disabled history.
4. Add metadata generation to the packaged app and test actual Shortcuts
   open-at-zero, ordered enqueue, cancellation and reference resolution.
5. Measure final displayed timestamps and responsiveness during rapid scrubbing;
   run real PiP/hidden-window/sleep/wake, accessibility and energy checks.

No process-kill, physical mount/NAS, installed historical upgrade, display/PiP,
Shortcuts registration, accessibility or battery qualification is claimed.
