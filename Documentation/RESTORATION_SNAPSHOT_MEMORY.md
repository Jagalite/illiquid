# Retiring obsolete restoration snapshots

## Finding

At baseline `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`,
`PlaybackCoordinator.applyPreparedRestore` saves the complete decoded
`PlaybackSessionRecord` in `preparedRestoreSession`. This includes its playlist,
subtitle URLs, and saved shuffle identities. The field is read by Locate when a
previous source is unavailable, but was only cleared when playback history was
disabled.

Consequently a successful restore kept the original record for the coordinator's
lifetime, including after a different playlist replaced it. A folder restore
also discovers a fresh playlist while retaining the old document. This is stale
ownership of a bounded startup snapshot, not an allocation that grows on every
playback frame.

## Change and recovery contract

Release the record when a new source successfully commits, or when Stop, Forget,
or shutdown ends its recovery role. The active playlist and pending resume
position/paused intent have their own owners. Locate's old history source URL is
also stored separately.

Keep the record through unavailable-folder discovery, failed Locate attempts,
and a native open failure awaiting Retry. In particular, do not release it in
`dismissRecovery`: that method also runs before asynchronous folder discovery,
which can fail and require another Locate.

The production patch consists of four release assignments and a comment. It
does not alter serialized session data or playlist ordering.

## Validation and evidence

The coordinator regression suite adds nine cases covering direct and folder
commit, replacement, failed Locate/Retry, repeated folder Locate, Stop, Close,
Forget, shutdown, and the existing history opt-out behavior. Assertions combine
snapshot lifetime with selection, playlist contents, paused intent, exact resume
position, saved target, and preservation of per-file history.

The [native experiment](../Benchmarks/RestoreSessionLifetime/README.md) compares
the original and changed controller within otherwise identical staged packages.
It records all-zone live malloc storage and exact retained entry counts, runs
the complete candidate coordinator suite, and requires the original controller
to fail the new direct-restoration lifetime regression.

Native test and measurement results will be recorded after the dedicated CI
qualification completes. Swift syntax parsing and source-staging verification
are local checks; they do not replace native execution.

## Limits

The original record can share storage with the active playlist, so releasing it
does not imply all its serialized bytes become free immediately. The experiments
use folder reconstruction and direct playlist replacement to expose obsolete
ownership. Their large saved playlists are synthetic stress cases, and the
fake playback runtime performs no decoding. These results must not be described
as a percentage reduction in the full player's resident memory.
