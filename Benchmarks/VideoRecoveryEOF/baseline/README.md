# Requalified baseline session

`MediaSession.swift` here is `MediaSession.swift` at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` (before final-GOP release at EOF)
carried forward to current source with `git merge-file`, using the `main`
session as the common base. Relative to the historical file it differs only by
the `IlliquidPlaybackModel` import (the playback core became a Statelessness
model) and the software decoder thread-count parameter, neither of which
participates in EOF packet retention. The workflow's baseline step installs this
file in place of the historical one.
