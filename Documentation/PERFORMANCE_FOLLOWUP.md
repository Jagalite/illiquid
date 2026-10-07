# Performance follow-up and decisions — 2026-10-06

This records the disposition of the idea list from [the lifecycle audit](LIFECYCLE_PERFORMANCE.md).
The original source-list optimization, shutdown-debounce fix, Behavior option
and close/reopen correctness fixes remain implemented. This follow-up adds a
reproducible three-player comparison, separates first-window appearance from
player readiness, allows resource measurements without the benchmark heartbeat,
and removes system-wide muting from the older reference profiler.

## Initial Illiquid, mpv and IINA comparison

**Protocol correction:** these initial runs inherited the benchmark bundle’s
legacy BGRA software-output default. Production prefers planar output. The
steady H.264 samples below observed hardware decoding, but software seek paths
can differ. Treat these as measurements of that benchmark configuration, not
a fully production-equivalent comparison. The joint pass below explicitly sets
planar output and disables inherited tuning flags. Its VP9 results supersede
the exploratory BGRA comparison.

Twenty-seven serial runs: three fresh processes per player per empty/1080p/4K
case, with rotating player order. Apple M1, macOS 26.5.2, warm caches. Media is
the same local synthetic 24-second H.264/AAC fixture in each player. Six seconds
of measured play follows two seconds of settling; four seconds of paused sampling
follows one second of settling. Playback clocks advanced with wall time and held
when paused in every completed media run. All media windows ended at 960×540
points; empty IINA uses its 640×400 welcome window. Controls hide normally,
Illiquid's 10 ms benchmark heartbeat is disabled, and each test player is muted.
System volume and the installed apps' preferences remain untouched.

Versions/routes: mpv 0.41.0 uses `gpu-next`; IINA 1.4.4 (168) embeds mpv 0.38.0
and reports `libmpv`; Illiquid uses its native AVFoundation presentation graph.
All media runs observed VideoToolbox decoding. The isolated IINA copy has a
separate bundle ID and application-support directory and is signed ad hoc.
Plugins, update checks and history/recent-file recording are disabled in that
copy; mpv uses `--no-config` and disables resume/watch-later writes. Illiquid
retains its isolated session persistence. These configuration and durability
differences matter when interpreting startup/quit costs.

**Median process CPU (% of one core) / end footprint**, three samples per cell:

| Case | Illiquid | mpv | IINA |
| --- | ---: | ---: | ---: |
| empty | 0.03% / 29 MiB | 0.12% / 129 MiB | 0.08% / 42 MiB |
| 1080p | 5.66% / 87 MiB | 6.02% / 247 MiB | 8.46% / 415 MiB |
| 4k | 4.34% / 155 MiB | 14.71% / 426 MiB | 7.67% / 608 MiB |

These are process measurements, not GPU/WindowServer cost, total energy, image
quality or a universal performance ranking. Synthetic clips, three repetitions,
background host activity, framework caches and different rendering pipelines
limit the comparison. Raw samples retain ranges and versions. Illiquid's 4K
paused CPU was 0.52%, versus mpv 0.39% and IINA 0.46%; none establishes an urgent
paused-CPU bottleneck. Native benchmark diagnostics remain enabled, so removing
the heartbeat does not make instrumentation overhead zero.

Common-helper Quit after the workload took medians 130/123 ms for Illiquid at
1080p/4K and 108/99 ms for IINA. This includes helper launch and process exit;
it is not the internal async shutdown interval from the earlier audit. mpv's
command-line process rejected the NSRunningApplication termination request, so
its 45/79 ms results use IPC Quit and are not directly comparable. The native
close button worked for IINA in the smoke audit: 366 ms to disappear, process
still alive, then roughly 0.09% CPU and 406 MiB footprint while closed (one
1080p sample). mpv's Accessibility close action returned `-25204`; its native
close timing is explicitly unqualified.

## First window versus player readiness

A separate nine-run empty-launch pass measured process creation to the first
onscreen qualifying window. **Median (minimum–maximum), milliseconds**, three
fresh processes each, no cache purge:

| Player | First window |
| --- | ---: |
| illiquid | 245 (225–890) |
| mpv | 309 (244–622) |
| iina | 949 (778–1766) |

Illiquid's configured-player readiness in this pass was 373 (339–1112) ms.
The surfaces differ: Illiquid first shows its loading shell, mpv is configured
to force an idle window, and IINA shows its welcome window. These are not equal
amounts of initialized functionality. Large sample ranges and uncontrolled OS
caches preclude a cold-start or universal launch-speed claim.

Three additional Illiquid runs with 100,000 history records showed the loading
window at 218 (215–231) ms, and configured-player readiness at 662 (646–662) ms.
This confirms that a loading window already precedes full-history/native setup.
It does not make playback available before that setup. The earlier lifecycle
audit's startup figures are now explicitly labeled player readiness.

## Decisions

| Idea | Disposition | Evidence and reason |
| --- | --- | --- |
| Serve playback before full history is decoded | **Deferred** | The existing background loader already allows the loading shell to appear and Quit to cancel publication. Playback still requires history for resume position, content-version checks, completion status and per-file settings. A staged store needs an explicit hydration state, merge rules for concurrent changes, legacy-preference migration, and proof that partial state cannot overwrite saved history. The measured 100k decode cost (233–386 ms) warrants that separate storage change; presenting an empty history temporarily is not an acceptable shortcut. |
| Lazily build the native playback graph | **Deferred** | The measured 67–107 ms empty-launch presentation setup is real. However, the constructor also establishes capabilities, surface ownership, audio-device callbacks, subtitle overlay and renderer fences. Moving it to first Open changes failure and session-lifetime behavior, and moves cost onto first media. This needs a transaction-aware lazy runtime with empty-launch and first-open acceptance tests together; no speculative background initialization of AppKit objects was introduced. |
| Copy IINA's visibility-aware UI timer policy | **Dropped as duplicate** | IINA disables its sync timer when paused or unnecessary. Illiquid already unmounts hidden controls, cancels the native timeline task when detached, and refreshes continuously only during active playback. Normal empty/paused measurements above support retaining that behavior. |
| Replace native presentation with mpv for speed | **Dropped** | This workload shows no CPU or footprint justification. Decoder, renderer and UI costs must remain separate; the different mpv and IINA results themselves show why an engine name does not predict whole-app cost. |
| Force all window animations off | **Dropped** | Same-process alternating A/B, five closes per mode: default animation had a 304 ms median (291–324), disabled animation 51 ms (43–53). Most apparent close delay is therefore attributable to the chosen window animation in this experiment. Removing the standard visual transition would change UX; the app's own close callback was already roughly 1–2 ms. The benchmark switch remains isolated and production behavior is preserved. |
| Abandon final writes to make Quit faster | **Dropped** | Acknowledging Quit before pending persistence work completes can lose the latest checkpoint. The new blocked-save regression checks responsiveness and latest-progress ordering without skipping the write. |
| Purge the native graph/caches whenever the window closes | **Dropped for the tested workload** | Twelve alternating 1080p/4K close/reopen cycles rose initially, then settled near 137 MiB; the last six samples ranged from 136.9 to 137.6 MiB. Closed CPU in those cycles was 0.09–0.31% of one core with the heartbeat off. A full teardown would trade away warm reopen without evidence of continuing growth here. Mixed codecs, subtitles and real memory pressure remain a deferred qualification expansion; this is not a universal leak clearance. |
| Rewrite SwiftUI layout based on resize round trips | **Deferred** | A second trace waited for actual attachment readiness and exported successfully, but its SwiftUI update table still has zero rows. Time Profiler captured about 2.4 s of main-thread running samples during a 15-second 30-toggle/30-resize workload, including graph updates and Core Animation commit work. These are overlapping sampled stacks, not individual frame latencies or identified invalidation causes. A valid SwiftUI cause trace and real-drag hitch capture are required before selecting a layout change. |
| Qualify real stalled-NAS and long storage-failure behavior | **Deferred after deterministic coverage** | No dedicated disposable stalled mount is configured. Deliberately disrupting a user's mounted filesystem would affect unrelated work. The blocked-save, blocked-restore, cancellation and write-failure tests exercise the controlled boundaries, but do not qualify OS/filesystem cancellation on an actual NAS. Resume this item with a dedicated fault-injection mount. |
| Purge system caches for a cold-launch number | **Deferred** | Current numbers describe warm-cache fresh processes. A cold-login/reboot test on a dedicated account/machine is needed; global cache purging during the user's active session would confound and disrupt the measurement. |
| Claim input-to-photon, energy or GPU superiority | **Deferred** | IPC acknowledgements, enqueue observations and process CPU do not establish these. They require display/hitch capture and GPU/energy instrumentation with controlled host activity. |

