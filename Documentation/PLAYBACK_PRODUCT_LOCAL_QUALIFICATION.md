# Illiquid playback product — local agent qualification and handoff

**Purpose:** finish the macOS and physical qualification for [draft PR #3](https://github.com/Jagalite/illiquid/pull/3) on top of [PR #1](https://github.com/Jagalite/illiquid/pull/1). Review and repair defects in isolated commits; do not merge, notarize, publish an update feed, or mutate installed-user data merely because a filtered CI run passes. The source integration has been pushed; there is no remaining conversation-only patch to apply.

## 1. Check out the exact work

```sh
git fetch origin feat/playback-reliability-tools fix/track-restoration-thumbnail-lifecycle
git switch --track origin/feat/playback-reliability-tools  # or switch an existing local branch
git status --short
git log --oneline -10
git merge-base --is-ancestor origin/fix/track-restoration-thumbnail-lifecycle HEAD
```

Record `git rev-parse HEAD`, `swift --version`, `xcodebuild -version`, macOS build, CPU architecture and pinned native SDK manifest. PR #3 is stacked on still-unmerged PR #1. Do not apply the old handoff `.patch` a second time. Keep generated app bundles in disposable locations.

## 2. Automated gates

```sh
# Core portable tests (Linux or macOS; includes bounded state-space model exploration):
bash Scripts/test-portable-playback.sh

# Focused track/thumbnail/migration tests using explicit macOS platform:
bash Scripts/test-restoration-regressions.sh

# Compiler and packaging metadata regressions:
python3 Scripts/tests/app-intents-metadata-tests.py -v

# On macOS 26 with the pinned native dependencies, build the entire app and run all tests:
swift test --force-resolved-versions --no-parallel

# Reproduce the focused product regression filter and fixtures:
fixture_dir="$(mktemp -d /tmp/illiquid-product-fixtures.XXXXXX)"
bash Scripts/generate-product-fixtures.sh "$fixture_dir"
ILLIQUID_PRODUCT_FIXTURES="$fixture_dir" \
ILLIQUID_NATIVE_FIXTURE_DIR="$fixture_dir" \
  swift test --force-resolved-versions --no-parallel --filter \
  'PlaybackCoordinatorTests|TrackRestorationRegressionTests|InterruptedMigrationRegressionTests|ThumbnailSchedulingPolicyRegressionTests|ThumbnailLifecycleRegressionTests|ThumbnailBackgroundSchedulerTests|PlaybackProduct|CaptionNavigation|PlaybackAutomation|MediaPlaybackSettings|PlaybackPersistence|AudioDelayTests|RuntimeAuthorityFenceTests|NativePictureInPictureTransitionTests|RendererObservationBoundsTests|SubtitleSeekRegressionTests'
```

`Scripts/install-ci-native-sdk.py` runs in the GitHub macOS jobs after source verification. Follow `Documentation/BUILDING.md` / `DISTRIBUTING.md` on a local machine. Separate missing-fixture skips from real passes. Do not count overlapping suites twice.

## 3. Build the app and inspect generated Shortcuts metadata

```sh
qualification_dir="$(mktemp -d /tmp/illiquid-qualification.XXXXXX)"
bash Scripts/build-illiquid-app.sh --unsigned --output "$qualification_dir"
app="$qualification_dir/Illiquid.app"
test -x "$app/Contents/MacOS/Illiquid"
python3 Scripts/app-intents-metadata.py validate "$app/Contents/Resources"
find "$app/Contents/Resources/Metadata.appintents" -type f -maxdepth 3 -print
```

Check that Apple-generated `.actionsdata` contains `OpenMediaAtTimeIntent`, `EnqueueOrderedMediaIntent`, `GetPlaybackReferenceIntent` and `OpenPlaybackReferenceIntent`. The packaging script must fail if the compiler constants or generated action catalog is absent. Repeat the build with a reusable `ILLIQUID_BUILD_ROOT` and inspect the new `app-intents/compile.*` output directory: a cached build must not silently reuse stale metadata. Verify temporary unsigned/ad-hoc packaging before any Developer ID signing. Confirm no new settings were written into an existing installed copy.

## 4. Manual acceptance matrix — record actual observations

| Area | Steps and required evidence |
| --- | --- |
| Crash/quit resume | Open a local video, accept position, force-terminate at idle and during a new source load/seek. Reopen: only an acknowledged position is retained, never a speculative target. Repeat after a failed resume and app restart. |
| Drive removal / moved file | Queue A and B on a removable volume, disconnect during active playback and during a pending playlist transition, retry, Locate to an identical/moved file and reject mismatched content. A cancelled/stale Locate panel must not hijack a newer source; positions and queue order remain intact. Repeat with slow NAS I/O; record timeouts/blocking. |
| Audio/subtitle identity | Choose second same-metadata track in A, switch to B, then A; close/reopen/quit/relaunch. Test subtitles Off vs Automatic, language fallback, explicitly chosen external SRT/ASS, no-audio media and stream-order changes. Manual track changes must supersede stale queued restores. |
| Per-file overrides | On A select speed, audio delay, subtitle delay and preferred tracks; on B select different values. Reopen A/B. Test inherit/reset commands, saved disabled-history preference, and legacy JSON migration. A global change must not erase unrelated per-file overrides. |
| Caption search and jump | SRT and ASS with formatting, embedded text stream, malformed or partial cues, disabled/bitmap-only subtitles, cue search (case/diacritic), jump, replay prior cue and prior sentence; verify delay-aware seek time. Change source/cancel index during read: no stale captions or unintended seek. |
| Rapid scrubbing | Long-GOP H.264/HEVC, repeated left/right/drag and fast reversals, paused and playing, including beginning/end boundary and mixed track changes. Compare the **displayed frame's observed PTS** to the final exact request; no stale frame, stall or optimistic checkpoint. |
| Picture-in-Picture/window lifecycle | Enter/exit PiP, minimize/restore, hide/unhide, close playback window while PiP remains active, occlude window with another application; verify playback/renderer continuation, idle thumbnail exclusion and no hidden wasted drawing. Repeat after sleep/wake, display disconnect/reconnect and audio device switch. |
| Shortcuts: open at time | Install an isolated build, open Shortcuts, discover the four actions; run open at 0 and a nonzero time, paused/unpaused, while app closed and open; action should finish after load/seek settles and return a usable reference. |
| Shortcuts: ordered enqueue | Supply 3+ files in a non-lexicographic order, with duplicates and a missing/unreadable file. Preserve caller order, deduplicate, and reject invalid batches without partial queue mutations; verify action cancellation and stale generation fences. |
| Shortcuts: references | Get current reference before/during/after seek; no optimistic time. Reopen valid reference; replace bytes/change metadata, move or delete media, or revoke a security-scoped URL, then attempt reuse: clear failure without opening wrong content. Inspect shared reference for pathname privacy, not a capability/grant. |
| Accessibility | VoiceOver focus order and names for new captions, override controls, dialogs; keyboard-only navigation, cancellation and restored focus. |
| Energy / resources | Profile idle visible, occluded, minimized, hidden and PiP-only states for CPU/GPU/thumbnail provider calls and memory. Compare to a clean PR #1 baseline on same hardware and file corpus; no battery benefit claim without measurement. |

Record file codec/stream layout, exact reproduction sequence, expected/actual result, event IDs/observed PTS, logs, commit SHA, and whether a failure is source-specific. For OS-blocked file operations, do **not** claim a hard I/O deadline from a cooperative cancellation token.

## 5. Publication criteria and known boundaries

Review each changed commit (`git show --check`, diff, test selection, native build/packaging evidence), update tests before modifying behavior, and rerun relevant suites after a fix. Require all relevant CI jobs green at the final SHA and a real installed-app Shortcuts registration smoke test. Keep PR #3 a **draft** until local device, volume and packaging gates pass. PR #1 must be reconciled/merged before rebasing PR #3 to `main`.

Unsupported by design: bitmap subtitle OCR; exact restoration when ambiguous stream identities change; hard OS/network-file I/O deadlines. Caption sentence grouping is heuristic. The existing filtered test count is not proof of physically correct rendering or absence of energy regressions.

Record native failures, missing fixtures and skipped cases in PR #3 instead of silently changing the checklist status. Do not publish a production release or Sparkle update feed as part of qualification.
