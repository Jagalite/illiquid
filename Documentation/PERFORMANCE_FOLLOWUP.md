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
