# Renderer recovery and terminal-error audit

## Scope and status

This investigation concerns the deterministic playback authority in
`IlliquidPlaybackCore`: renderer retry budgets, delayed effect results, and
preservation of terminal errors. It is independent of the packet ownership,
packet queues, native I/O, and media-library changes being investigated in other
PRs. No native decoder, renderer, queue, or buffering default is changed here.

The final candidate passed **64 tests across 6 suites in both debug and release**
with Swift 6.2.1 on x86_64 Linux. Eighteen named tests in
`RendererRecoveryRegressionTests` add parameterized event-ordering coverage to
the existing core suite. This proves deterministic core behavior for those
traces, not macOS integration, visible playback, or native cancellation safety.
The PR's current macOS jobs must be checked separately before merge.

## Reproducible source and test method

The starting PR head was `9ee55154bc829f1885da596096ebb4922c720a21`, based on
`main` at `8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`. Its existing source-receipt
workflow archived the synthetic merge commit
`266c71ad34dd8cde149508640e1361b955997455` in Actions run `39004984282`, artifact
`12090826301` (`non-decoding-performance-source`). The downloaded ZIP's SHA-256
was `5b42c5aeb99617c56ae8b25884b1512a182060f50352e200fc686828a89be453`.
The starting recovery/core files were checked against their Git blob hashes.

`Scripts/test-renderer-recovery.sh` copies the **actual complete core sources**,
their real `MediaTrack.swift` dependency, and all core tests into a temporary
Swift package. It does not substitute a mock recovery implementation. The
existing `PlaybackModelRuntime` supplies deterministic effect acknowledgements;
it does not execute native side effects. The toolchain's built-in Testing
library avoids resolving the app's native macOS dependencies.

From the repository root:

```sh
bash Scripts/test-renderer-recovery.sh
bash Scripts/test-renderer-recovery.sh --configuration release
```

The restoration workflow now runs both commands in its macOS focused job. Its
native app-graph job also includes `RendererRecoveryRegressionTests` in the
existing test filter. These are additional gates, not a claim that those new
macOS runs have already passed.

## Findings and retained changes

### 1. A recovery-generated revision replenished its own retry budget

The original classifier recorded a consumed flush for the current presentation
revision. Dispatching that flush then advanced the revision in `PlaybackCore`.
The next failure saw an unconsumed revision and received another flush, rather
than escalating. The existing classifier-only test reused one fixed revision,
so it did not exercise the real transition sequence.

The budget is now one presentation flush and one graph rebuild per active
session. Presentation revision advances and ordinary seeks do not replenish it;
a new loaded session starts with fresh recovery state. Existing Codable fields
are retained so a nonempty recorded flush set continues to mean spent budget.

Six new real-core cases cover playing and paused intent across enqueue, flush,
and render failures. Each commits the returned revisions and acknowledges the
intermediate effects before testing the next failure. A negative control that
restored only the original revision-membership condition failed all six cases.
The candidate passes them. This is evidence of fault detection, not a timing or
performance benchmark.

### 2. Late acknowledgements could erase a terminal error or restart playback

A terminal failure or operation timeout need not change session/generation/
revision identity. The old result reducer therefore accepted outstanding
recovery acknowledgements even after failure. Success could clear `lastFailure`
and emit a new rate command; failed or cancelled results could replace the
original diagnostic. This affects more than renderer flushes because recovery
routes share result handlers.

The result reducer now retires valid late results but rejects their playback
mutation while the matching active session is failed. It still validates tokens
and authority first. A repeated result remains a duplicate, and a rejected late
result does not remain in the outstanding-effect table. Persistence, resource
cleanup, and cancellation settlement remain permitted. A pending replacement
load has its own session authority and can still complete.

The suite covers nine routes: video flush/rebuild, hardware fallback, software
restart, transient video retry, audio flush/rebuild, and audio/subtitle disable.
For each, success, failure, cancellation, and timeout ordering are exercised.
Additional traces cover already-emitted resume-rate effects, both callback
orders for overlapping renderer recoveries, and an older optional-track result
after a different recovery effect fails.

Requiring every recovery result to match the latest `activeOperationID` was
not adopted: a user pause changes that ID while the recovery can still validly
finish. Six pause-during-recovery controls verify that the latest paused intent
is respected without discarding legitimate recovery completion.

### 3. Callback-only fixes left automatic-event bypasses

An intermediate fix guarded only recovery result handlers. Further tests showed
that buffering, format change, sleep/wake, or EOF observations could first move
a failed session into another phase. Other outstanding operations, including
seek, format reconfiguration, wake, and subtitle delay, could also change the
session or its diagnostic. Late deadlines could overwrite the original error.

The retained fix uses a shared result fence and guards synchronization,
lifecycle, drain-start, failure, and deadline observations at the failed-state
boundary. Failure observations during stopping/stopped are also ignored rather
than starting recovery during teardown. Ordinary play/pause commands cannot
restart a failed pipeline. Explicit load/replacement remains available; existing
seek and track-change command semantics are not redesigned in this patch.

Five automatic-event traces and twelve pending-result combinations reproduced
the narrower fix's bypasses. They pass with the retained fence. Separate controls
verify persistence completion, teardown, source replacement, and 100 repeated
failure observations without renewed recovery or diagnostic replacement.

### 4. Presentation classification ignored declared recoverability

The presentation branch previously checked domain and stage, but not
recoverability. Consequently even `.fatal` or `.cancelled` presentation failures
at enqueue/flush/render could consume a retry and suppress the error. The branch
now accepts only `.retryable` or `.fallbackAvailable`; terminal classifications
do not consume a presentation retry. Six metadata cases cover this contract.
The usual native presentation-failure builder reports retryable failures; these
tests do not establish that every terminal metadata case occurs in normal
native playback.

### 5. Correction to the earlier draft patch

The earlier PR contained literal `\\n` text in a source comment. This commented
out the intended `if` statement and produced unmatched braces. The unmodified
PR failed actual Swift compilation. This follow-up repairs the source and tests
it; the earlier unexecuted test was not successful qualification. Source/blob
hash checks accompany publication to catch serialization mistakes.

## Evidence and remaining qualification

The accompanying evidence bundle contains the reproducible core subset, this
report, the follow-up patch, and raw logs:

- `pr10-unmodified-build.log`: compilation failure of the earlier draft.
- `syntax-only-tests.log`: stale-callback and metadata failures after repairing
  only the malformed comment.
- `original-budget-negative-control.log`: all six real-core escalation cases
  fail with the old revision-membership condition restored.
- `terminal-fence-negative-control.log`: automatic-event and pending-result
  bypasses of the narrower callback-only fix.
- `candidate-debug.log` and `candidate-release.log`: final candidate, 64 tests
  in 6 suites passing in each configuration.

`bash -n` for the runner and `git diff --check` also pass. Source review was
performed in this investigation; no independent-agent execution is claimed.

Native work already in flight is not physically cancelled by this logical
fence. On macOS, qualify failure injection during flush/rebuild, queued rate
application, seek, sleep/wake, replacement, and shutdown, including native
resource cleanup and visible playback. Existing SDK-locked CI should build the
app graph and run the added suite. No CPU, memory, energy, audiovisual quality,
or full state-space-exhaustiveness claim follows from these deterministic tests.
