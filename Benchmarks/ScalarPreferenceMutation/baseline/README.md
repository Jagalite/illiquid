# Requalified baseline focal files

`PlaybackPersistenceStore.swift` and `PlaybackPreferences.swift` here are the
files at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72` carried forward to current
source with `git merge-file` (current file as ours, `main` as the common base,
the historical file as theirs). Relative to the historical files they add only
the software decoder thread-limit preference plumbing, so the measured scalar
mutation change remains the only difference between baseline and candidate.
