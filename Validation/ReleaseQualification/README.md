# Restoration, visibility, fairness, and installed upgrades

## Evidence boundaries

`Scripts/test-restoration-regressions.sh` builds the actual Foundation-only
production types and the new core regression suites without resolving the native
application graph. It is not a full application build. The macOS PR workflow also
runs the AppKit lifecycle/scheduler suites with the native dependency setup.

`Scripts/tests/sparkle-install-smoke.py` exercises signed feeds and installation
using **two copies of one application** with different build numbers and a unique
throwaway bundle identifier. Its pass result is not evidence of state preservation
between historical packages. Keep that test; do not rename its result into an
installed-upgrade qualification.

The tests added here reproduce/fix ambiguous unchanged-file track restoration,
exercise notification wiring, and test scheduler progress with cancellation-aware
slow duration/decoder substitutes. They do not establish battery savings, reproduce
network-mounted starvation, or prove that historical releases lose user data.

## Installed-package matrix (release gate, not yet executed here)

Run in a disposable macOS user account or VM snapshot. Retain the original,
unmodified downloaded packages and their checksums. Record OS, architecture,
package version/build, bundle identifier, executable hash, installation method,
and UI observations. Verify that the installed application came from the recorded
artifact; the receipt tool cannot establish this relationship by itself.

Seed meaningful state through each older application's UI, quit it cleanly, and
export all relevant preference domains and session files. Include nondefault
volume/mute, theme/interface/shortcuts, source tabs, playlist/order/selected item,
resume position, selected audio/subtitles, subtitle visibility/delay, and thumbnail
preferences. Include the legacy domain/session where applicable. Never point this
procedure at a daily-use profile.

| Case | Required assertions | Status |
| --- | --- | --- |
| Latest prior release -> candidate, drag replacement | First launch and second launch preserve UI-visible state and exported values; no unexpected reset | Unrun |
| Oldest supported legacy-key release -> candidate | Current values win; missing values imported; legacy domain/session retained; second launch does not reimport | Unrun |
| Current-domain legacy keys -> candidate | Destination legacy aliases outrank older development-domain aliases; unrelated keys unchanged | Unrun |
| Historical signed update -> candidate, actual Sparkle route | Distinct packages, normal signing/feed path, installation succeeds and the same state assertions hold | Unrun |
| Interrupt first migration -> relaunch candidate | Check before publication, after session publication/before marker, and after preferences import; no truncated published session or overwritten current values | Unrun |
| Candidate -> supported older package -> candidate | Older app can read its retained state; later current state wins on return; no repeated legacy import | Unrun |
| Existing current state plus changed older-domain state | Document precedence explicitly; intentional non-reimport is not data loss | Unrun |

The migration unit tests inject a partial-copy failure and model the post-copy,
pre-marker restart state. They are **not** process-kill tests of installed apps.
A same-directory staged copy is published only after copying completes. An abrupt
kill can leave an unreferenced temporary file, but must not expose it as the session.
Already-existing destination files are not replaced or retroactively repaired.

## Read-only evidence snapshots

`installed_state.py` reads explicit exported files; it never installs, launches,
changes defaults, modifies sessions, or calls Sparkle. Use stable logical labels
for exports on both sides. Example inside the disposable test profile:

```sh
python3 Validation/ReleaseQualification/installed_state.py snapshot \
  --app /test/installed/Illiquid.app --package /test/artifacts/older.dmg \
  --preferences current=/test/before/current.plist \
  --session current=/test/before/session.json --output /test/before.json

# Perform the chosen installed-package operation, verify the UI, quit cleanly,
# and export state again; do not merely replace the receipt's version string.
python3 Validation/ReleaseQualification/installed_state.py snapshot \
  --app /test/installed/Illiquid.app --package /test/artifacts/candidate.dmg \
  --preferences current=/test/after/current.plist \
  --session current=/test/after/session.json --output /test/after.json

python3 Validation/ReleaseQualification/installed_state.py compare \
  --before /test/before.json --after /test/after.json
```

