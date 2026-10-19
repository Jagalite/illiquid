# October 17 branch consolidation

Baseline: `68274d1b09dcc866296321a5a8858efc297c4f19`.

The integration retains complementary production improvements from PRs #34,
#35, #38, #39, #41, #43, #45, #48, #49, #50, #51, #52, and #53, together with
`perf/bitmap-subtitle-timeline-insertion` at `7b8d246da74fd28d4d83278bbd349b2b90513caa`.

Overlap decisions:

- #39 includes the filename-key caching in #36 and also sorts playlist items
  without discarding their metadata.
- #41 supplies per-line ASCII escaping, plain Unicode fast paths, and the
  original Foundation fallback for Unicode with escape targets. #37 is an
  alternative implementation. #40's cue-wide buffer is not selected: it restarts
  entire cues on Unicode and its native report records a long-prefix regression.
  #42's independent carriage-return guard and exact-byte tests are incorporated.
- #48 provides the playlist identity optimization also proposed by #44, including
  the empty/singleton fast path. #43 changes the separate URL lookup method.
- #49 supplies lazy folder recognition, superseding #47 and
  `perf/media-name-folder-evidence`. #50 removes repeated tag stripping and
  supersedes `perf/media-name-recognition-linux-9200ebe`. #52 supplies delimiter
  guards. #46's Gregorian date validation and tests are incorporated; its tag
  guard is covered by #52. These changes are reconciled in one recognizer.
- #53 covers the same empty-subtitle optimization as
  `codex/perf-empty-subtitle-matching-20261017`,
  `perf/empty-subtitle-association`, and `perf/skip-empty-subtitle-association`.

Native lifecycle failures on #35/#36/#52/#53 were in unchanged click, relative
seek, and observation tests. Their positive-result checks assumed fixed sleeps
or yield counts were enough for another scheduled task to complete. Integration
uses bounded condition waits and retains exact-result, early-delivery, and stale
callback assertions. Production scheduling is unchanged.

Historical benchmark receipts remain attached to their original source hashes.
Their percentages are not additive and do not measure this combined tree or
whole-player responsiveness. Fresh integration correctness and CI results must
qualify the combined commit before merge. Local differential verification already
matches 1,698 complete subtitle outputs/errors and 2,601 media recognition cases.
The palette harness passes debug, release, and ASan/UBSan modes, each with 4,382
cases and 27,791,978 independently checked pixels.
