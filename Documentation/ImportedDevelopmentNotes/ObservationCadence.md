> Historical development note imported from `/Users/jagatranvo/Projects/superplayr/Documentation/Qualification/Performance/2026-10-05-observation-optimization/README.md`. Its dates, validation results and relative evidence links describe that checkout, not the reconciled build.

# Renderer history and enqueue observation optimization

Implemented P01 and the routine-enqueue portion of P02 from the October 4 performance audit. This directory uses the UTC date October 5; work occurred on October 4 in the host's local timezone.

## Changes

- `DifferentialRendererObservationJournal` retains one earliest-start/latest-end interval per stream, replacing sample-history arrays. Readiness still means the clock crossed at least one submitted start. EOF still requires the clock to reach the latest submitted end. Reordered timestamps, stale epochs and empty epochs retain their previous behavior. A completed EOF remains completed after a late enqueue, preserving the existing contract. Already-completed EOF observations skip further drain work.
- The session observation coalescer limits routine video/audio enqueue deliveries to a nominal maximum of 60 Hz. It retains a trailing delivery so the final enqueue cannot disappear at pause or EOF. Urgent requests and other sources preempt a pending enqueue timer. Revision checks prevent a cancelled timer from delivering stale work. Counters continue counting every request.
- Subtitle packet observations, the separate presentation-clock coalescer, preroll, drain and failure requests keep immediate scheduling. Media queues, renderer submission and synchronization authority are unchanged. The optional cadence is enabled only for the session's coalescer; the default remains the existing coalescing policy.

Routine enqueue-driven snapshots can now wait up to about 16.7 ms plus actor scheduling delay. Urgent scheduling bypasses that deliberate wait; a busy main actor can still delay urgent delivery. This does not establish a strict wall-time guarantee.

## Evidence

- `focused-tests.log`: **89 tests passed** across journal, native-foundation and presentation-observation suites. New tests compare the bounded journal against the original sample-history algorithm for reordered/randomized inputs, verify bounded state after **1,000,000 samples**, and exercise trailing delivery, urgent preemption, cancelled-timer rejection and non-enqueue bypass.
- `runtime-tests.log`: **91 tests passed** across runtime authority fences, playback coordinator and seek-preroll decoding. These include acknowledgment, supersession and ownership checks.
- `architecture.log`: architecture checks passed.
- `observation-probe.swift`, compiled with `swiftc -O -parse-as-library`: serial original/candidate comparisons, alternating order across three repeats, each with 240 routine requests spaced by requested 2 ms sleeps. Original: **240 deliveries** each repeat. Candidate: **41–42 deliveries**, approximately **82.5–82.9% fewer**. This measures observation scheduling for a synthetic burst workload. It is not a whole-player CPU, energy or battery improvement claim; sleep/actor scheduling varies on the shared host.
- `final-*` raw JSON/logs: three full-app **debug** smoke processes, one each for H.264 1080p, H.264 4K with audio, and HEVC 1080p10, totaling **36 exact paused seeks**. All passed advancing-clock, pause, target-position, hardware-video and onscreen 960×540-window checks. `smoke-summary.json` retains those gates and final request/delivery metrics. These runs do not measure physical first-picture latency, displayed cadence, audio sync, long playback, or EOF after a full movie.

## Candidate and limits

The smoke app uses the current dirty working-tree debug executable built by the focused test invocation. It is copied into the prior release benchmark bundle's resource/library shell with the isolated `com.example.IlliquidBenchmark` identifier and ad hoc signature. The current executable uses its development dependency linkage. This is a local smoke candidate, not a packaged optimized release or an exact release A/B. Its CPU and footprint fields must not be compared to the v0.1.3 release baseline as optimization gains.

The existing shared worktree includes many earlier edits and renames. `implementation.patch` isolates these two production changes against the source content frozen in the October 4 audit; the reconstructed before-file hashes match that audit. `source-identities.json` retains before/after hashes. The added tests are in `DifferentialHarnessTests.swift` and `PresentationTimeObservationTests.swift`.

A release CPU A/B, long-session/EOF run, dense or animated subtitles, PiP, variable speed and 24/60/120 fps qualification remain before release-wide performance claims. Startup probe consolidation, preview decoder reuse and 4K seek allocation changes are still separate opportunities. This slice adds no claimed startup or seek-memory improvement.

No commit, push or publication was performed. User playback preferences/system volume were not changed; isolated benchmark-domain history was disabled. All owned smoke player processes exited. Source/code evidence remains local for review.