IINA's timer behavior was checked in its
[1.4.4 PlayerCore implementation](https://github.com/iina/iina/blob/v1.4.4/iina/PlayerCore.swift#L2513).
The reference harness uses the supported
[mpv JSON IPC interface](https://mpv.io/manual/stable/#json-ipc).
SwiftUI trace interpretation follows Apple's distinction between view updates
and rendering work in
[Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/).

## Validation

The initial follow-up focused run passed **94 tests in nine suites**. The new blocked-save
regression confirms native shutdown can proceed while a background write is
blocked, the main actor remains available, Quit does not finish prematurely,
and the final saved position is the latest value. Existing startup cancellation,
blocked restore, bounded source preparation, write-error and close/reopen tests
also passed. The architecture check passed. The final benchmark app built and
passed bundle/signature checks with 27 Mach-O images.

The initial follow-up added opt-in measurement controls: heartbeat
disabling, a benchmark window-animation switch and a startup-shell marker.
Production keeps its existing animation and playback behavior; the extra
startup marker view is constructed only in the opted-in benchmark. The prior
performance and correctness fixes remain in the workspace. No replacement
renderer, speculative persistence migration or blanket cache purge was added.

## Evidence and repeatability

Raw receipts are in `QualificationArtifacts/LifecyclePerformance/Followup/`:
`comparison-final/summary.json` and `comparison-final/statistics.json`,
`first-window/summary.json`, `history-readiness/summary.json`, per-run logs and resource
samples, `audit4-source-manifest.json`, `audit5-source-manifest.json`, the animation and
retained-memory runs, and the isolated IINA source references. The resource
comparison uses audit4; audit5 adds only a guard preventing the startup-probe
view from being constructed in production. Both exercise the same opted-in
benchmark path. The retry trace is `/tmp/illiquid-followup-ui.trace`; its exported
summary and zero-row SwiftUI receipt accompany the audit logs.
`reference-smoke` and `comparison` contain failed harness attempts and are not
included in the final medians. `reference-smoke2` supplies the separately labeled
single IINA close observation. The measured Illiquid build excludes the user's
concurrent OSD/PlayerRootView edits; integrated regression tests use the workspace.

`Scripts/profile-player-comparison.py` rejects normal IINA/Illiquid bundle IDs.
Build Illiquid with the benchmark identity as shown in the lifecycle report.
Prepare a disposable IINA copy (the measured version was 1.4.4):

```sh
ditto /Applications/IINA.app /tmp/illiquid-performance-IINA.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.IINAPerformanceBenchmark' /tmp/illiquid-performance-IINA.app/Contents/Info.plist
codesign --force --deep --sign - /tmp/illiquid-performance-IINA.app
python3 - <<'PYTHON'
import pathlib, plistlib
info = plistlib.loads(pathlib.Path('/tmp/illiquid-performance-IINA.app/Contents/Info.plist').read_bytes())
support = pathlib.Path.home() / 'Library/Application Support/com.example.IINAPerformanceBenchmark'
support.mkdir(exist_ok=True)
for marker in ['.firstLaunchAfter' + info['CFBundleShortVersionString'], '.installedDefaultPlugins']:
    (support / marker).touch()
PYTHON
swiftc Scripts/performance-app-control.swift -o /tmp/illiquid-performance-app-control
```

These first-run markers suppress the guide/plugin installation only in the
isolated copy. Then pass the prepared paths:

```sh
python3 Scripts/profile-player-comparison.py \
  --illiquid /tmp/illiquid-performance-audit5/Illiquid.app \
  --iina /tmp/illiquid-performance-IINA.app \
  --fixtures /tmp/illiquid-performance-fixtures \
  --control /tmp/illiquid-performance-app-control \
  --output QualificationArtifacts/LifecyclePerformance/new-reference-comparison \
  --repeats 3
```

Run one benchmark at a time. Raw executable/fixture/helper hashes and protocol
settings belong with each result. Reference native close uses Accessibility on only the owned PID; Illiquid
uses a benchmark command calling NSWindow close. Neither uses broad UI scripting
or a global key press. These different control endpoints are recorded. Failed or unavailable
control operations are retained as failures, not counted as latency samples.


## Joint lifecycle/playback pass — 2026-10-06

A further pass found an unbounded collection in the production renderer
observation journal. Every accepted audio/video interval was retained until the
next presentation epoch. Near EOF, each clock observation flattened that history
and searched all ends, even though readiness only needs the earliest start per
stream and drain only needs the latest end. The implementation now retains those
extrema. Stale-epoch rejection, finite-time validation, latched evidence, and the
requirement for an actual renderer-clock observation are preserved. Submission
still does not establish visible or audible output.

A regression compares the new journal with the previous array implementation
across 40,000 deterministic mixed events: reordered submissions, multiple stream
kinds, stale epochs, clock reversal, invalid clock observations, EOF before/after
samples, and observations after evidence has latched. A separate 100,000-frame
case checks the longest audio tail and a fresh epoch. The focused run passed
23 tests, including the existing differential readiness/drain contracts.

`Scripts/profile-renderer-observation.py` compiles the exact before/after journal
sources with `swiftc -O`, extracts their supporting enums from the production
contract, and alternates fresh processes for five repetitions at each size.
Median costs:

| Submitted intervals | Before: 100 EOF checks | After: 100 EOF checks |
| --- | ---: | ---: |
| 1,000 | 0.283 ms | 0.010 ms |
| 100,000 | 25.176 ms | 0.014 ms |
| 770,000 | 199.296 ms | 0.020 ms |

At 770,000 submissions the benchmark process's median peak RSS was 46.3 MiB
before and 5.7 MiB after; after enqueue alone it was 28.6 versus 5.6 MiB.
These include process/framework/allocator costs. The count approximates two
hours of 60 fps video plus 48 kHz/1024-sample audio packets, but events are
compressed: this is **not** two hours of live playback or a whole-app memory
measurement. Enqueue cost increased from 17.3 to 34.3 ms for the entire 770,000
batch (about 22 ns more per submission), in exchange for bounded retention and
constant-cost EOF observations. No material shutdown-speed claim follows from
the microbenchmark's sub-millisecond reset measurements.

Other candidates in this pass:

| Idea | Disposition | Evidence/reason |
| --- | --- | --- |
| Cache each video format description | **Dropped for now** | Six alternating optimized microbenchmark pairs for NV12, P010 and BGRA found creation around 4.95–5.16 microseconds versus 4.09–4.40 for validation/reuse. Less than one microsecond per frame does not justify another cache here. A cache would need Apple's full attachment-aware matching, not only dimensions/pixel format. |
| Remove the PCM copy into Core Media | **Deferred** | The six-second native sample did not identify it as a hot path. The tested stereo 48 kHz float stream copies about 0.37 MiB/s. Escaping a Swift `Data.withUnsafeBytes` pointer would be invalid; a future zero-copy implementation needs explicit retained allocation ownership and proof under multichannel playback, seeks and renderer flush. |
| Replace sidebar rows or eager directory scanning | **Dropped as duplicate work** | Source inspection confirms lazy rows and cancellable asynchronous directory/metadata loading already exist. No measured cause supports a rewrite in this pass. |
| Rework native/subtitle initialization | **Deferred** | Moving graph or libass setup onto first Open risks shifting startup cost into media readiness and changes error/lifetime handling. The earlier loading-shell/history results and ownership requirements still apply; this journal change does not require that redesign. |

Apple documents the attachment-aware validation contract in
[CMVideoFormatDescriptionMatchesImageBuffer](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptionmatchesimagebuffer(_:imagebuffer:)).
The native sample, format experiment, exact-source scaling receipts and fixture
generator are under `QualificationArtifacts/LifecyclePerformance/JointOptimization/`.


The expanded comparison exposed a VP9 admission difference: mpv/IINA reported
VideoToolbox while Illiquid used software. In a fresh process on this M1,
`VTIsHardwareDecodeSupported(vp09)` returned false before supplemental
registration and true afterward. Registration itself took about 0.003 ms.
A benchmark-only experiment now registers before the query; it requires both
the benchmark bundle identity and explicit master/VP9 flags. **Production VP9
admission remains unchanged.** Hardware reduced steady resource use but slowed
some first-open and exact-seek transactions, so default enablement is deferred
until both paths qualify together. Unsupported hardware still returns false;
explicit software preference and FFmpeg fallback remain respected. See Apple's
[supplemental-decoder opt-in contract](https://developer.apple.com/documentation/videotoolbox/vtregistersupplementalvideodecoderifavailable(_:)) and
[FFmpeg's decoder setup](https://github.com/FFmpeg/FFmpeg/blob/n8.1.1/libavcodec/videotoolbox.c).

The exploratory `matrix` and interrupted `final-matrix` used BGRA software
output, which differs from production. Their VP9 CPU/memory differences cannot
be presented as production improvements. The harness now explicitly selects
planar output (the same concrete native decoder policy as production), records
that selection, and removes inherited benchmark tuning flags. Hardware VP9
requires `--experimental-vp9-hardware`. Completed exploratory runs remain in the
receipts; interrupted runs are not counted as final qualification.

The new output comparison caught an existing shared metadata bug: looking up
the component depth of `AV_PIX_FMT_VIDEOTOOLBOX` returned zero. The shim now
resolves the backing `AVHWFramesContext.sw_format`, preserving actual decoded
bit depth in frame metadata passed to PiP policy. This does not by itself
establish a change in PiP eligibility. The test reads pixel storage using
its actual CVPixelBuffer format independently of that metadata. All 96 compared
frame pairs matched exactly for pixel bytes, timestamps, durations, dimensions,
pixel format, range, primaries, transfer, matrix and component depth: H.264,
HEVC 10-bit, VP9 8-bit and VP9 10-bit; first frames and frames after a 1.25-second
seek. This qualifies these synthetic fixtures, not arbitrary HDR content or
all VP9 profiles/devices.

A coalescer experiment cleared queued requests before the first delivery,
reducing a synthetic 1,000-request burst from two deliveries to one while still
handling requests during delivery. **Deferred; production retains the original
coalescer.** The full-app result was not a dependable improvement: fewer
follow-up operations sometimes created more freshly scheduled tasks. The
three-build ablation below checks this distinction. The request-during-delivery
regression remains, and the burst test now explicitly checks the retained policy.
No debounce, timer, frame cap or urgent-path delay was added.

The audit10 focused run passed **191 tests in 21 suites**, including output
comparisons, six seeks each for H.264/HEVC/VP9, coalescer races, EOF contracts,
PiP eligibility, damaged-stream policies, persistence, startup and close/reopen.
Hardware output tests explicitly register the supplemental VP9 decoder; they
qualify that experiment, not production default admission. The earlier audit7
was rejected for depth metadata; audit8 reused a stale SwiftPM system-header
consumer and is excluded; audit9 failed compilation while renaming the helper.
Audit10 rebuilt both Swift callers and passed output equality, but had default
VP9 registration and is superseded by audit11 with strict experiment gating.

Additional exploratory live checks passed for VP9 10-bit/P010 and VP9 4:4:4.
The former used VideoToolbox; the latter remained software yuv444p/BGRA. Both
advanced their clocks, held on pause, sought, stopped near EOF, closed to a
retained process, and reopened the same file. These used audit10 and the BGRA
benchmark policy. The 4:4:4 observation verifies software playability; it does
not simulate a midstream hardware-device failure.

### Corrected production-policy experiment

`JointOptimization/production-matrix` completed 45 serial runs: three fresh
processes per empty/H.264 1080p/H.264 4K/HEVC 10-bit 1080p60/VP9 1080p60/animated
ASS case for audit5 and audit11, plus three VP9 runs each for audit11's hardware
experiment, mpv and IINA. Planar software output was explicit, heartbeat was off,
window targets were 960×540 points, and player order rotated. All completed media
runs advanced with wall time, held on pause, completed exact seeks, and stopped
near EOF. Native runs additionally closed/reopened the same file and quit with
exit zero. Near-EOF clock evidence does not prove physical audio/video drain.

The corrected VP9 comparison (medians, three runs each):

| Player/configuration | Process CPU, one core | End footprint |
| --- | ---: | ---: |
| Illiquid audit11, default software planar | 21.55% | 133.5 MiB |
| Illiquid audit11, supplemental VP9 hardware experiment | 5.83% | 75.2 MiB |
| mpv 0.41.0, VideoToolbox/gpu-next | 18.86% | 203.4 MiB |
| IINA 1.4.4, VideoToolbox/libmpv | 6.66% | 389.7 MiB |

The hardware experiment reduced this sample's CPU about 73% and footprint about
44%, but configured-player-to-first-submission increased from 86 to 142 ms.
The three exact-seek target medians were 224/338/82 ms in software versus
287/347/78 ms in hardware. Submission/command endpoints are not scanout.
Different reference renderer versions/configurations and process-only accounting
prevent a quality/energy ranking. These results support retaining an experiment,
**not enabling VP9 hardware by default**. A future attempt needs a qualified
software/hardware seek handoff; the existing H.264-specific verified-IDR handoff
cannot simply be applied to VP9 packet key flags.

Audit11 also showed modest CPU/seek increases in several hardware-decoded cases
versus audit5. Fewer observation deliveries did not consistently mean fewer
scheduled tasks: for example, one HEVC run scheduled 329 rather than 247 tasks.
The coalescer change therefore required a separate ablation before acceptance;
its queued-burst test result alone is insufficient performance evidence.

### Retained candidate and ablation

The final candidate is **audit12**: bounded renderer observations, corrected
hardware-frame component-depth metadata, and the earlier lifecycle fixes.
It retains the original coalescer and production decoder admission. Supplemental
VP9 registration is strictly benchmark-only. The build passed signature and
27-Mach-O validation; bundled native library bytes match audit5.

`coalescer-ablation` contains 18 serial runs, rotating audit5, audit11 and audit12
on 4K H.264 and 1080p60 10-bit HEVC, three repetitions per cell. Audit12 and
audit11 differ only in the coalescer implementation. Medians:

| Case | Audit5 CPU | Audit12 CPU | Audit11 coalescer experiment CPU |
| --- | ---: | ---: | ---: |
| 4K H.264 | 4.69% | 4.62% | 5.48% |
| HEVC 10-bit 1080p60 | 5.61% | 5.89% | 7.20% |

These are small, noisy whole-process samples. HEVC ordering reversed between
individual rounds; audit12 ranged from 5.82–7.49%, and audit5 from 5.55–7.42%.
The result does not establish a steady-playback CPU improvement for audit12.
It does justify **deferring the coalescer change** rather than accepting it
because its synthetic burst counter improved. No production coalescer change
remains in the patch.

A 4K backward-seek cluster required further checking. Five additional alternating
pairs with process-filtered native OSLog stages (`seek-pairs`) produced medians
445/162/274 ms before and 449/160/265 ms after for the three targets. The candidate
also had one **1,094 ms outlier** at the backward target; its other four samples
were 244–290 ms. Baseline samples were 248–378 ms. The outlier's target-frame
decode stage reached 1,090 ms, while demux completed below 1 ms and enqueue
followed decode by less than 1 ms. This locates the delay before presentation,
but does not establish its root cause or prove it existed before the patch.
Info logging adds overhead; these are separate from primary resource samples.
**Seek-tail qualification is deferred** to controlled-host decoder/preroll
profiling and reproducible long-run scheduling captures. No blanket no-regression
or tail-latency clearance is claimed, and no speculative thread/queue tuning
was added to hide the outlier.

### UI, output and final validation

Six final 4K UI runs (three per build, explicit planar policy, benchmark heartbeat
on) included 36 sidebar and 36 resize commands per build. Median acknowledgement
latencies were 7.85→7.99 ms for sidebar and 23.26→23.86 ms for resize/layout.
The heartbeat recorded 47/49 main-queue gaps above 20 ms across the three
baseline/candidate runs, with maxima 105/129 ms over the full workloads. These
are not stable tail estimates or pure resize-only samples. This supports
**no general UI-speedup claim**. These command endpoints are not
real-drag frame hitches or input-to-photon measurements. The backward-seek median
in this different workload was 370 ms before and 354 ms after, another reason
not to infer causality from a single three-run cluster.

Final audit12 live checks verified retained close, same-file reopening and
successful Quit, plus default-off close exiting with status zero after VP9
playback. Owned-window screenshots at 6 and 12 seconds show the authored moving,
rotating ASS subtitle at the expected positions in Illiquid, mpv and IINA.
This verifies those displayed samples, not animation cadence, colorimetry,
audible output or arbitrary subtitle files. All test players used local muting.

The retained source passed **193 tests in 21 suites**, architecture validation,
Python compilation and diff whitespace checks. Hardware/software output tests
compared 96 frame pairs exactly, including first frames and frames after seeks.
The final tests include the preserved coalescer policy, requests arriving during
delivery, VP9 experiment gating, bounded-journal equivalence, startup cancellation,
blocked final persistence, close/reopen and checkpoint ordering. These test
claims apply to the named fixtures and contracts, not every codec/device.

Raw receipts are under `QualificationArtifacts/LifecyclePerformance/JointOptimization/`:
`production-matrix`, `coalescer-ablation`, `seek-pairs`, `final-ui`,
`visual-and-close`, `final-retained-regressions.log`, `audit12-manifest.json`,
and `final-validation.json`. Earlier failed/interrupted builds and exploratory
BGRA runs remain separate. The source manifest binds the final measured app to
the intended changes; the user's concurrent OSD/PlayerRootView edits remain
untouched and excluded from release comparisons. Nothing was installed,
committed or pushed.

### Final disposition of the additional ideas

| Idea | Disposition | Acceptance boundary or next requirement |
| --- | --- | --- |
| Bound playback-length renderer observations | **Implemented** | Exact-source stress measurements and old-implementation equivalence tests; no claim of a two-hour live soak. |
| Preserve hardware component-depth metadata | **Implemented** | Read actual backing format; exact frame/metadata comparisons on H.264, HEVC 10-bit and VP9 8/10-bit fixtures. |
| Reduce coalescer follow-ups | **Deferred; experiment reverted** | Fewer callbacks did not reliably reduce whole-app work; require controlled net CPU/latency benefit before another implementation. |
| Enable supplemental VP9 hardware by default | **Deferred; benchmark experiment retained** | Strong steady-resource improvement but slower first-open/some seeks; requires qualified seek handoff and broader profile/device coverage. |
| Tune decoder threads/queues to suppress the 4K seek tail | **Deferred** | Capture reproducible decoder/preroll scheduling evidence on a controlled host; one delayed target-frame decode is insufficient to select a safe queue/thread change. |
| Claim smaller production closed footprint from the old 137 MiB plateau | **Dropped** | That experiment used BGRA. Corrected planar/hybrid workloads retained roughly 240–245 MiB after 4K in audit5/audit11. Cross-codec memory-pressure and long-soak qualification remains deferred. |

Together with the earlier decisions, every investigated idea is implemented,
explicitly deferred or dropped. The retained gains are source-list startup,
shutdown/checkpoint handling, usable warm close/reopen, and bounded long-playback
observation state. General empty-start, layout, energy and media-throughput
superiority are not established by this audit.

## Preview, caching and prebuffering review — 2026-10-06

This follow-up reviews Illiquid against the local Demuxe source at
`993a40376fb493d1a0784a78aea8b35dd1070715`. It adds measurements and dispositions;
it does not change production policy or modify Demuxe. Receipts are in
`QualificationArtifacts/PreviewCachingAudit/`.

### Current Illiquid strategy

Hover previews have an independent FFmpeg input and software decoder, two decode
threads, half-second cache keys and a 48-image LRU. The worker owns one physical
decode and one replaceable pending request; cancellation does not release the
active slot until native code returns. Source revisions prevent stale publication.
The UI bypasses its 40 ms debounce for cache hits and retains the previous image
while loading a new one. The generator reuses its context and can decode forward
without seeking when the next target is within two seconds.

There is no neighbor/storyboard pregeneration, disk thumbnail cache, byte limit
on cached images, or admission control tied to playback buffering/seeking. At the
UI's 368×208 size, 48 four-byte images represent about 14 MiB of pixel payload;
this excludes row alignment, decoder references and other retained resources.
The 2.5-second decode budget and 3-second caller deadline are cooperative native
cancellation boundaries, not hard preemption. The UI can retry once, so those
budgets should not be described as a three-second end-to-end hover guarantee.

`NativeTimelineThumbnailGenerator.removeAllCachedThumbnails()` clears images and
cancels worker requests, but does not clear an already idle `DecoderStorage.context`.
That context is reset when a subsequent decode observes the changed revision,
or released when the generator is destroyed. Thus an idle decoder and its input
can survive Stop/retained close. This is a source-confirmed resource-lifetime gap;
its retained footprint and close latency have not been measured in this review.
Any fix must release on the serial decode queue without racing an active C call.

Playback packet queues separately bound video at 96 packets/32 MiB/4 seconds,
audio at 192 packets/8 MiB/4 seconds, and subtitles at 64 packets/4 MiB/30 seconds.
These are backpressure thresholds, not guaranteed buffered durations or a total
process-memory cap; an empty queue can accept one oversized item. Decoded frames
and renderer reservations have separate limits. Startup waits for required first
submissions rather than filling the entire packet budget. Rebuffering currently
uses a starvation boolean without separate low/high duration thresholds.
The reported cache duration is derived from renderer enqueue progress, not a
complete seekable packet-cache range. The bounded GOP recovery buffer is for
decoder recovery, not general backward-seek caching. Inputs are currently file
URLs, including mounted storage; HTTP range-reader policies cannot be transplanted
directly into this FFmpeg path.

### Fresh verification

The focused Illiquid suite passed **74 tests in eight suites**. Two standalone
debug thumbnail probes returned images for **14/14 requests** on synthetic local
24-second H.264 fixtures:

| Generator request | 1080p | 4K |
| --- | ---: | ---: |
| First request at 1.5 seconds | 103 ms | 253 ms |
| Nearby forward requests | 16–17 ms | 59–60 ms |
| Uncached jump to 8.5 seconds | 20 ms | 73 ms |
| Exact cache hits | 0.025–0.026 ms | 0.023–0.024 ms |

These are generator caller timings, excluding UI debounce and presentation.
They do not measure preview contention during playback, long-GOP HEVC, NAS
latency, or release-app performance. The observations confirm context reuse,
forward continuation and no decode on cache hits for these fixtures.

Demuxe's **118 focused preview/cache/buffering tests passed**. A fresh TypeScript
compile matched all **207 generated JavaScript modules**, normalizing only SPDX
header lines. No tracked Demuxe files were changed. Test success did not cover
the eviction defect reproduced below.

### Transferable ideas and dispositions

| Idea | Disposition | Acceptance requirement |
| --- | --- | --- |
| Yield preview decoding during loading, seeking and playback starvation while preserving cached images | **Recommended; implementation deferred** | Port Demuxe's admission/suspension contract into Illiquid's existing worker. Verify rapid state changes, cached responsiveness and concurrent-playback frame/seek tails. |
| Bound image bytes and release idle decoder state on invalidation/close | **Recommended first; implementation deferred** | Account for actual image row bytes separately from decoder resources; retain entry limits. Verify source fencing and eventual serial-queue release, then measure retained-close footprint and reopening cost. |
| Show a nearby cached preview immediately, then refine after the pointer settles | **Recommended; implementation deferred** | Bound timestamp distance and display the represented timestamp/approximation. Measure blank time and target accuracy without increasing decode churn. |
| Prefetch a small number of nearby forward samples | **Experiment deferred** | Exploit Illiquid's existing forward decoder continuation, protect foreground entries and cancel/yield for playback. Compare useful-hit rate against wasted decode CPU and playback frame delivery before enabling. |
| Explicit buffering profiles, requested/effective diagnostics and refill hysteresis | **Deferred to slow-storage qualification** | Measure mounted-storage stalls and recovery first; maintain fast local first-frame behavior and existing queue/pool bounds. |
| Whole-movie pregeneration or Demuxe's aggressive preset as default | **Dropped for this pass** | Existing synthetic policy results do not establish a net native-media benefit; more preview coverage can require materially more decoding. |
| Share active playback decoder/frame references with preview generation | **Dropped for this pass** | Retained frames and seeks can interfere with decoder generations and pool backpressure; preserve independent ownership. |
| Increase every buffer or add disk/backward caches to fix local seek time | **Deferred absent I/O evidence** | The earlier 4K seek outlier was delayed target-frame decoding, not demux time. More packet cache does not address that observation. |

Demuxe pointers: `src/preview/controller.ts` implements suspension, independent
provider admission and byte accounting; `src/internal/machine/selectors.ts`
projects playback pressure; `src/player/preview.ts` supports cache-first nearby
images and settled refinement. `web/range-reader.js` keeps optional preview reads
separate from playback reads and preempts them on playback progress. Its ownership
and priority rules are transferable, while the browser/HTTP mechanism is not.
`src/internal/machine/buffering-policy.ts` distinguishes requested policy from
backend-effective limits; its different backends do not all enforce the same
memory/time guarantees.

### Demuxe issue to avoid copying

In `src/internal/machine/preview.ts:141–145`, the ordinary background insertion
path selects only a background entry for eviction. The opt-in `demuxe` preset
overrides that selection with the first non-storyboard entry, including foreground
entries. A three-entry cache containing foreground time 10 and background times
11/12 loses the foreground image when background time 13 is inserted. The same
sequence under the default policy retains the foreground image. This contradicts
the intended foreground protection; it is specific to the opt-in preset.

The executable reproduction and its JSON receipt are
`demuxe-foreground-eviction.mjs` and `demuxe-foreground-eviction.json` in the audit
directory. They exercise the verified generated module, not a reimplementation.
Demuxe was reviewed only and this defect remains unfixed there. Its historical
864-case synthetic scenario report also shows a tradeoff: the opt-in preset had
1.1% blank previews versus Gaussian's 3.6%, but modeled decode time was 28.6 versus
22.6 seconds, about 26% higher. Those modeled durations are not native playback
CPU or frame-drop evidence; Adaptive remains its built-in player default.

### Local-player cache direction: recency and folder context

The subsequent design discussion favors a global thumbnail cache, optional idle
generation and priority informed by actual user activity and folder navigation.
This is an agreed design direction, not an implemented scheduler or a measured
performance improvement. Compressed-input sharing remains conditional on I/O
evidence; independent decode state is still required for distant preview targets.

Use one bounded thumbnail cache across source switches, with separate RAM and
optional persistent-disk budgets. Source transaction cancellation must stop stale
publication without deleting valid images for other files. File content/version,
video track, represented timestamp, dimensions and rendering version determine
validity; user activity determines scheduling and retention priority. Cached
thumbnails may also come from sparse, nonblocking extraction of playback frames,
provided full-resolution playback buffers are promptly released.

The proposed scheduling order is:

1. The exact foreground hover request.
2. Missing samples near the current video's hover or resume position.
3. Media actually visible in the source browser's viewport.
4. Nearby items in the focused folder or playlist, preferring likely next items.
5. Recently opened or explored videos outside the current folder.

Keep foreground priority categorical. Within speculative work, combine bounded
folder/playlist proximity, decaying interaction recency and missing coverage,
then account for measured generation cost. Visiting another folder replaces its
priority promptly, cancels obsolete queued work and uses a short settling delay
to avoid decode churn during navigation. Background generation must not count
as user interest or promote its own output indefinitely. Give each likely video
a sparse first pass before spending the budget on denser samples for one file;
failed/slow files have bounded attempts and cannot monopolize the queue.

Scheduling and eviction should use related but different rules. Generation asks
which missing image is likely to be useful next; eviction considers actual use,
current context, byte cost and whether an image was only speculative. Protect
foreground entries from speculative insertion; do not permanently pin whole
folders. Disk eviction can preserve recently useful videos longer than RAM,
without retaining their native decoders or full-resolution frames.

Current integration points are `AppModel.activeSourceTab`, the sidebar's expanded
folders and filtered `visibleRows`, the player's current source/playlist, and
saved playback position/duration. `visibleRows` describes the complete filtered
tree, not the on-screen viewport. Actual viewport membership and last-interaction
times need explicit signals. No new recursive filesystem scan should be triggered
just to compute thumbnail priority; use entries already discovered by the browser.
Filesystem creation/modification dates are content metadata, not user recency.

Idle generation remains an off-by-default Behavior option, initially restricted
to a visible player window while playback is paused or stopped. Closing the window,
starting playback, opening/seeking, disabling the option or quitting cancels
speculative work. Resource-pressure admission applies before opening another
decoder. Closed-window generation would require its own explicit preference.

Before adopting numeric weights or persistent-cache defaults, compare pure LRU
against recency-only and recency-plus-folder policies on the same interaction
traces: sequential episodes, rapid folder switches, repeated visits, random
scrubbing and large filtered folders. Record foreground hit rate/latency, useful
versus wasted generated images, decoder time, retained bytes, and background
cancellations. Native runs must additionally verify first-frame/seek latency,
frame delivery and close-time resource release. Cache policy simulations alone
cannot establish media performance or energy savings.

### Implemented global thumbnail cache and user limits — 2026-10-06

The preceding design is now implemented for the native thumbnail path. This
supersedes the earlier deferrals for global small-image caching, idle generation,
foreground protection, nearby cached presentation, and serial decoder release.
It does not introduce compressed-media sharing, change playback queue sizes, or
extract thumbnails from playback frames. Those remain separate experiments.

Settings → Behavior → Thumbnail Previews exposes:

| Control | Default | Allowed range / behavior |
| --- | --- | --- |
| Memory cache | 32 MiB | 8–128 MiB of image row-byte payload, shared across videos |
| Disk cache | 256 MiB | 0–2048 MiB; zero disables storage and removes indexed entries |
| Generate while idle | Off | Paused/stopped playback only; no library-wide scan |
| Generate with player window closed | Off | Separate opt-in; requires keeping the app running |
| Priority | Balanced | Balanced, nearby files, or recent activity |
| Videos per pass | 8 | 1–64 |
| Previews per video | 12 | 1–64 |
| Idle delay | 3 seconds | 1–30 seconds after relevant activity settles |
| Work budget per pass | 15 seconds | 1–120 seconds of wall time, followed by cancellation |
| Recent activity horizon | 7 days | 1–30 days; interaction history is session-local |

Preferences persist and are clamped before use. The UI includes explicit cache
clearing and a generation status. Decoder allocations, in-flight images and
metadata are outside the image-cache quotas; the limits are not total-process
memory or CPU guarantees. Additional entry guards are 512 RAM images and 8192
disk entries. Native OS/codec cancellation remains cooperative.

The scheduler takes actual row viewport visibility from SwiftUI scroll visibility
callbacks, the explicitly expanded folder, already-discovered filtered files,
nearby playlist items and bounded recent interaction records. It does not start
a new directory walk. The current video and viewport are hard priority tiers;
the selected priority adjusts folder/proximity versus decaying recency within
speculative work. Ranking runs off the main actor. A pass starts with one sample
per candidate before adding progressively broader time coverage. Failures do
not monopolize the first pass, and navigation replaces pending work after the
configured settling delay. Continuous idle looping is deliberately absent.

Starting playback, loading/seeking, foreground preview interaction, disabling
generation, closing the window without the separate opt-in, or shutdown cancels
speculative work. Low Power Mode and serious/critical thermal states suspend it;
power/thermal notifications re-evaluate admission. The same thumbnail decoder
worker serves foreground and background requests with foreground priority, while
remaining independent of the playback decoder.

Source changes now retire work and release native context on the serial worker
without throwing away other videos' valid images. Cache identity includes path,
target-file inode/size/nanosecond modification and creation times, half-second
bucket, dimensions and a rendering/default-video-selection version. `stat`
follows symlinks; a target replacement cannot reuse the link's unchanged metadata.
This is metadata-based invalidation, not a whole-file content hash.

Both identity reads and metadata probes have one physical worker and a bounded
caller lifetime. A stuck mounted filesystem cannot accumulate native workers or
block the RAM-cache actor. Expired/cancelled callers do not release physical
ownership before the native operation returns. The existing decode worker still
keeps one active decode and one replaceable pending request.

RAM uses actual image row bytes. Disk stores small JPEG previews in the user's
`Caches/Illiquid/Thumbnails-v1` directory. Foreground use promotes speculative
entries; background generation cannot evict foreground-used entries and does
not promote itself. JPEG persistence is best-effort at utility priority, with
one active write and one replaceable pending image. Encoding is outside the disk
actor so it cannot serialize foreground disk lookups behind compression. Clear
uses a generation fence so old queued writes cannot repopulate the cache.

Hover first checks exact RAM/disk entries and nearby RAM images, then refines
with native decoding. Approximate images display their represented bucket time
with an approximation marker. Nearby lookup is limited to at most 30 seconds
and never crosses file version or dimensions. Arbitrary nearest-neighbor lookup
over the entire disk cache is not implemented. Disk JPEG previews are lossy;
playback output is unchanged.

#### Validation and measurements

The final focused run passed **325 tests in 42 suites**, including the existing
playback coordinator/foundation/chrome/lifecycle regressions. New checks cover
priority changes, budget sanitization, stale file/symlink identity, RAM eviction,
disk round trips, corrupt entries, clearing with queued writes, nearest-image
isolation, serial resource release, stalled metadata ownership, folder replacement,
playback cancellation, closed-window opt-in and work-budget expiry.

A real idle pass prepared **six previews across H.264 and HEVC videos in about
2.5 seconds including the one-second test idle delay**, while the player remained
idle with no source loaded. The settings card was rendered and visually inspected.
Architecture validation and the release build passed. The existing Metal
Sendable warnings remain; no new compiler warnings were introduced by this work.

Final debug probes used local synthetic H.264 fixtures and the UI's 368×208 bound:

| Measurement | Result |
| --- | --- |
| 1080p cold first preview, disk enabled, three runs | 95.6–101.5 ms; median 98.6 ms |
| Same fixture/size with disk disabled, alternating runs | 94.5–98.3 ms; median 96.7 ms |
| RAM hit, median across 60 disk-enabled requests | 0.031 ms |
| Fresh-process persisted hit, native decoding prohibited | 5.23 ms |
| 4K cold first preview, one run | 246 ms |

The paired first-preview difference is about 2 ms in this small sample; this does
not establish a statistically meaningful regression or speedup. The earlier
320×180 generator probe is not an identical-size baseline. Early probes exposed
avoidable foreground persistence/empty-cache work: writes were moved off the
return path and empty disk indices now bypass hashing. Intermediate receipts
remain separate from final results. These measurements exclude UI presentation,
concurrent active-playback frame delivery and real NAS behavior. Blocked-I/O tests
prove caller/ownership boundaries using injected stalls, not every OS mount's
recovery behavior. Broad codec/device/energy and long-session cache qualification
remain deferred; background generation therefore remains opt-in.

Implementation: `ThumbnailPolicy.swift`, `ThumbnailBackgroundScheduler.swift`,
`NativeTimelineThumbnailGenerator.swift`, `NativeThumbnailCache.swift`,
`NativeThumbnailDiskCache.swift`, `ThumbnailBlockingReader.swift`, and
`NativeThumbnailMetadataReader.swift`; app/controller/sidebar/settings hooks connect
the policy to actual user activity. Receipts and the rendered settings image are
under `QualificationArtifacts/ThumbnailCache/`. The review app is packaged there
under a separate bundle identifier, but **failed the packaging dependency check**:
the bundled Homebrew `libavfilter` links Apple's OpenGL framework. The same link
is present in the earlier audit12 bundle, so this is not introduced by the
thumbnail change. No dependency check was relaxed. The release executable builds,
but the assembled `.app` is not a qualified distribution artifact; resolving the
native SDK's transitive dependency is deferred. Nothing is installed, committed
or pushed.

#### Thumbnail implementation review (2026-10-06)

The follow-up review found and fixed four correctness/performance issues:

- Cancelling a background pass skipped native-resource cleanup when its scheduler
  generation changed. Cleanup now runs for every started pass, using an idle-only
  worker operation that cannot cancel a newer decode.
- Foreground promotion could be lost when another image replaced its pending disk
  write. Promotion now updates disk metadata separately, including an encode that
  is still in flight. A foreground insert also promotes an already resident
  background image instead of leaving it eligible for speculative eviction.
  Ordinary RAM hits still avoid disk work; first promotion and the existing
  once-per-minute recency refresh await the disk metadata operation, not encoding.
- A failed hover could retain a previous image arbitrarily far from the pointer.
  Retained images now obey the same adaptive nearby window (at most 30 seconds)
  as cache lookup, preserving the represented timestamp only within that window.
- Removing a visible row beyond the 2,048-entry discovery prefix did not restart
  scheduling when that prefix was unchanged. Viewport membership changes now
  cancel the obsolete pass too.

Regression coverage includes a deliberately stalled JPEG writer with multiple
foreground promotions, an active native worker surviving late idle cleanup,
foreground reinsertion under RAM pressure, cancelled-pass cleanup, distant-hover
fallback and removal beyond the discovery prefix. **330 tests in 42 suites passed
in 19.956 seconds**, including native fixture previews and playback/lifecycle
regressions. Architecture validation and the release build (66.74 seconds) passed;
only the existing Metal Sendable warnings remained. Review receipts are kept separately
in `QualificationArtifacts/ThumbnailCache/Review/`; the preceding implementation
manifest and measurements remain historical evidence.

Three new alternating debug fixture pairs measured cold 1080p preview medians of
95.85 ms with disk enabled and 95.02 ms with disk disabled. RAM-hit medians were
0.032 and 0.030 ms respectively. First foreground promotion of a persisted
background image took 0.20–0.51 ms; a fresh-process exact disk hit with native
decoding prohibited for that lookup took 5.44 ms. These small samples do not
establish a significant performance difference; the earlier qualification limits
and native-SDK packaging blocker still apply.

#### Preview timing and decoding optimization (2026-10-06)

Two measured changes are enabled:

- A nearby forward hover now checks the selected video stream's existing FFmpeg
  keyframe index. When a sufficiently later keyframe offers a shortcut, it seeks
  there and decodes to the same requested frame, instead of decoding every frame
  between the previous hover and the target. No packet scan or additional file
  read is performed to discover keyframes. Missing index entries retain the
  previous continuation policy. Tiny shortcuts are ignored to avoid paying seek
  and buffer setup costs for only a few frames.
- Background generation still prepares one image for every selected video first.
  Refinement then visits each video for at most four samples before moving on,
  preserving sample priority, cancellation checks and the existing work budget.
  This reuses the decoder without letting one video's full plan monopolize a pass.

Final debug measurements used three alternating baseline/candidate pairs per
fixture on the M1, at the UI's 368×208 bound. Inputs are local synthetic H.264
1080p30/4K30, HEVC 10-bit 1080p60 and VP9 1080p60 files. Their paths, formats and
hashes are recorded in `QualificationArtifacts/ThumbnailOptimization/fixtures.json`.
First-preview numbers are cold decoder/cache measurements with warm OS file pages,
not cold storage or pointer-to-photon latency. The UI's unchanged 40 ms miss
debounce and actual presentation delay are outside these generator timings.

| Preview operation | Before | After |
| --- | --- | --- |
| First H.264 1080p preview | 94 ms | 94 ms |
| First H.264 4K preview | 253 ms | 243 ms |
| First HEVC 10-bit 1080p60 preview | 348 ms | 346 ms |
| First VP9 1080p60 preview | 146 ms | 145 ms |
| H.264 1080p hover crossing the tested keyframe | 16.35 ms | 5.64 ms |
| H.264 4K hover crossing the tested keyframe | 60.99 ms | 17.30 ms |
| 24 background previews across 1080p and 4K files | 3.293 s | 3.194 s |
| Decoder opens for that background batch | 24 | 8 |

The keyframe-crossing cases improve by approximately 66% and 72%, respectively.
Total process CPU for the seven-request H.264 workloads falls about 8% (1080p)
and 11% (4K). Cold generation has no intentional shortcut, so its small timing
differences are not claimed as an optimization. Typical uncached forward steps
remain about 16 ms for H.264 1080p, 61 ms for H.264 4K, 111 ms for HEVC 10-bit
1080p60 and 36 ms for VP9 1080p60. A separate final cache probe measured a
0.026 ms median RAM hit and a 5.20 ms fresh-process exact disk hit with native
decoding prohibited for that lookup. Background batch timing excludes the
configured idle wait and its initial metadata probes; its roughly 3% elapsed
improvement is modest, despite the substantial reduction in decoder opens.

All final candidate foreground and batch image hashes matched their baseline
counterparts. Additional regressions compare indexed previews against both the
old continuation path and independent fresh seeks, and verify reduced discarded
frames at the tested keyframe. Interlacing, nonzero origins, EOF fallback, partial
decode recovery, stale sources, cancellation and bounded worker ownership remain
covered. The final focused run passed **338 tests in 45 suites in 29.314 seconds**;
architecture checks and the release build (84.51 seconds) passed. The existing
Metal Sendable warnings remain. Receipts are under
`QualificationArtifacts/ThumbnailOptimization/`, including `final-summary.json`.

Other experiments are retained only as internal benchmark controls:

- **Dropped for production:** one/four-thread decoder changes. Four threads
  sometimes reduced wall time, but consumed more CPU in the H.264 samples;
  one thread regressed high-resolution cases. The two-thread limit remains.
- **Deferred:** planar preview output. Its pixels differ from the established
  BGRA route, and timing gains were inconsistent. Color/HDR qualification would
  be required before choosing a different output path.
- **Dropped for production:** explicit foreground queue priority. Quieter paired
  runs showed no meaningful benefit, so the established scheduling priority is
  preserved. The pending-request priority test exercises the opt-in experiment.
- **Deferred:** reusing BGRA output pools across seeks, larger decoder pools,
  hardware preview decoding and keyframe-only approximate previews. Those need
  separate memory, ownership, fidelity or concurrent-playback qualification.

Early screening ran during unrelated compilation/indexing and includes deadline
failures and multi-second latencies. Those receipts are preserved separately;
they are not used as the final baseline. The final results do not establish NAS,
HDR, low-power, broad-device, long-session or concurrent-playback performance.
Production changes retain the same decode route/thread limit, preserve exact
preview pixels in this matrix, and keep speculative work restricted to idle
playback. The existing packaging dependency blocker remains unresolved.

To reproduce the foreground comparison after building the debug tests:

```sh
swift test --filter ThumbnailOptimizationQualificationTests
Scripts/profile-thumbnails.py --direct-runner \
  --fixture /path/to/video.mp4 --output /tmp/preview-comparison \
  --runs 3 --mode baseline --mode indexed
```

The output directory must be empty. For a two-video background comparison, supply
two `--fixture` arguments plus `--batch --batch-size 1 --batch-size 4`. The script
runs probes sequentially, preserves failures, reports process CPU as well as wall
time, and exits unsuccessfully if any preview is missing. It does not launch the
installed app. The optional direct runner uses the active Xcode toolchain's Swift
Testing helper to avoid repeated SwiftPM manifest compilation between samples.

## 2026-10-06: UI responsiveness, cache controls and storage scheduling

This pass follows commit `0500268ce09e78f17a758e9e96a56fd19fef3fd9` and covers
all six proposed followups. Receipts are in the ignored
`QualificationArtifacts/ResponsivenessAudit/` directory. Tests and probes used an
M1 on macOS 26.5.2, synthetic local files, warm OS file pages and isolated app
identities/preferences/caches. The installed app was not replaced. Unrelated
edits to `PlaybackOSD.swift` and `PlayerRootView.swift` were preserved; their
hashes are in `baseline.json` and checked in `manifest.json`.

| Area | Disposition | Result and remaining boundary |
| --- | --- | --- |
| Preview/open/seek UI latency | Implemented and measured | Instrumented real hover handler, cache/image readiness and an AppKit draw witness. Fixed a source-revision race that cancelled a fresh hover in the same SwiftUI update. Physical input and compositor presentation remain unmeasured. |
| Cold previews / backward seeks | Measured; further decoder changes deferred | Four codecs, paused/playing hover sequences and alternating exact seeks pass. Keep established decoder route, pixel size and thread limit; pool/hardware/output changes need fidelity and concurrent-playback evidence. |
| Cache usability | Implemented | Economical/Balanced/Extensive presets, live RAM/disk/resident-image usage, background folder exclusions, memory-pressure suspension and resident trimming. |
| Large libraries / navigation | Implemented and measured | Reuse tab root indexes and direct file-item lookups, linear folder deduplication, session-local per-tab search/scroll restoration, accessible search label. Full VoiceOver walkthrough and a native-list/background-index redesign are deferred. |
| Slow/unavailable storage | Implemented and tested | Reserve an interactive slot, replace polling with completion notifications, retain bounded waits/deadlines and physical ownership after cancellation. Actual NAS disconnect/reconnect qualification is deferred. |
| Idle/closed resource use | Measured; retention investigation deferred | Completed 24 mixed-codec cycles plus an eight-cycle memory-map followup. Closed CPU is low; retained process memory is unresolved. Hours-long, energy and broad-device qualification remain deferred. |

Presets only change budgets, never background-generation consent. Exclusions
include lexical subfolders and apply before background metadata probing; they
leave foreground hover available. Existing preferences migrate with defaults for
missing fields. Usage refresh runs every two seconds only while settings is
mounted. Warning pressure reclaims half the current resident bytes, speculative
images first; critical pressure releases resident thumbnails and the independent
preview decoder. Disk entries and configured limits survive, and stale work is
fenced from repopulating the trimmed resident cache. The settings render was
visually checked (`settings.png`).

### Preview observations

The three-run cohort (`previews/summary.json`) completed 168 hover requests with
playback-clock checks. The final release executable repeated all four fixtures
once (`final-previews/summary.json`, 56 more requests). Values below measure
command injection to the first draw witness observed by the probe, including
command/polling overhead and the existing 40 ms cache-miss debounce.

| Fixture | Earlier cohort cold paused median | Final cold paused | Final cold playing |
| --- | ---: | ---: | ---: |
| H.264 1080p30 | 185 ms | 172 ms | 124 ms |
| H.264 4K30 | 315 ms | 272 ms | 266 ms |
| HEVC 10-bit 1080p60 | 425 ms | 403 ms | 412 ms |
| VP9 1080p60 | 219 ms | 215 ms | 200 ms |

These are observations across successive candidates, **not a decoder speedup
comparison**. Each paused first request starts with cleared thumbnails/decoder;
the subsequent playing first request clears those again but retains the warmed
image renderer. Final repeated cached positions reached the first witness in
16–42 ms. A witness can represent a nearby cached image before exact refinement;
separate image-ready stages are preserved. The AppKit witness and screenshots do
not prove compositor scan-out timing. Early failed cohorts retain evidence of the
source-revision cancellation, which occurred within 9–17 ms of the request.

Final 4K exact-seek pipeline completion was 199–216 ms forward to 18.5 seconds
and approximately 165 ms backward to 2 seconds (three each, paused). These
endpoints confirm pipeline completion, not displayed pixels. Broader seek tails,
real high-bitrate/HDR files and frame-drop accounting remain deferred. No new
playback decoder tuning is justified by this pass.

### Library and storage results

With 100,000 synthetic file entries, the initial candidate's worst sampled
main-queue gap was 2,232 ms. Caching roots alone left 1,375–1,454 ms gaps; replacing
the row context-menu linear file search with an indexed lookup reduced the
maximum to 310–329 ms across three runs. Query projections were 138–226 ms and
post-query process CPU 0.32–0.45% of one core. A separate two-run experiment
without scroll restoration showed no meaningful improvement, so restoration is
retained. This does not make 100,000 rows hitch-free: initial indexing still
runs on the main actor, and a larger list/index redesign is deferred.

Final 10,000-item runs configured in 540–613 ms, projected queries in 14–26 ms
and had maximum sampled queue gaps of 63–68 ms (initial candidate: 644 ms in
one run). The 10 ms diagnostic heartbeat is enabled for navigation and previews,
so these are instrumented observations. Query commands bypass physical typing.
Per-tab state and index/deduplication semantics have regression coverage. The
keyboard audit retained existing bindings, including Cmd-F fullscreen, rather
than introducing a conflicting search binding.

A controlled executor probe submitted 32 concurrent synthetic 1 ms reads with a
two-second deadline. Committed polling completed 22 and timed out 10 in 2.004 s;
completion-driven admission completed all 32 in 51 ms. A stalled background
worker still allowed a healthy interactive request in approximately 0.03 ms.
These test queue admission, **not NAS throughput or kernel I/O cancellation**.
Logical cancellation continues to hold the physical slot until the worker exits.
Polling is dropped; the default two-slot executor allows one background owner
and reserves capacity for interactive work.

### mpv/IINA and lifecycle controls

Three rotated-order H.264 4K runs used mpv 0.41.0, IINA 1.4.4 and an intermediate
Illiquid candidate (`reference-4k/summary.json`). Hardware decode was requested,
audio muted per player, target windows 960×540 points, diagnostic heartbeat off,
and IINA automatic thumbnail generation explicitly disabled. This isolates a
playback control; it is not a default-settings comparison. IINA 1.4.4 otherwise
[defaults to thumbnail previews, a 240-pixel width and a 500 MB cache limit](https://raw.githubusercontent.com/iina/iina/v1.4.4/iina/Preference.swift).

| Player | Playing CPU | Paused CPU | Closed CPU | Playing footprint |
| --- | ---: | ---: | ---: | ---: |
| Illiquid | 4.23% | 0.37% | 0.05% | 153 MiB |
| mpv | 8.03% | 0.47% | unavailable | 424 MiB |
| IINA | 3.77% | 0.48% | 0.04% | 606 MiB |

Values are medians, process CPU as a percentage of one core. They exclude GPU,
WindowServer and other processes. mpv native window close was unavailable through
the control helper; no close ranking is claimed. Reference and native readiness
and seek endpoints differ. Native playback clocks advanced correctly, but a
native dropped-frame counter was not available: missing is not zero.

Three subsequent baseline Illiquid runs measured 4.36% median playing CPU.
The 4.23% candidate result is not evidence of a new playback CPU gain; the
cohorts were sequential and host background activity varied. Baseline closed
footprints ranged 81–232 MiB, candidate approximately 220–242 MiB. A memory
nonregression claim is therefore **not established**.

The 24-cycle mixed-codec soak completed every open/play/hover/close/reopen cycle.
Median observed open-to-first-submit was 56 ms (maximum 249 ms), median closed
CPU 0.22%, and process exit after quit 257 ms. Final reopened idle footprint was
266 MiB and 264 MiB after critical thumbnail trimming. An independent eight-cycle
followup ended at 186 MiB before trimming and 137 MiB afterward. Its pre-trim
`vmmap` reported 24.9 MiB allocated in malloc zones and 88.0 MiB dirty/swapped
fragmentation, plus 21.9 MiB resident IOSurfaces. This suggests allocator
retention contributes, but does not attribute allocations to components or prove
a leak/plateau. A longer matched baseline/candidate run with allocation ownership
tracing is deferred; speculative global allocator purges are not adopted.

### Validation and reproduction

Final source passed **396 tests in 69 suites**, architecture checks, Python
compilation and a release build. The initial broad regression run had two missing
fixture failures; repeating with separate complete synthetic fixtures passed all
396. Both logs are preserved. The existing native dependency packaging blocker
is unchanged; a successful release build and ad-hoc benchmark bundle do not
qualify a distributable application.

Each cohort records its own executable hash. The early three-run preview,
100,000-item variants, reference comparison and 24-cycle soak used successive
intermediate candidates. Final previews, 10,000-item navigation and eight-cycle
memory map share signed executable SHA-256
`412f7f20a1a65a695578fa6c83103275fbe1e525fafdedb26119ffd62f2c096b`.
`manifest.json` captures final source/script/fixture hashes, validation receipts
and each cohort identity; this is not a uniform exact-revision qualification of
all historical measurements.

Use a separate benchmark bundle with identifier `com.example.SuperplayrBenchmark`
(as required by `profile-lifecycle.py`), never the installed production bundle.
The output directory must not already exist. For example:

```sh
Scripts/profile-responsiveness.py --app /path/to/benchmark/Illiquid.app \
  --fixture /path/to/video.mp4 --runs 3 --output /tmp/preview-ui
Scripts/profile-responsiveness.py --app /path/to/benchmark/Illiquid.app \
  --mode navigation --source-count 100000 --runs 3 --output /tmp/sidebar-ui
Scripts/profile-responsiveness.py --app /path/to/benchmark/Illiquid.app \
  --mode soak --cycles 24 --runs 1 --memory-map \
  --fixture /path/to/video.mp4 --output /tmp/lifecycle-soak
```

The probe isolates session/preferences/thumbnail cache, retains failure receipts,
and exits unsuccessfully on missing previews or failed playback-clock checks.
Use multiple `--fixture` arguments to rotate media in the soak. Full physical
input/display timing, real storage faults, HDR/device/energy matrices and native
retention ownership are explicit followup qualifications, not completed claims.

## 2026-10-06: compressed-packet preview experiment

**Decision: keep packet retention experimental; do not enable speculative
read-ahead for local previews.** Reusing compressed packets substantially reduces
FFmpeg's input reads, but the local-file cohort does not show a consistent latency
or CPU improvement. The artificial slow-read cohort supports investigating
retention for I/O-bound storage. It does not qualify NAS performance or justify
sharing packet ownership with the live playback session yet.

The internal qualification initializer now offers a packet window. The public
initializer leaves it disabled. The window retains at most 32 MiB of video packet
payload and 512 packets, for the independent decoder's current file. Replay must
start at the same indexed keyframe the existing preview path would select; absent
coverage/index, corrupt packets, or exceeded bounds fall back to demux seeking.
Packet exhaustion resumes reading at the demuxer's real frontier. Source changes,
worker cancellation/resource release and memory-pressure handling release the
window with its decoder context. Decoder state is not shared with playback.

Three modes used identical two-thread software BGRA decoding and 368×208 output:

- `indexed`: current production preview policy, without packet retention.
- `packet-retain`: retain video packets already fetched, without extra reads.
- `packet-prefetch`: retain packets and attempt up to another 0.5 seconds of
  reading, capped at 32 demux calls or 50 ms per request. A blocking call can
  overrun the 50 ms admission limit; the existing request/decode deadlines remain.
  This prototype charges prefetch work to caller latency, rather than hiding its
  cost. Prefetched packets are delivered before any subsequent physical read.

The read-ahead variant runs on the request worker: speculative stalls or read
errors can affect foreground completion. It is a cost probe, not a qualified
background-prefetch service; its results do not rule out a better idle scheduler.

Each run requests 17 distinct half-second thumbnail buckets, mixing backward
visits within GOPs, forward continuation and distant seeks. No finished-image
cache hit can masquerade as a packet-cache win in this workload. Three alternating
mode-order runs cover H.264 1080p30/4K30, HEVC 10-bit 1080p60 and VP9 1080p60.
These are debug native-generator probes, not UI or simultaneous-playback probes.
OS file pages are warm; host background activity was substantial and variable.

| Fixture | AVIO bytes: baseline → retention | Retained packet payload peak | Median whole workload: baseline / retention / read-ahead |
| --- | ---: | ---: | ---: |
| H.264 1080p | 45.8 → 21.2 MB (54% less) | 6.6 MiB | 927 / 888 / 881 ms |
| H.264 4K | 177.2 → 81.8 MB (54% less) | 26.0 MiB | 3,675 / 3,961 / 3,821 ms |
| HEVC 10-bit | 16.6 → 10.7 MB (35% less) | 3.6 MiB | 8,443 / 8,030 / 8,568 ms |
| VP9 | 10.9 → 8.3 MB (24% less) | 1.1 MiB | 1,882 / 1,760 / 2,143 ms |

AVIO bytes count data fetched by FFmpeg **including filesystem-cache hits**, after
initial media opening/probing. They are not physical disk bytes. Packet payload
is additional retained compressed data, not total process footprint or a complete
native-allocation budget. Extra read-ahead fetched more data than retention alone
and raised peak payload to approximately 29 MiB for 4K. In the local baseline,
packet reads took only about 0.4–1.6% of total workload time (ratio of medians).
Decoded output/preroll frame counts were identical between modes: retaining
packets does not eliminate reference-frame decoding. All **612 local images**
matched the baseline pixel hashes, with no missing previews.

A second cohort requested a 2 ms sleep after each demux call that increased the
AVIO byte counter. This is a synthetic input-stall test; it does not model disk
throughput, network round trips, buffering or NAS cancellation. Actual sleep and
scheduling delays can exceed 2 ms substantially. In the complete 1080p cohort,
median backward preview latency was **532 ms baseline, 34 ms retention, 36 ms
read-ahead**; whole-workload medians were 13.50, 7.06 and 7.73 seconds. Thus
retention avoids repeated input stalls, whereas extra speculative work adds cost.

The delayed 4K cohort exceeded existing decode/caller deadlines on five requests:
three baseline, two read-ahead, zero retention-only. All **301 delivered images**
across the delayed cohort match the complete local baseline. Missing outputs are
preserved and make the delayed benchmark exit unsuccessfully. Some raw
`hashes_match_first_run` fields are false because the first delayed 4K baseline
itself lacked an image; `analysis.json` separately compares every delivered image
to the complete local baseline. Failed 4K runs are not a clean latency comparison
or a production qualification. No deadlines were relaxed to make the probe pass.

The production path gains no packet cache, extra reader, thread or prefetch setting
from this experiment. Packet measurement timers and simulated stalls are confined
to the internal observation-enabled qualification path. Further steps are deferred:
real slow-storage trials, matched process-memory/energy and playback-contention
measurements, and a playback seek cache with coherent audio/subtitle/generation
handling. Sharing immutable packet ranges may be useful eventually; sharing the
mutable demux/decoder cursor is not part of this prototype.

Receipts, failures, fixture hashes and test-binary identities are under
`QualificationArtifacts/PacketPreviewExperiment/`. The main `local` and `delayed`
cohorts precede final defensive argument guards (rejecting pre-keyframe targets
and negative prefetch indexes). Their supplied arguments already satisfy those
guards. Final validation and edge-case receipts identify the rebuilt binary.

To reproduce after building the qualification tests:

```sh
swift test --filter 'ThumbnailPacketWindowTests|ThumbnailOptimizationQualificationTests'
Scripts/profile-thumbnails.py --direct-runner --packet-workload --runs 3 \
  --mode indexed --mode packet-retain --mode packet-prefetch \
  --fixture /path/to/video.mp4 --output /tmp/packet-preview-local
```

Add multiple `--fixture` arguments for a matrix; add `--refill-delay-ms 2` with a
new output directory for the synthetic stall test. Failures and mismatches cause
a nonzero exit. This experiment does not launch or replace the installed app.

Final validation passed **123 tests in 22 suites**, including the packet-window
bounds/keyframe tests, actual tiny-budget decoding, pressure/invalidation release,
and exact-seek frame comparisons on five fixtures. The missing long-VFR fixture
was generated separately using the repository's 120-second recipe. An initial
overly broad native-fixture run was interrupted before qualification and is not
counted. Architecture and Python checks passed.

The rebuilt test binary produced another **204 matching main-matrix images**.
Nonzero-origin and single-frame fixtures added 102 matching images. The initial
interlaced fixture was only two seconds long: 13 targets per mode were at/past its
end and unavailable in every mode (39 unavailable requests total). Those receipts
are retained; they are not packet-cache regressions or a passing edge cohort.
A 24-second top-field-first MPEG-2 fixture then produced **51/51 matching images**,
with no packet replay or speculative reads: the filtered-frame guard correctly
keeps the established seek/decode path. End-of-duration behavior of the short
interlaced fixture is a separate deferred investigation.

Final confirmation ran during heavier host activity and is used for correctness,
not a new timing claim. All executable/fixture identities and preserved-edit
checks are in `manifest.json`. No release-package or concurrent-playback
qualification is claimed; the experimental code remains disabled by default.

## 2026-10-06: remaining-fixes qualification

This pass addresses the six followups after the packet experiment. Receipts are
in `QualificationArtifacts/FixAllAudit/`. It supersedes the earlier short-clip
EOF, main-thread root-index and native-package deferrals. The compressed packet
experiment remains disabled. Measurements use the same M1/macOS host, synthetic
fixtures and isolated benchmark identities; the installed app is unchanged.

### Retained changes and measurements

Root/file indexes now build on a cancellable background task and publish only
the latest complete revision. The previous watch roots remain active while a
replacement builds; file actions wait for the new revision. Thumbnail candidates
and full-path membership sets are prepared with the background row projection,
removing another full-library walk from the main actor. Three packaged-app runs
with 100,000 files recorded worst sampled main-queue gaps of **107.6, 102.8 and
111.3 ms**, compared with the earlier 310–329 ms cohort. Query projections took
approximately 138–256 ms off the main actor. These are successive cohorts, not
controlled cold-start measurements. Restoring all rows after clearing the query
still produces a roughly 100 ms SwiftUI reconciliation hitch. A native table or
windowed row model is deferred: it needs separate selection, accessibility and
scroll-restoration validation, not just a faster timing result.

Preview target buckets now clamp below a known finite EOF and seek with up to a
second of preroll near the end. The two-second interlaced MPEG-2 fixture returns
a final image at duration minus 0.01 seconds, duration, duration plus 0.5 seconds
and duration plus 20 seconds. Each selected frame is within 0.15 seconds of the
end. This fixes the previously recorded missing images without relaxing decode
or cancellation deadlines. Additional per-decode/per-enqueue autorelease scopes
were also tested, but showed no established memory benefit and were removed
while investigating a possible small playback CPU regression.

Volume mount/unmount notifications now invalidate affected descendant roots and
reattach their filesystem streams. An offline root retains its volume observer
even when stream creation fails. The packaged integration test creates its own
APFS disk image, plays a copied file, force-detaches only that owned device,
closes/reopens the window, plays a healthy local file, then reattaches and verifies
listing, playback readback and preview drawing. `storage-final` passed:
**393 ms** from detach invocation to unavailable-state observation and **332 ms**
from attach invocation to directory-ready observation. These include OS command
and polling overhead. They do not qualify SMB/NAS timeouts or physical disk loss;
those remain deferred pending an appropriate storage target. Physical-worker
ownership and cancellation are separately covered by executor tests.

Renderer qualification now reads current-generation displayed pixel buffers and
public renderer performance counters. Readback is opt-in for benchmark snapshots
and does not add polling to production. Six paused 4K seeks reached a matching
current-generation displayed buffer in **187–253 ms** after command dispatch.
This is stronger evidence than enqueue completion, but it is not compositor
scanout or physical-input-to-photon latency.

The packaged four-codec interaction cohort uses six-second steady, repeated-hover
and repeated-resize phases. Controls remain visible, unlike the playback-only
reference comparison. Counters are checked for availability and progress;
missing metrics are never treated as zero.

| Fixture | Steady CPU / drops | Hover CPU / drops | Resize CPU / drops |
| --- | ---: | ---: | ---: |
| H.264 1080p30 | 5.30% / 0 | 11.95% / 0 | 8.01% / 0 |
| H.264 4K30 | 6.35% / 0 | 24.08% / 0 | 9.47% / 0 |
| HEVC 10-bit 1080p60 | 7.02% / 0 | 102.90% / 0 | 9.03% / 2 |
| VP9 1080p60 | 17.90% / 0 | 36.62% / 0 | 21.27% / 1 |

CPU is a percentage of one core; drops are renderer counter deltas. All corrupted
frame deltas were zero. The three resize drops remain a measured limitation,
not a zero-drop claim. HEVC cold-hover CPU warrants further scheduling/decoder
work, but no alternate decode route is promoted without image and playback
qualification. GPU/WindowServer cost is excluded. Hardware energy measurement
was unavailable because `powermetrics` required a password; CPU is not energy.

### Memory experiment disposition

The mixed-codec soaks still show variable closed footprints. Memory maps report
substantial dirty/swapped empty malloc regions alongside roughly 25 MiB of live
malloc allocations and 22 MiB resident IOSurfaces. This suggests allocator
retention contributes; it does not prove that every retained object is expected.

An idle-only `malloc_zone_pressure_relief` experiment was tested after physical
session cancellation, off the main actor, with cancellation on reopen. The first
A/B cohort missed the typed stop path and had **no cleanup events**, so it cannot
support an effect claim. Corrected wiring produced four observed cleanup events
(0.065–0.106 ms each), but the closed footprints were still approximately
104, 189, 214 and 226 MiB. Final idle was 224 MiB and critical preview trimming
left 223 MiB. The cleanup and its benchmark switches were **removed** because
there was no demonstrated benefit. The experimental source and receipts are
preserved under `dropped-idle-reclaim` and `allocator-v2-pilot`. Longer allocation
ownership tracing remains deferred; neither a leak fix nor a stable long-session
plateau is claimed.

### Native packaging repair

FFmpeg 8.1.2 was rebuilt from the existing pinned source with only the unused
CoreImage filters disabled, removing libavfilter's OpenGL dependency. Its separate
`8.1.2-illiquid1` prefix does not replace Homebrew's global opt link. The SDK,
lockfile, source manifests, recipe and build receipt now describe the new bytes.
Build scripts prefer that reviewed SDK when no explicit toolchain is supplied
and reject the incompatible OpenGL-linked variant before compiling. Both bundle
audits reject OpenGL and libmpv dependencies.

The 26-library non-system closure, seven public-header digests, decoder, encoder
and demuxer lists were preserved. Only `coreimage` and `coreimagesrc` filters were
removed; `bwdif` remains. **156 decoded frame hashes matched** the prior FFmpeg
across H.264 1080p/4K, HEVC 10-bit, VP9 and deinterlaced MPEG-2 fixtures. Source
verification passed for **28 inputs and 114 notices**, and SDK verification passed.
Packaged benchmark builds pass signature, architecture and loader-path audits
for all **27 Mach-O images**. Ad-hoc local qualification is not Developer ID
signing, notarization or a published release.

The final ad-hoc DMG also passed create/mount/copy/signature verification,
media-open and relaunch smoke tests. Its SHA-256 is
`529d1268bba86d8fa402ec488c51287fa7dc7b3431576c3642094f74813cf35a`.
It lives under `/tmp/illiquid-fixall-dmg-final/`; no installed application or
Homebrew opt link was replaced. Final-source packaging and generic audit logs
are `package-final-source.log`, `dmg-final.log` and `verify-final-app.log`.

Final source passed **434 tests in 76 suites** in the selected regression run,
with the new FFmpeg SDK and short-EOF/4K-index/packet-regression fixture overrides.
Architecture, packaging-helper and Python syntax checks also passed. The earlier
435-test run included the subsequently dropped allocator helper test; it is not
the final-source count. The fixture-gated full native integration matrix is not
claimed by this selected-suite result. Logs preserve an earlier stalled SwiftPM
planning attempt and the successful retry rather than counting interruption as
validation.

### Packaged player comparison before removing autorelease scopes

A fresh three-repeat rotated-order 4K cohort used the packaged candidate,
mpv and isolated IINA, with the same hidden-controls playback protocol described
above. IINA automatic thumbnails were disabled, hardware decode requested and
sound muted per player. This candidate has no idle allocator relief but still
has the subsequently removed autorelease scopes.

| Player | Playing CPU | Paused CPU | Closed CPU | Playing footprint |
| --- | ---: | ---: | ---: | ---: |
| Illiquid | 5.15% | 0.43% | 0.04% | 135 MiB |
| mpv | 9.50% | 0.38% | unavailable | 339 MiB |
| IINA | 8.05% | 0.48% | 0.03% | 397 MiB |

These are medians of process CPU as a percentage of one core and end-of-playing
footprint. The endpoints and exclusions remain unchanged: no GPU/WindowServer
accounting, no cross-player scanout ranking, and no mpv close measurement.
They describe this workload and host session, not a universal player ranking.
The different IINA result from the earlier cohort reinforces why measurements
from separate host conditions must not be treated as a controlled speedup.

Three subsequent previous-build Illiquid controls measured **4.86% playing,
0.35% paused and 0.04% closed CPU**. The candidate's extra 0.29 percentage points
of playing CPU do not establish a gain or nonregression. The scopes were removed
for a followup measurement; this is an investigation, not proof of causality.

The later 16-cycle packaged soak (`soak-final`, still with the autorelease scopes)
completed all cycles. Closed footprint ranged **94–256 MiB**, falling from about
250 MiB to 94 MiB late in the run; final reopened idle was **113 MiB**, or **110
MiB** after preview trimming. This variability is why one ending footprint is
not used as a memory-fix claim. Quit took 279 ms. A `leaks` snapshot reported
**14,400 bytes in 288 allocations**, rooted in three AppIntents/NSXPC cycles;
it also reported restricted process inspection. That limited result neither
explains the hundreds of MiB nor provides full leak clearance. No unsupported
framework teardown was added.

### Final source after dropping unproven memory changes

The four decoder/presenter/thumbnail autorelease edits were restored to their
pre-pass implementations; those files had no preexisting working-tree edits.
The idle allocator helper, its wiring and benchmark switches are also absent.
The retained fixes are background library indexing/projection preparation,
end-of-duration previews, volume reconnect handling, renderer qualification and
the reviewed native SDK/package repair.

This final source again passed **434 tests in 76 suites** (`no-pools-regressions.log`).
The final bundle is `/tmp/illiquid-fixall-no-pools/Illiquid.app`; all 27 native
images pass the packaging audit. Its DMG passed mount/copy/media-open/relaunch
verification (`no-pools-dmg.log`) and has SHA-256
`34f56729d192528677519b9a2154685c5cdb1b5ed0828e9e195a8b8e18401b73`.
It is an isolated ad-hoc benchmark package, not an installed or notarized release.

Three final playback-only controls measured **4.70% playing, 0.47% paused and
0.04% closed CPU**. Individual playing observations were 4.70%, 4.81% and 4.61%,
versus 4.86%, 4.84% and 4.95% for the earlier build. This removes the observed
CPU increase in the scoped-autorelease candidate; sequential host measurements
do not prove a universal speedup or identify causality conclusively. The mpv/IINA
values above belong to the preceding rotated cohort, not a newly interleaved
comparison with this final binary.

Final 4K displayed-frame seeks took **218–308 ms** in the six-request confirmation.
Steady/hover/resize phases again reported **zero dropped or corrupted frames**;
CPU with controls visible was 7.26%, 24.61% and 11.02%, respectively. Those CPU
figures cannot be compared directly to the hidden-controls playback-only median.
The earlier four-codec results, 16-cycle soak and reconnect tests retain their
own binary hashes and are not relabeled as final-source runs. The final-source
regression and 4K output checks cover the removal of the extra scopes.

Remaining deferrals are explicit: the roughly 100 ms full-library reconciliation
hitch, allocation ownership/long-duration memory qualification, real NAS failures,
physical scanout/energy measurements, and broader high-rate resize/drop tuning.
The allocator purge, extra autorelease scopes and compressed-packet prefetch are
not enabled. No new decoder policy was promoted on CPU evidence alone. At the end of qualification, changes
were uncommitted, and the two protected user-edited UI files retained their
initial hashes. `manifest.json` records the final source, test and app identities.


### Review before committing

Review found and fixed two tooling failures: FFmpeg preflight now rejects missing
filter libraries and failed/empty dependency inspection, and output/recovery
probes refuse an existing result directory before touching its evidence. Both
build entrypoints use the shared preflight. Packaging helper tests exercise a
valid path containing spaces plus five failure cases; six native-lock tests,
script syntax checks, real pinned-SDK inspection and output/storage receipt
preservation checks passed.

No Swift implementation changed during this review. All 299 app/test source files
still match the 434-test qualification snapshot. Those tests and app measurements
used the working tree with the two separately edited UI files; the performance
commit excludes those cosmetic edits. Qualification is local and ad hoc, not a
claim of a release built from a clean committed tree. The unresolved/deferred
items above remain unchanged.

## Full audit following 47007a2 (2026-10-06)

This pass reviewed preview/playback contention, 100k-source UI work, regression
qualification, memory ownership, high-rate transitions, and usability. It keeps
four application fixes and adds repeatable benchmark gating. **The performance
qualification is not green:** a completed cohort failed memory and dropped-frame
gates, and subsequent visible-window measurements were interrupted. The user
explicitly deferred the remaining visible-window benchmarks. No commit, install,
push, release, or change to another player was performed in this pass.

Evidence is under `QualificationArtifacts/FullAudit/` (ignored local artifacts).
`manifest.json` binds source, test, harness, fixture, application and receipt
identities. The starting revision was
`47007a2ae107f5d0fb592afbd8cbaeb8e32df095`. Existing edits to `PlaybackOSD.swift`
and `PlayerRootView.swift` were preserved byte-for-byte. Test/build snapshots
include those user edits; this is working-tree qualification, not a clean-commit
release claim.

### Retained fixes and disposition

| Area | Disposition and evidence |
| --- | --- |
| Playback versus preview decoding | Implemented synchronous admission fencing during prepare, buffering, stop and shutdown. Active/pending requests are interrupted without releasing the physical native-worker slot early; stale metadata/debounce work cannot revive after recovery. Cached images remain available. Four deterministic admission tests cover these boundaries. |
| Stationary hover after buffering | Implemented a retry when recovery ends for an incomplete preview of the current source. Exact cached previews and previous-source requests are not restarted. Policy regression coverage accompanies the change. |
| Clearing a large-library search | Implemented reuse of the existing visibility projection for empty/whitespace searches outside media grouping. Three-pair medians: 246.13 → 2.52 ms for 100k rows. This is projection timing, not complete visual response. |
| Full-library UI reconciliation | Deferred. Main-thread sampling points to SwiftUI `ForEachState.update(view:)`, identity lookup and large row-value copies. A computed lightweight collection did not materially improve the roughly 100 ms hitch. A precomputed reference-array experiment passed correctness tests but could not be performance-qualified; both experiments were removed. The latter is archived in `deferred-row-references.patch`. |
| Sidebar layout and settings accessibility | Fixed long-title/search-field sizing that clipped Add Files, Add Folder and visibility controls. Added labels and units to remembered-volume and sidebar-width sliders. Live AX and screenshot verification passed at 359/360-point sidebar widths. |
| Repeated regression qualification | Implemented `Scripts/profile-performance-suite.py`: serial alternating order, at least three repeats, exact input hashes, complete readback/renderer evidence, finite metrics and explicit gates. Missing evidence fails. Added scoped display-awake assertions and periodic visibility evidence after diagnosing Space-related failures. |
| Retained-memory ownership | Deferred: longer 48-cycle soak and entitled allocation trace were prepared but not run after the visibility failures and user deferral. Existing variable-footprint findings remain unresolved. No allocator-purge or autorelease change was reintroduced. |
| 60fps playback/resize | Audited with HEVC 10-bit and VP9; dropped-frame gates failed. No decoder-thread, queue, hardware or presentation-policy change was promoted. Stable visible-window confirmation remains deferred. |
| Fullscreen, keyboard and recovery usability | Search/Escape, AX Play, settings, close, aspect-preserving resize and fullscreen return were exercised. External-display switching, spoken VoiceOver, physical scanout and real NAS disconnect qualification remain deferred. |
| mpv/IINA comparison | Refreshed cohort deferred with the other visible-window work. Earlier comparison receipts in this document retain their original binary/workload scope; they do not establish a ranking for the final source here. Neither reference player was changed. |
| Compressed prefetch / speculative decode changes | Remain dropped/default-off as previously directed. Cold HEVC previews still warrant investigation, but coarse-keyframe-first previews need separate accuracy, latency and playback qualification before adoption. |

The admission change coordinates ownership and scheduling; it does not make a
cold codec decode intrinsically cheaper. In three alternating contention pairs,
12 HEVC seeks per app measured median **168.48 → 164.54 ms**, maximum
**187.60 → 189.33 ms**, from command to current-generation displayed-frame
readback. This does not establish a material latency improvement. The benefit
proved by the tests is cancellation/admission correctness.

### Completed comparison, including failed gates

`alternating-suite/summary.json` contains 24 completed runs: three repeats of
navigation plus H.264 4K30, HEVC 10-bit 1080p60 and VP9 1080p60 for each app,
rotating baseline/candidate order. Baseline binary SHA-256:
`9b4d26e26d9eda5b2945f04ba0a104fba55e4d1b4cbfbaa702e302c10cbc336d`.
Candidate binary SHA-256:
`55b1dcfa31cd08c1972f92e7f7009762841052fd46d998b8b1382f1854f9ff78`.
That candidate contains admission, cached projection and layout/accessibility
fixes, before the later stationary-hover retry. It has neither row-reference
experiment. Its results are not relabeled as final-binary measurements.

| Median observation | Baseline | Candidate |
| --- | ---: | ---: |
| 100k-source launch through window configuration | 1,472 ms | 1,012 ms |
| 100k-source clear-search projection | 246.13 ms | 2.52 ms |
| Maximum recorded main-queue gap per navigation run | 120.48 ms | 113.72 ms |
| Navigation quit through process exit | 188.93 ms | 173.31 ms |
| H.264 4K displayed seek | 260.73 ms | 232.18 ms |
| HEVC 60fps displayed seek | 157.44 ms | 156.35 ms |
| VP9 60fps displayed seek | 256.12 ms | 247.43 ms |
| H.264 steady / hover / resize CPU | 6.33 / 24.82 / 9.56% | 6.01 / 24.17 / 9.05% |
| HEVC steady / hover / resize CPU | 7.32 / 106.18 / 9.50% | 6.78 / 103.85 / 9.20% |
| VP9 steady / hover / resize CPU | 19.69 / 35.36 / 21.07% | 19.14 / 34.84 / 21.22% |

CPU is percent of one core and excludes GPU/WindowServer. Controls are visible;
this differs from the earlier hidden-controls mpv/IINA comparison. Launches use
fresh processes with warm OS caches. Seek readback is not physical scanout.
These observations are workload-bound, not a universal speedup or nonregression
claim. The final visibility-aware harness was added afterward; this older cohort
cannot retroactively prove uninterrupted on-screen presentation.

Failed gates must remain visible:

- H.264 hover footprint median **226.61 → 300.16 MiB** and resize footprint
  **222.27 → 298.47 MiB** exceeded the configured 15%/16 MiB allowance. Individual
  observations varied on both builds, but allocator retention is not established
  as the complete explanation.
- HEVC maximum steady dropped-frame delta **34 → 120** and resize **0 → 39**;
  VP9 steady **0 → 120**. These are failed renderer-counter gates, not dismissed
  as harmless telemetry. Every corrupted-frame delta was zero.
- A paused repeated-seek diagnostic (`drop-accounting/`) did not reproduce the
  hypothesized delayed dropped-frame accounting. That explanation remains
  unproven.

The subsequent `final-suite/` is an **incomplete 15-record experiment**, stopped
when the unchanged baseline lost displayed-frame readback. It also observed
baseline HEVC hover drops, so drops are not isolated to the new admission logic.
It is not a passing confirmation. `confirmed-suite/` then failed baseline window
visibility before obtaining any paired result. Its filename does not imply
confirmation.

### Visibility failure and remaining qualification

Cua/WindowServer evidence identified the diagnostic benchmark window as 960×600
on Space 3, while fullscreen Space 217 was active; it was explicitly offscreen
and not on the current Space (`window-space-evidence.json`). Thus the later
startup visibility failures were not caused by an undersized window. A scoped
`caffeinate` assertion alone did not fix them. This observation explains that
startup failure; it does not establish the cause of every earlier frame drop or
memory result. No user Space, fullscreen app or display preference was changed.

The harness now records own-window geometry and visibility during navigation,
readback and each half-second playback-workload step, and rejects a run that
leaves the visible desktop. These are sampled checks, not continuous occlusion
or compositor proof. Startup timeout errors include own-window details. The
suite also refuses old receipts lacking the new visibility evidence. Existing
failed receipts and pre-change harness sources remain archived unchanged.

On user instruction, the remaining controlled comparison, 48-cycle mixed-codec
soak, entitled allocation trace, and three-repeat mpv/IINA refresh are deferred.
Resume these on a quiet normal desktop with Illiquid continuously visible. The
allocation trace should use only the separately signed diagnostic bundle from
`prepare-memory-copy.py`; its stack-logging memory/CPU results are diagnostic,
not normal-performance measurements. The memory-copy preparation now points to the retained bundle; the older
batch scheduler is preserved as historical evidence and should not be rerun.
Use fresh output directories when resuming. No prepared-but-unexecuted probe
counts as validation.

Reproduce the retained-source comparison with a new, nonexistent output path:

```sh
python3 Scripts/profile-performance-suite.py \
  --baseline-app /tmp/illiquid-fixall-no-pools/Illiquid.app \
  --candidate-app /tmp/illiquid-full-audit-retained/Illiquid.app \
  --fixture /tmp/illiquid-performance-fixtures/h264-4k.mp4 \
  --fixture /tmp/illiquid-performance-joint-fixtures/hevc-10bit-1080p60.mkv \
  --fixture /tmp/illiquid-performance-joint-fixtures/vp9-1080p60.mkv \
  --output /tmp/illiquid-visible-confirmation --runs 3 --source-count 100000
```

### Usability evidence and validation scope

`gui-audit.json` and `gui-final/` preserve live verification. Search filtered the
real list and Escape cleared it; AX Play started the selected local file.
Fullscreen reached 1440×900 and returned to 960×540 with video visible. A
700×500 request settled at 699×393 under aspect locking, correctly hiding the
sidebar. Closing Settings left an offscreen backing window, so retained
WindowServer membership was not mistaken for failed close behavior.

The 300-point sidebar limit was not visually qualified: AX `set_value` failed.
Background Cmd-W with two eligible windows was refused by the automation driver;
the native Close menu was used instead. This does not prove a keyboard shortcut
bug. Slider AX labels/units passed; spoken VoiceOver and full contrast/focus
certification did not run. Fullscreen used the VFR fixture; 60fps resize has the
separate failed-gate scope above. The final hover-recovery edit has deterministic
coverage but no subsequent live-window timing claim.

The retained source is packaged at
`/tmp/illiquid-full-audit-retained/Illiquid.app`, binary SHA-256
`44b4927f82be799bb23cc32c43b7e335930f663f85bc6b1b902e71cfbda6e7c7`.
The ad-hoc build passed signature, architecture and dependency checks for all
27 Mach-O images (`build-retained.log`). Architecture validation passed
(`architecture-final.log`); all ten Python regression-gate tests and script
syntax checks passed (`harness-tests.log`). The focused final-source Swift run
passed 14 tests in three suites (`retained-tests.log`). Native dependency policy
and reviewed FFmpeg 8.1.2-illiquid1 remain unchanged.

The first final-source expanded regression run executed 504 tests and exposed
one existing PiP subtitle test race (`final-regressions.log`): after seeking to
75 seconds it slept exactly 600 ms and sampled an empty replacement subtitle
track. The test now waits up to its existing three-second bound for a newer seek
generation and nonempty subtitle output, while retaining the main/PiP counters,
packet-count equality, renderer-failure and backward-seek checks. No production
subtitle implementation or playback timeout was changed. The failed receipt is
preserved; its run is not counted as passing.

After repairing that synchronization, the retained-source regression selection
passed **504 tests in 81 suites in 55.623 seconds**
(`final-regressions-repaired.log`). It uses the reviewed FFmpeg SDK and the
explicit local thumbnail/index/packet/subtitle fixtures recorded in the manifest.
Some opt-in tests return early without their own qualification flags, so this
count does not claim the complete media-format matrix. The final report keeps
unit/fixture/build success separate from the failed or deferred performance
cohorts. All changes remain uncommitted.

### Active-window click-to-hide follow-up

A reported failure while Illiquid was already active exposed a focus-ordering
gap: native video mouse-down transfers first responder to the video, but
SwiftUI's control-focus loss can arrive after mouse-up. The click handler cleared
hover/legacy focus pins while retaining `playbackFocus`, which could reject the
explicit hide. Video clicks now retire the stale focus owners and that pin;
control activation, keyboard navigation and pointer exit preserve their existing
focus rules. Active scrubbing, popovers, accessibility interaction, loading and
always-visible settings remain protected. Two regression tests cover delayed
focus loss and preservation of those other owners. The targeted run passed
180 tests in 34 suites, including native click routing. This verifies the
identified state transition; the user's original intermittent live sequence has
not yet been reproduced on the replacement build.

The startup placeholder now says “Starting Illiquid…” because it covers history
loading and player/model initialization. A read-only probe found about 32 KB of
saved history and sub-millisecond raw plist/JSON parsing, but that is not Cocoa
preferences or end-to-end startup timing. Sampling began after startup completed,
so the original long-startup cause remains unconfirmed. The label change is not
a claimed startup speedup. Local evidence: `QualificationArtifacts/HistoryStartup/`
and `QualificationArtifacts/ClickHideFix/`. These follow-up changes are uncommitted.

### Sources scrolling report and subtitle reader spin

The user identified Sources-list scrolling as laggy. A read-only sample of the
running `2e6d3ad` build found a continuously executing subtitle demux worker,
repeatedly reading and throwing through the input executor. Its main thread and
audio/video workers were waiting during the sample. A separate 3.004-second
process CPU measurement recorded **97.05% of one core**. This identifies wasted
background work; it does not establish that this is the sole cause of scroll lag
or identify the exact native error code in that existing process.

`subtitleDemuxLoop` previously retried both invalid-data and interrupted errors
without a bound, including errors thrown after `readPacket` had exhausted its
own bounded retry policy. Malformed *decoded cues* remain skippable. Exhausted
*input reads* now report the existing subtitle failure once and exit. An
interrupted read continues only when a pending seek owns the next operation.
Intentional stop and subtitle-disable cancellation do not emit another failure.
The existing recovery path disables the failed subtitle track while preserving
audio/video playback; this is not a new input-repair or subtitle-reopen policy.

A fault-injected MediaSession regression reproduced **145,353 invalid-data
retries** and **146,920 interrupted-read retries** during respective 250 ms
observation windows with the old loop. Both cases make **one read and report one
failure** with the fix. This is a controlled retry-count result, not a measured
before/after CPU reduction in the user's running instance. Additional tests
verify that a cancelled read with a pending seek reaches the new generation,
20 cancel/seek cycles remain readable, and subtitle reconstruction and cancelled
reads remain usable on the media open in the user's app. The PiP/main subtitle
pipeline seek test ran against a generated 95-second H.264/AAC/SRT fixture.
The final reviewed regression run passed **273 tests in 41 suites**, including
seek/disable/stop cancellation and subtitle-only recovery. Architecture checks,
packaging, signing and dependency checks passed (27 Mach-O images). Opt-in cases without their own
fixture flags are not a claim of complete format-matrix coverage.

A temporary isolated-bundle scroll probe traversed 180 native clip-position
steps with 10,000 synthetic source rows. It did not record whole-sidebar body
reevaluation, so no change to scroll-state ownership was justified. Its sampler
did not capture useful active-scroll stacks; a second trial failed the visible
window gate after a Space change. These trials are insufficient to qualify
wheel/trackpad scrolling, adaptive text over playing video, compositor frame
pacing, or a scroll-latency improvement. The temporary probe is archived rather
than shipped. No Sources rendering, cache, or navigation behavior was changed.
Visible-window scroll verification remains outstanding; the earlier deferred
playback benchmark cohorts remain deferred too.

Evidence is retained under `QualificationArtifacts/SidebarScroll/`: live process
sample and CPU receipt, exploratory scroll trial, failing old-loop regression,
passing fixed-loop tests, packaging log, and source/binary manifest. The build
at `/tmp/illiquid-scroll-fix-reviewed/Illiquid.app` includes this fix and the click/startup
label follow-up above. It does not replace or restart the user's running app.
These follow-up changes remain uncommitted.

### Subtitle read failure during a pending seek

Review found that a superseded subtitle read returning `INVALIDDATA` could exit
the worker and report a track failure even after a new seek was pending. The
fault-injected review test reproduced one unexpected failure and no read in the
new generation. The error handler now checks for a pending seek for all read
errors, after synchronizing with seek publication. It lets that seek reposition
the input; errors without a pending seek still report once and terminate the
worker, preserving the bounded retry behavior.

The permanent seek/disable/stop regression now covers both `EXIT` and
`INVALIDDATA`. Review evidence and follow-up test logs are under
`QualificationArtifacts/SubtitleReadReview/`. This source fix is newer than the
previously packaged `/tmp/illiquid-scroll-fix-reviewed/Illiquid.app`.

Validation: the focused run passed 24 tests in three suites (two optional media
tests skipped), including all six seek/disable/stop error cases and the one-read,
one-failure assertions for persistent errors. Architecture checks passed. The
broader test selection did not complete: `externalSubtitleSeedHasNoStuckProgressStates`
terminated with signal 10, also reproduced when run alone. That state-space
test does not exercise `MediaSession`; its crash remains unresolved, and this
follow-up does not claim a fully passing broader suite. Logs retain both failed
runs and the passing focused run. No new app bundle was packaged or installed.

Subsequent requested rebuild: `/tmp/illiquid-seek-race-fix/Illiquid.app` includes
the pending-seek fix. Release compilation, dependency audit and ad-hoc signature
verification passed (arm64, 27 Mach-O images). All 334 recorded build inputs
remained unchanged through packaging. The binary hash and source manifest are
recorded in `QualificationArtifacts/SubtitleReadReview/build-fix-receipt.json`
and `build-fix-inputs.json`. The app was not launched or installed over the
running copy; this packaging result does not resolve the state-space test crash.


### Donor checkout reconciliation

The missing video tabs, sidebar folder tabs, progressive folder scanning,
contrast fixes and Illiquid naming/migration work from the development checkout
are now reconciled with the performance and subtitle/click fixes above.
[Checkout reconciliation](CHECKOUT_RECONCILIATION.md) records exact inputs,
imported/retained/deferred decisions, the combined test result (901 tests in
135 suites; state-space excluded), and `/tmp/illiquid-reconciled/Illiquid.app`.
No new whole-player performance gain is claimed by this integration; the
existing visible-window qualification limits still apply.


## Optimization follow-up after checkout reconciliation (2026-10-07)

The user's request to fix and test remaining issues retains their earlier
visible-window benchmark deferral. Evidence for this pass is under
`QualificationArtifacts/OptimizationFollowup/`; the reconciliation build remains
an unchanged baseline at `/tmp/illiquid-reconciled/Illiquid.app`.

Implemented changes:

- Split the playback core's effect-result switch into scoped handlers without
  changing the 14 extracted transition bodies. The excluded external-subtitle
  state-space test reproduced a SIGBUS stack overflow on the merged baseline.
  Its debug `apply` frame reserved 277,728 bytes; the new dispatcher reserves
  17,520 bytes (arm64 object-code measurements, excluding callees/prologue).
  The CLI explorer now completes 7,180 states and 57,236 edges for that seed.
- Keep open-video resume data outside the observed title-bar membership and
  selection. Position/pause/playlist checkpoints stay current without requiring
  a visible tab-list update. Added observation and close/restore coverage.
- Move saved source-tab decoding, normalization and legacy-source restoration
  into the existing read-only background startup operation. The UI receives one
  complete snapshot, and shutdown still prevents late model publication. Valid
  modern tabs avoid decoding unused legacy folder data. This removes a known
  main-thread startup workload; it does not establish the cause of the user's
  original intermittent startup delay.

The large-library SwiftUI reconciliation hitch, actual trackpad/wheel scrolling,
60fps resize/drop counters, whole-app retained memory, and refreshed mpv/IINA
comparison still require the deferred visible-window cohort. Existing failed
memory/drop gates are not reclassified as passing by unit or headless fixture
tests. The extra observation cadence and compressed-packet prefetch remain off;
no decoder/thread/cache-size policy is changed without playback nonregression
measurements. Final test results and the replacement bundle are recorded below.

The first complete run reached 930 tests in 138 suites: the formerly crashing
state-space tests completed, and one real-media subtitle cancellation regression
failed with `AVERROR_EXIT`. The generated 95-second Matroska fixture exposes a
stored AVIO interruption that `avformat_flush` and buffered seeks do not clear.
New seeks now clear only the previous `AVERROR_EXIT` and its EOF flag before
repositioning; ordinary reads, other I/O failures, and cancellation of the new
operation retain their existing behavior. A focused test verifies that genuine
I/O, invalid-data and EOF errors are not cleared.

Packaging also found that Homebrew's active HarfBuzz, GLib and PCRE2 links had
moved to newer kegs. The reviewed originals remain installed. Automatic SDK
selection now resolves transitive libraries from the SDK's pinned keg paths,
with the unchanged native-input hash lock as the final check. No Homebrew links
or dependency versions were changed. The final headless test/probe run explicitly
loads the same pinned libraries and records loaded paths; the initial full run
used the host's newer transitive libraries and is retained separately.

A first test-only attempt to pin every library directory via `DYLD_LIBRARY_PATH`
shadowed Apple's private ImageIO PNG library and crashed screenshot encoding.
The corrected runner overrides only HarfBuzz, GLib and PCRE2; the screenshot
suite passes and the loader receipt verifies all 26 locked native inputs plus
Apple's own PNG implementation. Packaging never exports that loader override.
The failed harness run is retained as `all-tests-broad-override-failed.log`.

Other Rust compilation and Firefox workloads were active during qualification
(load average approximately 16, 3.7 GiB swap in use at one sample). Timing data
from this pass is diagnostic under that host load; it cannot establish an
idle-host performance improvement or replace deferred playback nonregression
measurements. No unrelated processes were stopped.

The first complete run with the corrected pinned-library environment completed
931 tests in 138 suites with five issues in four preview integration tests.
The short interlaced receipt explicitly recorded `decode-budget-exhausted`
(2,790.5 ms decode against a 2.5-second limit); source restoration and core
exploration also took substantially longer during the competing host workloads.
The four affected tests subsequently passed unchanged on both the reconciled
baseline (4.497 seconds) and the current binary (2.725 seconds), sequentially on
the same host and pinned dependencies. These small, changing-load timings are
not a speedup claim. No deadline was extended and no failing test was disabled.
The contended run is preserved as `all-tests-pinned-contended.log`; focused
baseline/current logs retain the recovery evidence.

Final complete test run: **931 tests in 138 suites passed in 210.128 seconds**,
with state-space tests included, required native fixture inventory enabled,
bitmap fixtures, long-caption cancellation/seeking, idle generation, indexed
preview and interlaced-end regressions active. The conversion-only opt-in timing
test remained explicitly skipped; other environment-gated experiments without
flags remain unqualified. This is debug-test evidence, separate from Release
packaging and the deferred visible playback cohort. Architecture validation,
10 performance-harness tests, six dependency-lock tests and packaging helper
checks passed. No test timeout or production decode deadline was relaxed.

Observation instrumentation measured **1,000 -> 0 tab-strip invalidations** for
1,000 playback checkpoints while preserving resume data. The final 100,000-file
source restoration sample took 753 ms on its background worker; an earlier
less-contended sample took 600 ms. These demonstrate work placement, not an
end-to-end startup speedup.

Three current-policy preview runs per fixture measured the following caller
medians, with warm OS pages and no concurrent playback. The initial aborted
probe's samples are retained in these totals rather than discarded.

| Fixture | First request | Warm decode request | RAM hit | Missing images / requests |
| --- | ---: | ---: | ---: | ---: |
| H.264 1080p | 290 ms | 17.4 ms | 0.040 ms | 0 / 21 |
| H.264 4K | 336 ms | 87.6 ms | 0.047 ms | 1 / 21 |
| HEVC 10-bit 1080p60 | 473 ms | 66.6 ms | 0.051 ms | 0 / 21 |
| VP9 1080p60 | 307 ms | 38.7 ms | 0.043 ms | 0 / 21 |

All available images matched their corresponding available repeated-request
hashes. One first 4K call returned nil at 3,085.6 ms; its worker completed around
3,091 ms, after the existing request deadline. A later request for that same
timestamp succeeded. The corresponding opt-in measurement exits with a failure
and remains preserved; **83/84 available images is not an all-green preview
qualification**. Deadline tuning and any settled-hover retry remain deferred
until playback contention can be measured. Packet prefetch remains disabled.

All four separate cache-tier probes passed, including background generation and
foreground promotion. Across those fixtures, each 20-hit RAM sample had a median
of 0.030-0.033 ms. New-generator exact disk reads, with decoding prohibited, took
2.21-4.34 ms (one sample per fixture; same process and warm filesystem cache).
These results support retaining the existing cache tiers; they do not justify
larger caches or additional decoder threads.

Final runnable build: `/tmp/illiquid-optimization-fixes/Illiquid.app`. Release
compilation, arm64 dependency audit and ad-hoc signing passed for 27 Mach-O
images. All 26 signed native libraries are byte-identical to the reconciled
baseline, and all 365 recorded code/build inputs remained unchanged through
packaging. The original reconciled executable remains unchanged. The final
executable SHA-256 is `1fdeb1306fcf5739ba065daf81b3c0244cdac326420c974c43239060e7410d74`.
`final-receipt.json` binds the app, source manifest, tests and qualification limits.
The changes remain uncommitted; the app was not launched or installed.

Run a separate instance with:

```sh
open -n /tmp/illiquid-optimization-fixes/Illiquid.app
```


## Cold 4K preview deadline investigation (2026-10-07)

This investigation uses the exact prior debug test binary
`416f8beff68198dfa1d5b5b37d3ff279acb4fe477bb044c498774af4a71fc0fc`, copied to
`/tmp/illiquid-preview-timing-runner/IlliquidPackageTests` to preserve its identity.
The working checkout has newer edits in 16 previously recorded files; this pass
neither changes them nor claims to qualify them. Evidence and the reproducible
probe driver are under `QualificationArtifacts/PreviewTimingInvestigation/`.
The same pinned native-library environment and hashed H.264 4K fixture were used.

The original failed caller returned nil after 3,085.6 ms. Its native worker
finished at 3,091.2 ms with `imageCreated=true`, `cancelled=true`, and the correct
selected timestamp of 1.5 seconds. The stages were:

| Original worker stage | Elapsed time |
| --- | ---: |
| Opening/probing and decoder setup | 448.9 ms |
| Seek | 0.4 ms |
| Reading/decoding | 1,146.7 ms |
| Image creation/scaling, including lazy renderer initialization | 1,490.4 ms |

Packet reads account for 62.5 ms within reading/decoding, not an additional stage.
The byte counter starts after opening, so it does not measure probing I/O.
The caller recorded 733.2 ms total process CPU during its 3,085.6 ms wait. This
is consistent with substantial waiting/descheduling/GPU work, but does not
identify a specific OS stall. No native stack was captured for that original
failure. The result was discarded because cancellation won while the final image
operation was still returning; the decoder had already reached the target.

Twelve fresh-process runs alternated the existing utility policy and the opt-in
foreground-priority experiment (six each, two decoder threads, no packet cache).
All runs processed the same measured 11,902,883 bytes and 119 packets for the
first request. Every available image matched its corresponding repeated-request
hash. Utility produced 41/42 images, foreground 42/42. Another utility miss
returned at 3,222 ms: opening took 1,831 ms, decoding 1,139 ms, and image work
433 ms. The slow stage is therefore not consistently image conversion alone.

| Six-run cohort | First-request median | First-request process CPU median | Missing images |
| --- | ---: | ---: | ---: |
| Current utility priority | 477 ms | 600 ms | 1 / 42 |
| Experimental foreground priority | 407 ms | 594 ms | 0 / 42 |

These results include the outlier. Host load varied, and the cohort excludes
concurrent playback. A 70 ms median difference in this small experiment does
not overturn the previous decision to retain production priority. First-image
stage medians were 62.5/49.9 ms; warm image medians were 4.5/4.3 ms.

A separate optimized Swift component probe uses a decoded 3840x2160 BGRA frame
from the same fixture, with the existing Core Image options and 368x207 output.
Across five fresh processes, context initialization took a median 30.1 ms
(range 29.4-39.1), first rendering 6.9 ms (6.8-7.2), and warm rendering 2.4 ms
(2.4-2.6). This isolates the component rather than claiming native-pipeline or
color qualification. It supports cold setup as an ordinary tens-of-milliseconds
cost, with additional resource delays needed to explain the original 1.49-second
image stage. An attempted stack sample timed out; its separate trial is excluded
from the latency cohort.

Disposition: retain the current deadline, two-thread limit, and utility priority.
An idle context prewarm could hide about 37 ms of normal isolated setup/render
cost, but has not been shown to remove multi-second stalls and could increase
startup/idle work. It remains an experiment pending concurrent-playback and
resource measurements. A targeted trace of a failing cold request is needed to
distinguish initialization, GPU waiting, paging, and scheduling precisely.
Visible-window qualification stays deferred. No production code or policy was
changed, and no rebuild or commit was made by this investigation.

A post-measurement verbose loader audit reached its 45-second limit before
test execution; seven observed native inputs matched the prior run. All 26
original pinned input files still hash identically. The incomplete loader audit
is retained separately and is not counted as a passing test or full live-loader
verification.


## Native stack capture of a cold preview stall (2026-10-07)

Follow-up evidence is in `QualificationArtifacts/PreviewStallTrace/`.
The exact earlier debug binary and H.264 4K fixture were SHA-256 verified against
`PreviewTimingInvestigation/protocol.json`. Logs and sampling output were written
to the internal drive before archiving. No application source or policy changed;
these runs do not qualify the newer checkout edits.

One of three sampled fresh-process runs missed the deadline. Its caller returned
nil at 3,189 ms with 480 ms process CPU. Worker stages were opening 60 ms,
decoding 269 ms, and image creation 3,774 ms; the worker finished at 4,105 ms.
It selected the correct 1.5-second frame, read the usual 119 packets / 11,902,883
measured bytes, and discarded the late image after cancellation.

`sample-0.txt` captured 883 samples on the preview worker with this stack:

```text
NativeTimelineThumbnailGenerator.ImageRenderer.init
CIContext.initWithOptions
CI::MetalContext::init
CI::new_precompiled_kernels
MTLLibraryBuilder::newLibraryWithFile
fopen -> open$NOCANCEL -> __open_nocancel
```

This localizes the sampled stall to a file-open operation during lazy Core Image
Metal kernel-library initialization. The decoder threads were waiting during
that interval. It does not identify the precise file, explain the kernel-level
reason for the blocked open, or prove that every earlier outlier had this cause.
In particular, the earlier decoder-opening stall remains unexplained. Sampling
can perturb timing. The other two sample reports had no useful call graph and
are not counted as additional stack evidence.

Eight separate unsampled control processes returned 56/56 previews. Their first
request median was 513 ms, with a range of 295-1,820 ms. The sampled cohort
returned 20/21 previews. Every available image in both cohorts matched its prior
reference hash. After the sampled timeout, the next request returned in 1,182 ms;
a later request for the original target returned in 190 ms. The existing worker
therefore recovered without a process restart; active native work remained
serialized until it returned.

Four runs of the existing proposed stable-hover retry qualification returned
16/16 previews, all on the first attempt. They validate the exercised first-attempt
path only: no actual retry occurred, so this does not qualify timeout recovery
or justify enabling the retry policy.

Disposition: lazy renderer initialization is now a directly observed stall
location. The next targeted experiment is preparing the existing shared renderer
after startup, when preview work is expected and playback load permits it.
Prewarming moves work earlier; it does not remove its I/O or resource cost and
must not block app startup or delay a foreground request behind speculative work.
Measure readiness, first-hover latency, CPU/memory, and playback interference
before adoption. A bounded retry for an unchanged hover remains a separate
resilience candidate. Preserve the three-second deadline, utility priority, and
two decoder threads. No downscaling, media prefetch, or decoder-thread change is
supported by this captured stall. Concurrent-playback and visible-window
qualification remain deferred.


## Shared preview renderer prewarming experiment (2026-10-07)

Disposition: retain the opt-in qualification hook; defer automatic app adoption.
`NativeTimelineThumbnailGenerator.prepareImageRendererForQualification()` prepares
its existing shared CIContext on a utility queue. Only the measurement test calls
it, with `ILLIQUID_PREVIEW_PREWARM=1`. No app startup, playback, background scheduler,
or user setting enables it. The hook does not decode media or render a dummy image.

The current checkout built successfully in debug mode. Baseline and candidate
used the same copied test binary, with fresh processes and alternating order.
Preparation completed before the first request: this measures the opportunity
when idle lead time exists, not actual app startup or a hover racing preparation.
Both modes retained the existing deadline, two decode threads, utility priority,
BGRA output, and disabled packet-prefetch experiment. The fixture pages were warm.

| Fixture | Runs per mode | First request baseline median | Prepared median | Median paired saving |
| --- | ---: | ---: | ---: | ---: |
| H.264 4K | 10 | 256 ms | 218 ms | 38 ms |
| H.264 1080p | 3 | 102 ms | 64 ms | 38 ms |
| HEVC 10-bit 1080p60 | 3 | 248 ms | 212 ms | 37 ms |
| VP9 1080p60 | 3 | 214 ms | 151 ms | 37 ms |

VP9's difference between cohort medians is larger than its median paired saving;
retain the paired result and small-sample limitation rather than claiming 63 ms
of consistent improvement. All 38 runs returned all seven images (266/266), with
matching image hashes between baseline and prepared modes. No multi-second miss
occurred in either mode, so prevention of the previously traced stall is unproven.

For 4K, the first image-stage median fell from 33.7 to 7.5 ms. Preparation took
34.6 ms wall time and 11.5 ms process CPU, adding a median 2.0 MiB physical footprint
and 6.3 MiB resident memory before any preview. This is work moved earlier rather
than removed: seven-request batch CPU including preparation was 941.8 ms baseline
versus 939.4 ms prepared, effectively unchanged in this cohort. After requests and
idle decoder release, incremental physical footprint was approximately 124.4 MiB
in both modes. These are process snapshots, not a long-soak or memory-budget pass.

Five existing worker admission/priority tests passed, covering cancellation,
retained native ownership, stale admission, cached images during recovery, and
pending foreground priority. The full application suite was not rerun for this
unused experimental hook. New metrics in the opt-in measurement test account for
preparation separately and capture memory before/after preparation and requests.

Evidence: `QualificationArtifacts/PreviewPrewarmExperiment/` contains the analysis,
protocol, final receipt, and `receipts.tar.gz` with the exact source changes, driver,
per-run receipts, build log, and regression log. The recorded binary SHA-256 binds
these measurements to the copied candidate, not earlier benchmark binaries.

Before adoption, measure concurrent playback and actual startup/first-hover
behavior. If hover arrives while lazy initialization is still running, Swift's
shared initialization can still make it wait; prewarming is not a cancellation
mechanism. Preparation also consumes resources even if the user never hovers.
Visible-window qualification stays deferred. Keep the experimental hook off all
production call paths until these tradeoffs are qualified.


## Hover cache reuse and pointer settling (2026-10-07)

Implemented: when an already displayed thumbnail is within 3.5 seconds of the
hover position, reuse it during movement without another nearest-cache lookup.
A broader existing storyboard fallback remains visible when available; precise
refinement still targets the existing half-second bucket. Actual click-to-seek
coordinates and playback decoding are unchanged.

Settling now follows pointer-position changes, including motion within the same
half-second bucket. Native refinement waits until 180 ms after the last movement.
The old additional decoder debounce is removed from this call path, so settling
does not stack two delays. An already exact cached image returns immediately.
Pointer exit and replacement requests keep task cancellation, and both cache and
decode publication explicitly check the current source revision. Cached images
keep their represented timestamp and existing approximate marker.

169 tests in 32 suites passed, including deterministic within-bucket movement,
cancellation before refinement, already-settled admission, nearby-distance bounds,
retry/recovery, playback admission, and control-bar interaction/geometry coverage.
This validates scheduling and correctness, not measured desktop frame pacing or
an end-to-end hover latency improvement. A completely uncached position can still
show a spinner. Renderer prewarming remains benchmark-only. Visible-window
performance qualification stays deferred.


### Hover refinement review fixes (2026-10-07)

Review found that pointer settling and current-request/source admission were
checked only before entering the retry helper. Movement within a bucket after
the first failed attempt could therefore allow an unsettled retry; a delayed
source-change observer could also leave a stale task issuing another request.
Publication already had an outer source guard, so this finding concerns stale
work admission rather than proof of an incorrectly displayed cross-source frame.

Every decode attempt now checks ownership, waits for settling, checks ownership
again after that suspension, and rejects stale results after decoding. Existing
task cancellation and the two-attempt bound remain. Three deterministic regression
tests cover ownership lost during settling, source change during decoding, and
renewed pointer movement between attempts. 172 tests in 32 suites passed. Desktop
latency/playback qualification remains deferred; no performance gain is claimed
from these correctness tests.
