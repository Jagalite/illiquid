# Playback performance fixes

Latest 4K follow-up: bounded software seek acceleration and hardware handoff (reference omitted from this source export).
Matched long 4K H.264 seeks improve 52–59% (8.5-second target: 1.39 s to 0.60 s),
with exact pixels/PTS preserved. CPU returns to hardware-playback levels after
handoff; the temporary memory/CPU tradeoff is quantified in the report.

Latest seek optimization: exact-seek decoder qualification (reference omitted from this source export).
Across 60 release seeks, guarded non-reference decoding reduced median preroll
by 29–50% on the three long-GOP fixtures, with matching landing timestamps.
This preserves exact targets and the existing decoder/session ownership.

Preceding measured follow-up: release render, memory and responsiveness qualification (reference omitted from this source export)
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
