# Lifecycle and UI performance audit — 2026-10-05–06

> Protocol qualification: the original lifecycle measurements used the benchmark
> bundle's BGRA software-output default. Production prefers planar output;
> software and hybrid seek paths can therefore differ. Startup/source-list and
> persistence findings remain separately measured. See the corrected production
> policy comparison in [the follow-up](PERFORMANCE_FOLLOWUP.md).

The largest confirmed bottleneck was quadratic source-tab deduplication during
startup. The fix normalizes each item once and uses a set while preserving
ordering and file/folder identity. An optimized harness exercising the exact
production implementation reduced a 1,000-entry merge with duplicate additions
from a median **9,003 ms to 11 ms** (three samples each). At 10,000 entries the
new implementation took **93 ms**. This harness excludes UI and filesystem work.

Settings → Behavior now has **Keep Illiquid running after closing the last
window**, defaulting off to preserve existing behavior. Closing stops playback
unless Picture in Picture is active; the Dock reopens the player, and explicit
Quit still exits. Session restoration is also on the Behavior page.

Live testing exposed three correctness problems that would otherwise undermine
this option: SwiftUI reused a closed window without reinstalling its handlers;
opening the retained current file did not restart its stopped session; and a
subsequent save could replace the last checkpoint with idle position zero. All
three paths now have regression coverage. Shutdown also cancels the interactive
250 ms save debounce, joins an already-started save, and performs the final
flush with existing error reporting intact.

## Measurement protocol

Baseline: product revision `2819b8cd2789755d9a45d5bf39da2683892e1621` plus
benchmark instrumentation. Candidate: that revision plus this audit's changes.
Both are release, ad-hoc-signed bundles with locked native dependencies and
the isolated `com.example.SuperplayrBenchmark` identity. The benchmark builds
exclude the separate, concurrent OSD/PlayerRootView edits; integrated regression
tests include the current workspace. The installed `/Applications/Illiquid.app`
and its preferences/session were left untouched.

Primary comparisons use internal-storage app bundles, fixtures, command files,
logs and isolated session writes. Each case has five fresh processes per build,
alternating baseline/candidate order and reversing order on alternate rounds.
OS caches remain warm; launches execute the bundle binary directly, so these are not cold Finder/LaunchServices measurements. Cases: empty, 10,000 and 100,000 history entries, 1,000
saved source entries, and generated 24-second 1080p/4K H.264/AAC media. Media
runs exercise play, pause, exact seeks, sidebar toggling and window resizing.
Fixture hashes, machine/OS, bundle hashes and script hashes accompany the raw
results. Preferences are reset before each launch, not merely imported over
the previous case.

The original launch measurement waits for player configuration and then checks
for an onscreen player-sized WindowServer window. It measures **player readiness**,
not the earliest appearance of the loading shell, completed drawing or scanout.
The follow-up records first-window appearance separately. Shutdown means the instrumented
application delegate's async shutdown interval; the separately recorded
Apple-event-to-process-exit interval includes automation overhead. Command
round trips have a 5 ms polling floor and are not input-to-photon latency.
First-frame submission does not prove visible pixels. A benchmark-only 10 ms
heartbeat measures main-queue gaps and adds overhead. CPU is process CPU as a
percentage of one core; it excludes WindowServer/GPU. The host was not otherwise
quiesced, and five samples do not establish a reliable tail-latency percentile.

## Measured results

Apple M1, macOS 26.5.2 (25F84). Sixty completed internal-storage release runs.
Values below are **median (minimum–maximum), milliseconds**, five runs per cell.

| Workload | Baseline | Candidate |
| --- | ---: | ---: |
| Empty startup | 417 (359–521) | 420 (364–557) |
| Startup with 10k history | 556 (374–599) | 392 (370–586) |
| Startup with 100k history | 650 (586–899) | 751 (591–900) |
| Startup with 1k sources | 4533 (4110–5907) | 593 (432–678) |
| Shutdown after 1080p workload | 99 (62–273) | 51 (30–58) |
| Shutdown after 4K workload | 110 (54–288) | 54 (41–60) |

