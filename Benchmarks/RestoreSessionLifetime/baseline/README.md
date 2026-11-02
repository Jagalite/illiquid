# Requalified baseline controller

`PlaybackController.swift` here is the historical controller at
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` carried forward to current source:
`git merge-file` applied the historical file onto the current controller with
the `main` controller as the common base. Relative to the historical file it
differs only by the `IlliquidPlaybackModel` import (the playback core became a
Statelessness model) and the software decoder thread-limit plumbing, neither of
which participates in restoration snapshot retention. `run.py` records both the
historical and the requalified hashes in each manifest.
