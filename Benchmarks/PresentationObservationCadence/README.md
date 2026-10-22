# Presentation observation cadence admission

This native component experiment measures repeated cadence requests before and
after the runtime's `PresentationObservationCadence` gate. The original path
always calls `setPresentationTimeObservationInterval`; the candidate calls it
only when its valid requested interval changes.

The harness compiles the complete production gate unchanged. It also extracts
the **exact production coordinator setter** and the **exact subtitle cadence
policy**, checks both against baseline
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3`, and compiles them unchanged. The receiver
has a real serial `DispatchQueue`, real `CMTime` interval state, and the
coordinator's initial 1/30-second interval. Observer replacement is a recorder;
this does not instantiate an AVFoundation synchronizer or exercise media output.

## Reproduce on macOS

```sh
python3 Benchmarks/PresentationObservationCadence/run.py \
  --pairs 7 --requests 100000 --output /tmp/illiquid-cadence-results
```

Requires Python 3, macOS 26, and the Xcode Swift toolchain. The output directory
must be new or empty and the baseline revision must be available in Git.
`--verify-only` runs debug/release regression tests and trace comparisons without
timing. `--skip-tests` can isolate a benchmark rerun after tests were qualified.
Linux adapters are intentionally absent.

## Fixtures and correctness

| Workload | Requested cadence |
| --- | --- |
| `steady-4hz` | Subtitles off, repeated 1/4-second interval |
| `steady-24hz` through `steady-120hz` | Subtitles on at 24, 30, 60, or 120 Hz |
| `periodic-transitions` | Subtitle off/on and 30-to-60-Hz changes, 128 repeated requests per phase |
| `alternating-control` | Every request changes interval; deliberately removes the coalescing opportunity |

Rates describe the interval requested from the presentation observer, not the
frequency of the timed calls. Fixtures run as tight loops to measure component
cost; they are not captured playback telemetry. There is no artificial queue
contention in the timing cohort.

Verification runs 4,096 requests per workload and compares the complete effective
interval-change traces and final states between both variants. Separate receiver
lifetimes demonstrate that each new owner applies its own initial request and
that terminated receivers cannot mutate interval state. The exact production
gate and its checked-in tests are also built in temporary Swift packages in
debug and release. These tests include the separate blocked-queue regression.

Every fixture interval is positive and numeric. The unmodified coordinator setter
therefore performs exactly one `commitQueue.sync` for each counted setter entry.
The reported queue-entry count is this valid-call count; the setter is not
rewritten or wrapped with a replacement queue. Effective observer changes are
counted by the recorder independently.

## Measurement and limits

Both binaries use the same sources and optimized whole-module compiler flags;
the candidate additionally defines `CANDIDATE` to enable the gate in the caller.
Warmup occurs on a separate receiver outside timing. The measured owner starts
fresh, so the first admitted request is included. History recording is disabled
inside timing, while effective-change and setter-entry counters remain enabled
for both variants. Results report nanoseconds per request and queue entries.

Each pair runs fresh processes in alternating AB/BA order and rotates workload
order. Seven pairs contain four AB and three BA rounds. All raw results, source
copies, source/executable hashes, extraction provenance, commands, native
toolchain/host details, verified traces, test logs, medians, and a completion
receipt are preserved. Timing has no machine-dependent pass/fail threshold.

These results measure caller admission and an uncontended serial queue entry.
They do not establish whole-player CPU, battery, frame-rate, or subtitle latency
improvements. A waiting main actor is avoided when unchanged requests do not
enter a busy presentation queue; the regression tests establish that behavior
separately. The repository's regular PR workflows build and test the complete
native app graph, and the focused workflow runs this component qualification.