The 1k-source launch improvement is about 87%. Ordinary startup is unchanged.
The 10k/100k history differences are noisy and inconsistent; no history-loading
optimization was made, and these results do not establish an improvement there.
Baseline media shutdown spent up to 216–228 ms waiting for the save task;
candidate waits were under 0.1 ms. Actual persistence and native cleanup still
run and can dominate other workloads. Empty app shutdown was about 6 ms in both.

Candidate first-frame-submitted observation was 140 ms at 1080p (126–162) and
139 ms at 4K (121–189). This marker is candidate-only, so no before/after
first-frame improvement is claimed. Native logs show VideoToolbox/420v output
for these fixtures. They do not qualify other codecs or software-decoding paths.

Each media/build cell includes 60 sidebar commands and 60 resize commands.
Candidate sidebar acknowledgement medians were 7.8–7.9 ms; resize/layout was
23.4 ms at 1080p and 27.6 ms at 4K, versus 23.5/23.8 ms in the baseline.
These results do not demonstrate a general UI speedup. Process CPU and footprint
remain broadly similar; the raw summaries retain play, pause and empty phases.

The follow-up internal-storage close run completed nine close/reopen cycles:
window disappearance took **277–393 ms** and reappearance **43–65 ms**.
The same-file media sessions reopened successfully and final checkpoints remained
nonzero. A separate earlier external-media close run completed nine close/reopen cycles
(three each empty/1080p/4K), reopening the same media between cycles. Windows
reappeared in 45–229 ms and disappeared in 293–420 ms. The application's own
close callback took roughly 1–2 ms. The larger WindowServer interval needs a
separate animation/compositor timing audit; it must not be labeled native
teardown time. The short closed-state samples retained about 33 MiB empty,
101–112 MiB after 1080p, and 170–179 MiB after 4K. These are footprint samples,
not a leak diagnosis.

A separate internal-storage run after 4K playback, with two seconds allowed for
cleanup followed by ten seconds of sampling, used **0.44% of one CPU core** and
ended at **149 MiB footprint** while closed. The benchmark heartbeat remained
enabled. This single observation is not a long-term energy or leak test. With
the keep-running option off, a separate live close exited successfully in 82 ms.

## Follow-up decisions

Every idea below now has an implemented, deferred or dropped disposition in
[the completed follow-up and mpv/IINA comparison](PERFORMANCE_FOLLOWUP.md).
The following table preserves the original investigation priorities.

### Original investigation priorities

| Priority | Evidence | Next experiment and acceptance check |
| --- | --- | --- |
| 1. Decouple usable window from full history | 100k-history decoding alone took 233–386 ms in the candidate. Model creation still waits for it. | Load the minimal session/index first, then the full history. Verify explicit file opens and close/quit during loading; retain unreadable-history protection and prevent partially loaded data from overwriting saved history. |
| 2. Defer native initialization for an empty launch | Empty candidate presentation initialization took 67–107 ms, on the path to the first window. Subtitle initialization is much smaller on warm runs. | Create the empty shell before the native graph, or initialize playback on demand. Measure first usable window and first-media latency together so deferred work is not mistaken for an overall speedup. |
| 3. Investigate resize/layout work | The 4K candidate resize round trip had a 27.6 ms median; no UI improvement was established. | First obtain a valid SwiftUI update/layout trace, then target broad observation invalidations or expensive layout. Re-measure frame hitches during real dragging as well as command acknowledgements. |
| 4. Reduce retained resources while closed | Closing retains considerably more footprint after media than an empty app. | Profile repeated mixed-codec close/reopen cycles and memory-pressure handling; release decoder/presentation caches selectively while preserving the benefit of a warm reopen. Do not classify retained framework allocations as leaks without ownership evidence. |
| 5. Qualify slow-storage shutdown | Removing the debounce does not remove real writes or cooperative native cancellation. | Exercise a controlled slow/unavailable filesystem, close during probing, and quit during a write. Measure bounded cancellation and checkpoint correctness. Local synthetic fixtures and deterministic cancellation tests do not qualify a real NAS stall. |

