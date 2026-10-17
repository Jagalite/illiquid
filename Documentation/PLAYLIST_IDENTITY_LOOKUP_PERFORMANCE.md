# Playlist identity lookup performance

## Scope

This investigation starts from `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19` and targets current-selection
preservation in `PlaylistMutation.indexPreservingCurrentIdentity`.

`PlaybackController` calls the mutation helper while sorting, removing, moving,
shuffling, restoring and committing playlist items. These calls repeatedly compare a changing candidate URL with one fixed target.
The related `FolderPlaylist.index(of:)` is unchanged and supplies control
workloads in the final experiment. A separate concurrent PR,
[#43](https://github.com/Jagalite/illiquid/pull/43), covers that method.

## Change and reasoning

The previous implementation calls `NormalizedFileURL.representsSameFile` for
all visited items. For each supported local candidate, that helper reconstructs
normalized keys for both the candidate and the fixed target. With K supported
local candidates visited, this performs 2K normalizations.

For playlists with more than one item, the new implementation normalizes a
supported target once and normalizes each visited candidate once: K + 1 normalizations for an all-local scan. Unsupported
targets skip the scan. Empty playlists still return before any normalization. A singleton always
returns its only index, so it now skips normalization too.
There is no retained cache, new index, filesystem access, or change to the
normalization helper.

The runtime diff changes only `PlaylistMutation.indexPreservingCurrentIdentity`.
It keeps the first match and the
existing selection fallback. A target must have a nonnil local persistence key:
identical unsupported URLs must never match merely because both keys are nil.
Each item is still normalized during lookup because decoded `FolderPlaylistItem`
values can bypass the public initializer that normally prepares their URLs.

One tradeoff needs explicit measurement: with a valid target and exclusively
unsupported items, the previous left-to-right comparison never normalizes the
target. The candidate pays for that normalization once. First-item hits in longer lists also need controls because their target key
was already normalized only once. Singleton lookup now returns directly.

## Correctness qualification

The isolated component uses the exact four production Foundation source files,
with no model stubs, import rewriting, or changes to the main package. It runs
the existing playlist mutation, restoration and folder tests alongside the new
identity tests, for the frozen baseline and candidate in debug and release.

The new tests cover local and Unicode aliases, raw decoded URLs, duplicate
metadata, nil/missing/unsupported targets, identical invalid URL nonmatches,
empty/all-invalid lists, distinct paths, and extreme fallback indices. An
independent identity-label oracle enumerates 85 small queues and checks 3,570
mutation selections, 425 folder lookups, and 510 initial selections (4,505
checks), in addition to the direct edge cases.

## Initial native experiment and refinement

[Run 39070214459](https://github.com/Jagalite/illiquid/actions/runs/39070214459)
tested the initial two-function candidate at
`6d2e617ffdda47e20ffdb67ab6551619de2c7634` on an Apple M1 virtual runner,
macOS 26.6.2 and Apple Swift 6.3.3 / Xcode 26.6. All 22 test functions in
four suites passed for baseline and candidate in debug and release. Its 29
workloads produced 464 measured fresh processes and 61 calibration processes;
all semantic checks and an independent audit of source hashes, raw records,
paired summaries and command logs passed.

The 1,000-item mutation last-hit case decreased from 7.723 ms to 4.054 ms
(47.8% median paired reduction, faster in all eight pairs). A supported
singleton remained about 8.2 microseconds. An unsupported singleton increased
from 0.203 to 3.898 microseconds because eager preparation added a normalization
that the previous left-to-right comparison skipped. These results identify the
first candidate, not the final implementation.

The final scope removes the `FolderPlaylist` production change because PR #43
appeared independently while this experiment ran. Those 13 workloads become
unchanged controls. The mutation refinement returns immediately for both empty
and one-item playlists: a singleton has exactly one possible selection under
every current-URL/fallback combination. This removes the unsupported-singleton
regression and ordinary singleton identity work without adding a special URL
policy. Existing exhaustive tests already exercise the invariant.

The final benchmark gives empty/singleton mutation cases a predefined 500,000
iteration floor, applied before calibration, so the now much shorter candidate
path has a longer timed interval. Both variants use the same iteration count.
The baseline/driver sources and both campaigns' evidence remain separately
identifiable.

## Final measurement status

The narrowed implementation is awaiting its own native test and benchmark run.
Final performance claims will use that run only.
