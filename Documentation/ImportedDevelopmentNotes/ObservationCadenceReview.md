> Historical development note imported from `/Users/jagatranvo/Projects/superplayr/Documentation/Qualification/Performance/2026-10-05-observation-review/README.md`. Its dates, validation results and relative evidence links describe that checkout, not the reconciled build.

# Review and fixes: renderer history and enqueue cadence

Reviewed the preceding observation optimization, fixed two scheduling issues, and retained the earlier measurements as historical candidate evidence. The directory date is UTC October 5; the host local date was October 4.

## Findings fixed

1. **Concurrent clock subtraction could trap.** A request read uptime before acquiring the coalescer lock. A delivery occurring before that request acquired the lock could update `lastEnqueueDeliveryNanoseconds` past the request's timestamp; unsigned subtraction could underflow. Read request time inside the lock and calculate a saturating absolute deadline instead. The timestamp and delivery state now share one serialization boundary.
2. **Actor contention added an unnecessary cadence wait.** The sleeping task used a relative delay calculated when requested. If the actor was occupied beyond that deadline, the task still slept the full interval after it began. Store the original deadline and sleep only for the time still remaining at task execution. Overdue work runs immediately when the actor can execute it.
3. **Small EOF allocation.** Use a lazy maximum over the bounded stream intervals, avoiding construction of a temporary end-time array. No journal result changed.

The review also checked readiness for reordered timestamps, empty/stale epochs, completed EOF with a later enqueue, urgent timer preemption, revision rejection of cancelled tasks, requests arriving during delivery, and coalescer lifetime. No further behavior mismatch was identified in those paths. The review does not certify all production workloads.

## Validation

- **182 tests in 10 suites passed**, including a new eight-producer/8,000-request concurrency regression and an overdue-timer regression that deliberately occupies the main actor. Journal/sample-history equivalence, million-sample bounded retention, urgent preemption and trailing delivery tests also passed. See `tests.log`.
- Architecture checks passed (`architecture.log`).
- The optimized isolated probe retained **41–42 deliveries versus 240** for 240 routine requests across three repeats, approximately **83% fewer deliveries**. Raw source, build log and results are retained. This is scheduling work reduction, not release CPU savings.
- The newly built debug app passed three separate local smoke runs: H.264 1080p, H.264 4K with audio, and HEVC 1080p10, totaling **36 exact paused seeks**. All recorded playback-clock, pause, hardware-video, seek-position and onscreen-window gates passed. Every owned player process exited.

## Evidence and remaining limits

`review-fixes.patch` contains the production delta against the prior candidate; the reconstructed before-file hashes were checked against that candidate's validation receipt. `validation.json` records current source hashes, the fixed executable hash and evidence hashes. Existing reports and raw attempts were preserved.

The app smoke candidate is the current dirty working-tree **debug** executable in an isolated ad hoc signed bundle using the prior resource shell. It is not an optimized packaged release, so its CPU/footprint fields are not a release A/B. Strict urgent wall-time guarantees, physical frame cadence, long-session EOF, dense/animated subtitles, PiP, variable-speed and high-frame-rate qualification remain outside these tests. The 60 Hz cadence applies only to routine audio/video enqueue observations; urgent edges and other sources bypass its deliberate wait.

No commit, push or publication was performed. User playback settings and system volume were not changed.
