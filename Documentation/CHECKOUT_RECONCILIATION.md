# Checkout reconciliation — 2026-10-06

The runnable UI work in `/Users/jagatranvo/Projects/superplayr` had not reached
this checkout. This integration uses the current Illiquid checkout as the
destination and keeps the donor untouched.

- Destination base: `2e6d3ad4dbeeaa1e6e20940ff5fbbb4c549d6e57`, including its
  existing uncommitted click, startup-label, OSD and subtitle-reader fixes.
- Donor: `11e2d406` and its current working files. Its UI/module rename is in
  `0b81b79f`; the preceding source snapshot `e3e2c864` provided per-file
  three-way merge context. The repositories do not share Git commit ancestry.
- Before-change patches, input hashes, normalized comparisons, per-file
  decisions and validation logs are in `QualificationArtifacts/CheckoutReconciliation/`.

## Integrated

- Open video tabs in the native title bar, including file/URL opens, multi-file
  tabs, keyboard switching, close actions, and per-tab playback position,
  pause intent and playlist context using one playback engine.
- Source/folder tabs inside the Sources sidebar; removal of the old folder
  tab strip from the native title bar.
- Closing the last video cancels playback and clears its shell metadata and
  saved restore target; ordinary Stop still retains replay behavior.
- Progressive media-presence scanning, targeted filesystem repairs, manual
  rescan, and hiding folders confirmed to contain no supported media. Unknown
  or unreadable folders remain visible.
- Adaptive text geometry refresh and contrast edges, with theme colors for
  title-bar text outside the video sampling area.
- Illiquid package, module, C shim, script and environment names. Preferences
  migrate from legacy keys without overwriting existing Illiquid values; the
  playback-session document is copied once without deleting its original.
- Donor regression coverage for tabs, close-video fencing, scanner repair,
  contrast, migration, renderer-history equivalence and observation cadence.

## Retained from this checkout

The merge preserves the newer lifecycle policy, bounded global thumbnail cache,
background-thumbnail settings and admission, preview recovery, source-root index,
interactive source-preparation capacity, filesystem remount recovery, and the
subtitle-reader spin and seek-race fixes. It also preserves the current OSD
restyle and the native-video click-to-hide fix.

The renderer journal keeps this checkout's constant-size earliest-start/latest-end
representation. The donor's equivalence and million-sample regression tests
were adapted to it.

The current pinned FFmpeg `8.1.2-illiquid1` dependency receipts, matching source
package, production artwork, release identity/version, notarization workflow and
release packaging safeguards are retained. Older donor receipts must not replace
the build's actual dependencies.

## Deferred or historical

The donor's reviewed routine-enqueue cadence implementation and tests are
available, but the production session retains its current immediate coalescing
policy. Enabling the additional 60 Hz cadence remains deferred until optimized
release playback, high-frame-rate, PiP, variable-speed and long-EOF qualification.
The donor's synthetic delivery reductions are not whole-player CPU evidence.

Selected development notes are preserved under `ImportedDevelopmentNotes/`.
Their dates, claims, local artifact paths and relative evidence links describe
the donor checkout. Historical videos, generated benchmark outputs, publication
receipts and archived plans remain in the donor rather than being treated as
new source changes or current qualification.

The separately reproduced state-space test crash and the previously deferred
visible-window playback benchmarks remain outside the reconciliation's passing
test claims.


## Validation and runnable build

The combined release bundle is `/tmp/illiquid-reconciled/Illiquid.app`.
It is ad hoc signed for this Mac: arm64, 27 Mach-O images, successful native
input/dependency audit and code-signature verification. Executable SHA-256:
`1b8a299d7bbddb31e706016668adc169d04803de2dc86cb0a3cda598bb8ef111`.
No commit, push, notarization, release, or replacement of `/Applications/Illiquid.app`
was performed.

- Swift tests passed: **901 tests in 135 suites**, with `--no-parallel` and
  `--skip PlaybackStateSpace`. Six fixture/opt-in tests reported skipped;
  the known state-space crash remains excluded. This is not a claim of full
  media-performance or visible-window qualification.
- Architecture check passed.
- Packaging helper checks passed; performance-suite helper tests passed (10);
  native-dependency-lock helper tests passed (6).
- Corresponding-source verification passed: 28 source/resource/patch inputs and
  114 notice documents.
- All 1,317 inventoried donor files remain unchanged. The user's OSD edit matches
  the original exactly after module-name normalization; its top-right placement
  remains in PlayerRootView.
- Source conflict-marker scan and `git diff --check` passed.

The first packaging attempt compiled successfully but its Git provenance probe
hit a 30-second timeout on this external-volume checkout. Git status, diff and
untracked-input probes now have a bounded 120-second timeout; native-library
commands retain 30 seconds. Untracked Validation sources are included in the
provenance hashes. The subsequent complete packaging run passed. Final input
hashes and the bundle receipt are retained beside the logs.

A separate copy with the benchmark identity launched and played a generated,
silent H.264 fixture. Its window was on another Space and had no resolved AX
surface; the driver refused background input. Consequently this is launch and
playback smoke evidence, not a visual/interactive qualification of tab placement,
scrolling or text contrast. The [Cua Driver skill](skill://cua-driver/SKILL.md)
requires: “If background delivery is unavailable and foreground control is not
authorized, stop with the driver's refusal instead of silently escalating.”
Foreground takeover was not requested. The test process and temporary app were
removed, and the prior benchmark-domain preferences were restored. The user's
running production app was left alone.

After quitting your current Illiquid instance, launch the combined build with:

```sh
open -n "/tmp/illiquid-reconciled/Illiquid.app"
```
