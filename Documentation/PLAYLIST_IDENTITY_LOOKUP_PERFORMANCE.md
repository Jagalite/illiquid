# Playlist identity lookup performance

## Scope

This investigation starts from `main` at
`68274d1b09dcc866296321a5a8858efc297c4f19` and targets the two in-memory
playlist identity lookups in `PlaylistMutation` and `FolderPlaylist`.

`PlaybackController` calls the mutation helper while sorting, removing, moving,
shuffling, restoring and committing playlist items. `FolderPlaylist.index(of:)`
selects an opened folder item and supplies the restored initial selection.
These calls repeatedly compare a changing candidate URL with one fixed target.

## Change and reasoning

The previous implementations call `NormalizedFileURL.representsSameFile` for
all visited items. For each supported local candidate, that helper reconstructs
normalized keys for both the candidate and the fixed target. With K supported
local candidates visited, this performs 2K normalizations.

The new implementations normalize a supported target once and normalize each
visited candidate once: K + 1 normalizations for an all-local scan. Unsupported
targets skip the scan. Empty playlists still return before any normalization.
There is no retained cache, new index, filesystem access, or change to the
normalization helper.

The runtime diff changes only `PlaylistMutation.indexPreservingCurrentIdentity`
and `FolderPlaylist.index(of:)`. The methods keep the first match and the
existing selection fallback. A target must have a nonnil local persistence key:
identical unsupported URLs must never match merely because both keys are nil.
Each item is still normalized during lookup because decoded `FolderPlaylistItem`
values can bypass the public initializer that normally prepares their URLs.

One tradeoff needs explicit measurement: with a valid target and exclusively
unsupported items, the previous left-to-right comparison never normalizes the
target. The candidate pays for that normalization once. First-item hits and
empty/singleton playlists also need controls because the large-list reduction
in repeated work does not apply to them.

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

## Measurement status

Native measurements and their source receipts will be recorded here after the
macOS experiment completes. No timing result is inferred from the operation
counts above.
