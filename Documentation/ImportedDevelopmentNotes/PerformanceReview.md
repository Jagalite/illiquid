> Historical development note imported from `/Users/jagatranvo/Projects/superplayr/Documentation/PERFORMANCE_REVIEW.md`. Its dates, validation results and relative evidence links describe that checkout, not the reconciled build.

# Playback performance fixes

Latest review fixes: [enqueue scheduling race and overdue timer](Qualification/Performance/2026-10-05-observation-review/README.md).
182 tests, architecture checks and 36 debug-app seeks passed on the fixed code.
The isolated observation-work reduction is preserved; release CPU savings remain
unmeasured. Earlier candidate evidence is retained separately.

Latest implementation: [bounded renderer history and routine enqueue cadence](Qualification/Performance/2026-10-05-observation-optimization/README.md).
180 focused tests and architecture checks passed; three debug app smoke runs
passed 36 exact seeks. The isolated scheduling probe reduced deliveries by
82.5–82.9%; whole-player release CPU savings remain unmeasured.

Latest released Illiquid baseline: [2026-10-04 v0.1.3 full-app measurements](Qualification/Performance/2026-10-04-illiquid-baseline/README.md).
Six qualified playback runs, 72 exact seeks, and six corrected startup probes
retain raw results and failed attempts. Cross-player comparisons remain limited
by window state and different readiness/seek endpoints.

Latest reference baseline: [2026-10-04 mpv / IINA measurements](Qualification/Performance/2026-10-04-reference-baseline/README.md).
Twelve final processes and 144 exact seeks passed the recorded checks across
H.264 1080p, H.264 4K with audio, and HEVC 1080p10. These are warm-filesystem,
shared-host reference results; CPU variation and physical-output limits remain
explicit, and the current Illiquid binary was not measured alongside them.

Latest opportunity audit: [2026-10-04 performance audit](Qualification/Performance/2026-10-04-audit/README.md).
Fifteen opportunities are ranked by likely benefit, workload-specific impact,
effort and risk, with source hashes and a comparison against public v0.1.3.
This is source/retained-evidence review, not a new measured optimization result.

Latest 4K follow-up: [bounded software seek acceleration and hardware handoff](Qualification/Seeking/2026-09-05/4k-followup/REPORT.md).
Matched long 4K H.264 seeks improve 52–59% (8.5-second target: 1.39 s to 0.60 s),
with exact pixels/PTS preserved. CPU returns to hardware-playback levels after
handoff; the temporary memory/CPU tradeoff is quantified in the report.

Latest seek optimization: [exact-seek decoder qualification](Qualification/Seeking/2026-09-05/REPORT.md).
Across 60 release seeks, guarded non-reference decoding reduced median preroll
by 29–50% on the three long-GOP fixtures, with matching landing timestamps.
This preserves exact targets and the existing decoder/session ownership.

Preceding measured follow-up: [release render, memory and responsiveness qualification](Qualification/Performance/2026-09-05/REPORT.md)
at product commit `a477d32b`. Sixteen standalone runtime runs, a 60-second HEVC
gate and an animated-ASS probe preserve raw evidence and distinguish process
cost from full UI/GPU cost. The historical measurements below remain separate.

The September 2026 review identified work whose cost grew with playback history,
folder size, hover activity, or movie duration. The fixes keep the existing
coordinator, deterministic playback core, and native media-session ownership.

| Area | Change | Remaining cost or limit |
| --- | --- | --- |
| Persistence | Separate preferences from history; coalesce snapshots on serial utility queues; await storage completion at checkpoints and shutdown. | History snapshots still use copy-on-write collections and whole-history encoding. Encoding and session-file writes run off the main actor; `UserDefaults` controls its own disk flushing. |
| Timeline previews | One native decode and one replaceable pending request; reuse the decoder for the same file; interrupt open, probe, seek, and decode with a request deadline. | FFmpeg cancellation is cooperative. A slow native call keeps its worker slot until it returns, even after its caller has been released. Images retain the existing 48-entry cache. |
| Embedded subtitles | Throttle the independent reader to 30 seconds ahead; prune expired embedded cues; wait on a condition at EOF and wake on seek or stop. | The window bounds read-ahead by time, not bytes. Unusually dense subtitles can still consume substantial memory. External subtitle files retain their existing whole-file behavior. |
| Folder matching | Tokenize filenames once and index normalized prefixes; score only possible matches. | Broad ambiguous prefixes can still produce many candidates. Existing tie rejection is preserved. |
| Sidebar filtering | Extract a background actor that caches visibility evaluation; search reuses that projection and cancels superseded work. | Rebuilding and sorting the source-tree projection still happens when source structure changes. |
| Packet/frame queues | Use fixed-capacity ring storage. | Enqueue/dequeue no longer shift every queued reference under the queue lock; clearing remains linear in occupied entries. |

EOF playlist advancement now follows a successful checkpoint result. Failed
writes report a save error and do not advance. A seek, replay, replacement, or
shutdown invalidates the authority of an older completion.

## Isolated measurements

An optimized (`swiftc -O`) harness exercised the production persistence and
subtitle-matching code. Preferences used an in-memory `UserDefaults` destination;
flush was measured outside setter timing. Forty volume changes were measured per
history size. These numbers describe caller work, not total storage latency.

| Workload | Result |
| --- | --- |
| Volume setter, 0 history entries | 0.00017 ms median |
| Volume setter, 1,000 history entries | 0.00017 ms median |
| Volume setter, 10,000 history entries | 0.00021 ms median |
| Associate 1,000 episode videos with 1,000 corresponding subtitles | 13.54 ms total |

Regression coverage includes coalescing and write failures, checkpoint ordering,
matching equivalence, visibility-cache reuse, native thumbnail reuse, bounded
thumbnail concurrency, ring wraparound, subtitle pruning, and read-ahead wakeups.
The player app was not launched; these measurements do not establish playback
frame rate, peak process memory, or battery consumption.

Validation covered 394 unit/regression tests. The broad run exposed outdated
model-version assertions; those were updated and passed a focused recheck. All
12 targeted native fixture/boundary tests passed, as did the architecture check
and `git diff --check`.

All 40 PR state-space seeds completed within their configured bounds with no
invariant or progress failures: 196,538 states and 1,900,363 transitions. The
baseline was refreshed from those summaries. The changed ended/seek scenario
then passed an independent baseline recheck with zero trend violations.
