# Playback reliability and product features — PR #3 integration status

Updated October 15, 2026. **Integrated source pushed; PR remains draft pending full macOS package and physical qualification.**

Pull request: https://github.com/Jagalite/illiquid/pull/3

This branch is stacked on [PR #1](https://github.com/Jagalite/illiquid/pull/1), which is **still unmerged** and provides the upstream track-ID restoration, thumbnail window lifecycle, slow-probe fairness, and migration fixes. Do not accidentally rebase against `main` while PR #1 remains open. Neither branch is a released application.

## Included implementation

| Area | Committed functionality | Boundaries |
| --- | --- | --- |
| Privacy and session preferences | Individual preference setters preserve disabled history and restore-paused choice; real-store round-trip regression across all ten setters. | A manual installed-app privacy audit is still required. |
| Crash resume and recovery | Avoid optimistic checkpoint writes during unsettled load/seek; source-scoped recovery and Locate for failed queued media, with stale-panel rejection. | Process-kill windows, detached volumes, slow NAS I/O and retry after sleep require physical testing. |
| Audio/subtitle restoration | Sequenced track selection and session acknowledgement; explicit saved Off/Automatic behavior and manual override supersession. | Ambiguous remuxed/renumbered stream identity remains best effort. |
| Per-file playback preferences | Sparse override model and application for audio/subtitle, playback speed, subtitle delay and audio delay; inherit/reset UI controls. | Verify exact UI behavior and persistence on a real installed app. |
| Caption navigation | Bounded SRT/ASS/embedded text indexing, search, jump-to-cue, previous-cue/sentence replay and source-scoped cancellation. | No bitmap OCR; sentence grouping is heuristic, not ASR. Blocking file I/O has no hard deadline. |
| Native automation | Four App Intents for timestamped open, ordered enqueue, current playback reference and reopen reference; acknowledgement-based coordinator/queue; explicit invalid/replaced-file failures. | Shortcuts discovery, file authorization across launches, and installed-app registration remain unqualified. |
| Seek, window and PiP lifecycle | Existing tests and additional transaction/seek guards exercise deterministic policy and selected native boundaries. | Final presented frame, minimized/occluded-window energy, actual PiP and sleep/wake require hardware. |
| Packaging | Real compiler constant emission and Apple App Intents metadata extraction with fail-closed catalog verification before signing. | App bundle metadata generation has **not yet passed final CI qualification** for this pushed revision. |

## Test evidence

- Exact locally applied source patch verified against the `9dde96b` repository snapshot, with all 16 resulting blob hashes independently confirmed on GitHub after push.
- Current Linux actual-source portable playback: **179 passing tests in 33 suites**, including the bounded state-space explorer. The harness excludes the macOS app UI, renderer and certain Darwin facilities.
- Current local packaging metadata unit tests: **6/6 passed**, including recompilation into a new compiler-constants output path without SwiftPM manifest caching.
- Prior native macOS integration candidate: **148 tests in 13 suites passed**, including transaction restore, seeks, caption navigation and automation; see the saved development handoff log. The previous release assembly compiled the product but failed before extracting App Intents metadata because SwiftPM omitted the expected `.swiftconstvalues`; this branch includes the output-directory and manifest-cache corrections. **That prior native run is not a pass claim for the new release packaging revision.**
- PR #3 CI triggered after integration was pushed on October 15; inspect the results for the exact HEAD SHA before promoting out of draft.
- A separate restoration-harness CI failure originated from missing explicit macOS platform deployment in the temporary Swift package; setting `.macOS(.v13)` passed all **14 regression tests in 3 suites** locally. The corrected harness is included in the next qualification commit.

These runs overlap and are not additive. A filtered test run is not equivalent to an end-to-end release qualification or an actual Shortcuts-registration test.

## Integration commit review

- `1864da35` through `9dde96b6`: foundational CI, persistence, sparse preferences, caption source, native reader and regression work. Intermediate failures were corrected in follow-up commits; history preserved.
- `1b83d2d4`: integrate coordinator recovery and transaction fences, caption UI, per-file override application, App Intents types, and native automation/transaction tests. The resulting 12 blobs were checked byte-for-byte against the saved candidate at this development stage.
- `3491e34d`: add the final native transaction changes, app packaging compiler constants, Apple metadata extraction and strict validation; all 16 final blobs matched the tested local patch hashes.
- Subsequent qualification-only commits should record their own failure reproduction, repair and rerun results before changing PR draft status.

This is a self-review ledger, not an independent review or physical-qualification claim.

## Remaining gates and local agent handoff

Follow [`PLAYBACK_PRODUCT_LOCAL_QUALIFICATION.md`](PLAYBACK_PRODUCT_LOCAL_QUALIFICATION.md) for exact commands, test matrix, and evidence collection. At minimum: clean native app build, unsigned bundle with `.actionsdata`, all native tests, manual crash/reopen/moved-volume/track/seek/PiP/sleep cases, installed-app Shortcuts actions, accessibility and energy measurements. Record every failure and its fix in commits and rerun tests. Do **not** merge PR #3 until its dependency PR #1 and qualification gates are addressed.

No new app release, production signing, notarization, update feed, or mutation of an existing installed user's playback state is part of this work.