For legacy migrations, repeat `--preferences legacy=...` and `--session legacy=...`
for retained source state, and supply `--expected-state expected-current.json` to
require newly imported values in the current domain/session. The file is an
expected projection of the receipt's `state` object. Missing expected keys fail;
additive dictionary fields are allowed. JSON stored inside plist Data is exposed
under `$json_data`; opaque bytes are represented under `$base64_data`.

The comparison deliberately rejects the same executable or the same package,
even when build numbers differ. A pass establishes only the recorded state
comparison, not UI behavior, correct migration semantics outside the expectations,
signing provenance, or installed-package qualification. Review intentional
changes rather than removing inconvenient assertions. A mismatch requires
investigation and does not by itself establish permanent data loss. Receipts may
contain private paths and settings: keep them private or redact before publishing.

## Playback restoration qualification

| Case | Expected result | Coverage |
| --- | --- | --- |
| Unchanged file, two audio tracks with identical or absent metadata, choose ID 2, JSON save/load | ID 2 in both array orders | Core regression |
| Same test for subtitles; hidden subtitles and nonzero delay | ID 2; visibility and delay retained | Core regression |
| Renumbered tracks with distinctive metadata; old ID reused by another track | Better metadata match wins over old ID | Core regression |
| External subtitle with distinct filename, reused ID | Filename match wins | Core regression |
| Older JSON without stored ID | Reads successfully, retains deterministic metadata fallback | Core regression |
| Renumbered streams with ambiguous metadata | Best effort only; cannot assert exact identity | Explicit limitation |
| Quit/relaunch and close/reopen actual app with unchanged media | Verify selected audio and rendered subtitle content, not just IDs | Unrun full-app test |

A saved track ID is an unchanged-file tie-breaker, not a stable identity across
remuxing, stream reordering, or replacement. Exact restoration in those ambiguous
cases needs stronger stream/content identity; this PR does not invent one.

## Visibility qualification

Minimize/deminiaturize, hide/unhide, full occlusion/unocclusion, order-out/order-in,
close/reopen, and same-window reuse must update eligibility **without requiring a
playback-state transition**. Visible but inactive windows remain eligible.
The scene binds a window observer directly to the scheduler, so the AppModel's
window-presence input is intersected with actual visibility rather than confused
with it. Duplicate notifications must not keep resetting the idle timer.

Check both idle and playing media, including PiP. Visibility changes must not
pause playback, exit PiP, clear caches, or disable cached hover previews. Hidden
work remains opt-in and idle-only; normal power/thermal/memory/exclusion gates
still apply. AppKit tests control window visibility and inject slow operations;
real GUI playback/PiP/cache and battery/energy qualification remains unrun.

## Slow-file fairness qualification

The cursor advances **before** the first duration/decode await and survives
cancelled budgets. Ranking happens before the per-pass limit, so progress can
reach files beyond the old fixed prefix. Automatic current-video work participates
in the resumable library pass instead of spending every budget in front of it.
Library-only passes resume pending candidates without requiring another UI event.

The AppKit tests exercise slow duration probing and slow first-image decoding,
with automatic current preparation both enabled and disabled. They require
cancellation and eventual first-image progress on two later files, including one
beyond the original batch limit. Existing stale-completion, memory-pressure,
exclusion, and playback-cancellation tests remain in the targeted CI run.

For real local and network-mounted media, record per-file duration-probe and decode
start/end times, cancellation request/completion, first-image progress on later
files, cleanup, cache hits, native resource counts, and UI responsiveness. Test
slow/corrupt files, disconnected mounts, navigation during work, shutdown, and
repeated budgets. Confirm eventual progress while keeping one independent decode
at a time; don't mask stalls by accumulating abandoned timeout tasks.

**The work deadline is cooperative cancellation, not a hard wall-time bound on OS
I/O.** A native operation that never returns can still hold the pass. Full deep
refinement progress is also not a durable per-sample queue. Native interruption
latency, permanently blocked I/O, real network starvation, and energy impact are
not qualified by the cursor tests and remain explicit follow-up release checks.
