# Requalified support

`PlaybackPreferences.swift` is `Benchmarks/NonDecodeFollowup/fixtures/PlaybackPreferences.swift`
with only the software decoder thread-limit members added (applied with
`git merge-file` from the current source's change). The current
`PlaybackState.swift` (variant `v5`) reads those members; the historical
variants do not, and the added members do not participate in the measured
publication path. The follow-up fixture itself stays pinned and unchanged.