The 4-second close-path sample was dominated by the idle main run loop and did
not identify the cause of the window-disappearance interval. The separate
12-second Instruments SwiftUI attempt reported **no SwiftUI data** and exceeded
the 45-second export wait; it is inconclusive. The captured 4K player screenshot
shows the generated fixture and controls, but is not frame-rate/latency evidence.
Actual input-to-photon timing, GPU/WindowServer cost, cold-cache launch,
long-duration energy usage and live Picture in Picture remain unqualified.

## Evidence and validation

Raw evidence lives under the gitignored
`QualificationArtifacts/LifecyclePerformance/` directory. Keep `internal-final`,
`internal-close`, `closed-steady-run`, `default-close-run`, `close-final`, the source-item harness results, source manifests and bundle hashes
together when comparing another build. Executable SHA-256:

- Baseline: `75e494f9b8327e26ba5a0f777134a8a41113df11fbebf4a6cd8ec10df72b54a8`
- Candidate: `d28c7e6197e307e5f9900929a20ceea66c480711404e756a43a149f32fc330ff`

The candidate source hashes are in `candidate3-source-manifest.json`.
The earlier external-HFS-drive runs are
exploratory and must not be combined with internal-storage results. The tail of
that comparison overlapped an abandoned internal run; `internal-matched` is
explicitly excluded. Earlier failed close/reopen runs are retained as defect
evidence, not passing performance samples. History-100k samples in
`baseline-scaling` were contaminated by previously imported source-tab settings
and are excluded.

The final focused regression run passed **84 tests in five suites**, including
coordinator persistence/shutdown behavior, last-window policy, window reuse,
source merging and player-window lifecycle. An earlier broader run passed 97
tests, including history scaling, source-preparation cancellation and persistence
writers. These counts overlap. The architecture check and whitespace check
passed. The same-file reopen regression was observed failing before its fix.
Live media-close checkpoints retain nonzero playback positions after final Quit.

## Reproduce

Build baseline and candidate in separate checkouts with identical instrumentation
and isolated identities; never point this harness at the installed product.
Use internal storage for both bundles and the fixture directory when reproducing
the primary results. The harness writes its active session, log and control file
to the system temporary directory and archives them under the output directory.

```sh
PLATINUM_BUNDLE_ID=com.example.SuperplayrBenchmark \
  Scripts/build-platinum-app.sh --output /tmp/illiquid-perf-candidate --adhoc

python3 Scripts/profile-lifecycle.py \
  --app /tmp/illiquid-perf-baseline/Illiquid.app \
  --comparison-app /tmp/illiquid-perf-candidate/Illiquid.app \
  --fixture-dir /tmp/illiquid-performance-fixtures \
  --output QualificationArtifacts/LifecyclePerformance/new-comparison \
  --repeats 5 --cases empty history10k history100k sources1000 1080p 4k

python3 Scripts/profile-lifecycle.py \
  --app /tmp/illiquid-perf-candidate/Illiquid.app \
  --fixture-dir /tmp/illiquid-performance-fixtures \
  --output QualificationArtifacts/LifecyclePerformance/new-close \
  --keep-running --close-cycles 5 --closed-seconds 10 --repeats 1 \
  --cases empty 1080p 4k

python3 Scripts/profile-source-items.py \
  --output QualificationArtifacts/LifecyclePerformance/new-source-merge \
  --counts 100,500,1000,10000
```

The fixture directory must contain `h264-1080p.mp4` and `h264-4k.mp4`.
Run only one lifecycle harness at a time: they intentionally share one isolated
benchmark preference domain. The script resets that domain, so it is unsuitable
for preserving an interactive benchmark session. All added lifecycle probes and
application-control actions require both the benchmark bundle identity and
explicit environment opt-ins; ordinary production launches do not run them.
