# Build coordination

Run future builds through the shared Kyoto queue when it is available, including
Swift product builds, Swift test compilation, and packaging that compiles Metal.
From this repository, preserve the intended command and environment:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- COMMAND ARGUMENTS
```

Kyoto supports arbitrary executables, not only Cargo. Use its default queue and
inspect `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID` before reporting a result.
Queued, compiled, executed, and live UI-qualified are different outcomes. Do not
change shared queue policy. If Kyoto is unavailable, explain the limitation
before using a direct build. Keep builds sharing `.build` serialized.

Prepare the UI runner's cached Swift helpers through Kyoto before using a new
helper version: `kyoto.py submit -- python3 Scripts/agent-ui/prepare.py`.
The runner otherwise compiles missing helpers automatically.

For agent UI automation, follow
[the macOS runbook](Documentation/MACOS_AGENT_UI_AUTOMATION_RUNBOOK.md). Use the
isolated benchmark bundle and exact process identity for live checks; retain
receipts and report unqualified interaction or presentation metrics explicitly.
