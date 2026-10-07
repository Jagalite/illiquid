> Historical development note imported from `/Users/jagatranvo/Projects/superplayr/Documentation/PublicationAudit/VIDEO_TABS_PENDING.md`. Its dates, validation results and relative evidence links describe that checkout, not the reconciled build.

# Open video tabs — local draft, 2026-10-04

User requested open-video tabs and explicitly said not to push.
Changes are uncommitted and unpushed in the public checkout and mirrored into
corresponding development files without replacing unrelated private changes.
No new release or release-version bump was created.

A tab strip supports file/URL opens, switching, close buttons, a file-open plus
button, Cmd-T (open video), Control-Tab / Control-Shift-Tab (switch), and
Cmd-Shift-W (close video tab). Source-library tabs retain their separate action.
Video tabs keep per-session position, pause intent and playlist context. One
native engine is shared; tab activation uses the existing identified load path
and matching-source resume state. Closing the active tab chooses a neighbor;
closing the last stops playback. Closing a background tab leaves playback alone.
Video tabs now live in the native title bar; source/folder tabs live in the
sidebar above the file list. The sidebar follows interface scaling.

Added OpenVideoTabsTests and coordinator tab-activation/late-event tests.
Validation performed: Swift frontend syntax parsing, git diff --check, local
app build, packaging-helper checks, architecture validation, and 18 focused
tests covering tabs, launch opens, metadata, session persistence and migration.
The local app is ad hoc signed; notarization and manual UI validation are pending. GitHub CI was not triggered because
that would require publishing the draft. Do not claim the tab feature exists
in the published v0.1.3 DMG.

## Illiquid naming, 2026-10-04

The user requested renaming everything after seeing `swift run Superplayr`.
Active package/products/modules, source/test/validation directories, app type,
C shim symbols, scripts, environment variables, resource names, metadata and
CI/docs references now use Illiquid. Development launch is `swift run Illiquid`.
Only migration code/tests and immutable historical evidence retain old labels.
Legacy defaults are copied to Illiquid keys without overwriting newer values.
Session documents move by a one-time copy into Application Support/Illiquid;
the legacy file remains intact, and clearing a session does not import it again.
Private and public changes remain uncommitted and unpushed.

Focused test log: `/Volumes/seed2/Projects/illiquid-rename-tests-20261004-final.log`.
Local bundle build log: `/Volumes/seed2/Projects/illiquid-rename-app-20261004.log`.
Local bundle: `/Users/jagatranvo/Projects/illiquid-public/dist/local-tabs/Illiquid.app`.
This remains a local draft, not part of the published v0.1.3 DMG.

Renamed bundle rebuild completed successfully; arm64, 27 Mach-O images, native
dependency/provenance audits and ad hoc signature verification passed.

## Tab placement, 2026-10-04

User requested folder tabs in the sidebar and file tabs higher up.
SourceSidebarTabs now sits below the sidebar header with scrollable source
groups, selection, close, plus and existing context-menu behavior.
OpenVideoTabBar is hosted in the native title bar beside the traffic lights,
using the full available title-bar width. It stays available while playback
chrome fades. The separate top content row was removed.
Changes are mirrored to the public checkout and remain uncommitted/unpushed.
Local rebuild log: `/Volumes/seed2/Projects/illiquid-tabs-placement-app-20261004.log`.

Placement validation: local app rebuilt and bundle/dependency/signature audits
passed; 33 existing tests in four suites passed (window controls, sidebar folder
model, sidebar resize cancellation, and open-video tabs). Test log:
`/Volumes/seed2/Projects/illiquid-tabs-placement-tests-20261004.log`.
Manual visual verification of the relocated tabs remains pending.

## Closing the last video tab, 2026-10-04

The user found that closing the sole video tab left the file loaded.
The previous handler called Stop, which preserves shell media metadata and
playlist for replay. The close handler now uses closeCurrentVideo instead:
identified native stop/cancellation, saved-session clear, pending-media cleanup,
video-color reset, and one batched clear of shell source/playlist/track metadata.
Normal Stop retains its prior replay behavior. Stale callbacks remain fenced.
Regression tests cover loaded and pending opens, stale loaded/video events, and
Play after close not initiating another load. Public/private edits are local.
Validation logs: `/Volumes/seed2/Projects/illiquid-close-video-tests-20261004.log`
and `/Volumes/seed2/Projects/illiquid-close-video-app-20261004.log`.

Final close regression log:
`/Volumes/seed2/Projects/illiquid-close-video-tests-20261004-final.log`.
All 10 focused tests in two suites passed, including both loaded/pending cases,
late callbacks, clearing both restore targets, and Play not reloading closed media.

Close-fix bundle rebuild completed successfully at
`/Users/jagatranvo/Projects/illiquid-public/dist/local-tabs/Illiquid.app`:
arm64, 27 Mach-O images, dependency/provenance audits and ad hoc signature
verification passed. This is a local draft; no commit, push or release.

## Text contrast refresh, 2026-10-04

User reported unreadable black text in both tabs/sidebar and playback controls.
The shared dynamic text modifier now measures its CGRect independently of video
samples and derives sampling geometry each render from current sample/viewport/
clip metadata. It falls back to theme text until a valid region is available.
Folder tabs use local adaptive text rather than inherited primary text; legacy
playback controls use actual local bounds rather than the broad bottom region.
All sampled text retains an opposite-polarity edge for material/sampling mismatch.
Native title-bar text uses theme colors over an explicitly dark AppKit window,
not a video contrast sample from outside the video coordinate space.
Added bright/dark cut and source-reset palette/edge regression coverage.
Changes are mirrored into public source and remain uncommitted/unpushed.
Test log: `/Volumes/seed2/Projects/illiquid-text-refresh-tests-20261004.log`.
Bundle log: `/Volumes/seed2/Projects/illiquid-text-refresh-app-20261004.log`.
Manual visual verification remains pending.

Text-refresh validation: all 39 tests in three suites passed (adaptive palette,
glass legibility, native window controls), including the new scene-cut/reset
regression. Bundle rebuild is in progress; manual visual validation is pending.

Text-refresh rebuild completed and bundle/dependency/provenance/signature audits
passed (arm64, 27 Mach-O images). The first packaging attempt stalled during
Swift package planning and was terminated; the successful retry log is
`/Volumes/seed2/Projects/illiquid-text-refresh-app-20261004-retry.log`.
Local app: `/Users/jagatranvo/Projects/illiquid-public/dist/local-tabs/Illiquid.app`.
No commit, push, publication, or manual visual qualification performed.
