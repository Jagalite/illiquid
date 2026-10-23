# macOS agent UI automation runbook

Status: initial implementation, integrated 2026-10-23. Read the [plan](MACOS_AGENT_UI_AUTOMATION_PLAN.md), [implementation contract](../Scripts/agent-ui/IMPLEMENTATION_CONTRACT.md), and [coverage inventory](../Tests/AgentUI/coverage.json) together. A structurally valid scenario is not a passing native UI test.

Retained integration validation on the development Mac (2026-10-23) follows. Each receipt applies to its recorded source/helper version; aggregate validation of the latest activation and window-probe edits remains pending:

| Check | Result and evidence boundary |
| --- | --- |
| Optimized product build | Passed; `/tmp/illiquid-agent-ui-build.log`. Existing Metal Sendable warnings remain. |
| Packaging and helper preparation | Kyoto job `f675d92fcc8a46eebaf4b8f373d3b0fd` succeeded; benchmark bundle audit passed for 32 arm64 Mach-O images with valid signatures. |
| Component suite | 117 tests passed through Kyoto job `b868f79e3f5249c4b5aced4c1cdb805b` before the latest activation run-loop changes. Current-source aggregate validation is pending; these receipts do not qualify subsequent helper edits. |
| App protocol | Four tests passed in an isolated harness with stubbed playback dependencies; this is not a full app test-suite result. |
| Preflight | Accessibility, post-event and Screen Recording access detected; Instruments templates discovered. |
| Inspection scenario | Passed all three steps, including an owned-window screenshot; receipt directory `/tmp/illiquid-agent-ui-live-20261023-inspection-4`. |
| Playback shortcuts | Passed all 19 steps with generated video, real Space/Left/Right input, and app-state assertions; receipt directory `/tmp/illiquid-agent-ui-live-20261023-playback-6`. This proves those input/state transitions, not visible-frame latency. |
| Time Profiler | Failed: readiness notification did not arrive before the deadline. Recorder received SIGINT and was reaped; `cleanup_confirmed: true`, `measurement_valid: false`. Failure retained under the playback run's `trace/7aabdf4d197649bb938adccf922e297d`. No performance pass or metric export is claimed. |
| Post-trace screenshot | Refused because no owned window was on-screen at capture time; this is not a renderer result. |
| Cleanup | The inspection and playback apps terminated gracefully. Playback close preserves the earlier profiler failure in its result even though app termination and recorder cleanup completed. |
| Preference isolation | Existing benchmark preferences were inherited. Per-run preference isolation remains pending; see the launch and comparison notes below. |

These temporary development receipts are not portable CI artifacts. The run manifests explicitly report incomplete checkout provenance when Git diff capture times out or untracked source is omitted; no frozen baseline/candidate performance qualification is claimed. The coverage inventory describes wider app interactions that still need implementation or live qualification.


## Prerequisites

Use a dedicated logged-in, unlocked macOS GUI session with an active display. The app currently targets macOS 26 and packages arm64 by default; check `Resources/Info.plist`, `Package.swift`, and the intended hardware before building. A remote shell alone does not establish an interactive WindowServer session. Keep other input clients and physical input idle during a run.

Install Python 3.9 or newer, Swift, full Xcode with its macOS SDK and Metal tools, and the repository's reviewed native dependencies. Follow [BuildInputs/README.md](../BuildInputs/README.md) and retain `BuildInputs/native-sdk.json` and `Scripts/native-dependencies.lock.json`. Packaging requires `swift`, `xcrun`, `otool`, `lipo`, `install_name_tool`, `pkg-config`, `sips`, `iconutil`, `ditto`, `codesign`, Python, FFmpeg/libavfilter, and libass. Fixture video generation additionally needs an FFmpeg build with `libx264` and AAC support. The runner uses Python's standard library and compiles its Swift helper into a source/toolchain-keyed cache; it does not build the product.

Check the selected developer directory and versions, saving their output alongside the build receipt:

```sh
xcode-select -p
xcodebuild -version
swift --version
python3 --version
```

Accessibility permission permits AX inspection and semantic actions. Real keyboard/pointer input also requires post-event access. Owned-window screenshots require Screen Recording permission. Profiling may require Developer Tools authorization and an installed Instruments template. Apple Events Automation permission is adapter-specific; the PID-targeted native adapter is not an app-name AppleScript workflow. Input Monitoring is not a substitute for Accessibility/post-event authorization. Inspect the actual preflight result and authorize the responsible host/helper in System Settings → Privacy & Security; rerun preflight after any required restart. Never disable SIP, reset production preferences, or treat denied permissions as a skipped pass.

## Build a separate optimized benchmark bundle

For this workspace, submit future builds through the shared Kyoto queue, including Swift and Metal compilation. Kyoto accepts non-Rust commands unchanged. Submit from the repository root, preserve the build's environment and flags, and inspect `show JOB_ID`, `logs JOB_ID`, and `wait JOB_ID` before claiming success. A queued job is not a completed build. Do not change shared queue policy.

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  Scripts/build-app.sh --configuration release \
  --bundle-id com.example.IlliquidBenchmark --output /tmp/illiquid-agent-ui-UNIQUE
```

Replace the output with a new directory. For the isolated-scratch recipe below, submit its build invocation through Kyoto with the same explicit environment, for example `kyoto.py submit -- env ILLIQUID_BUNDLE_ID=... ILLIQUID_BUILD_ROOT=... Scripts/build-illiquid-app.sh ...`. The expanded recipe shows the build inputs and evidence to retain.

The following is an operator recipe, **not a record of commands already run**. Run from the intended checkout with no concurrent product build. Use a fresh output path: packaging replaces `Illiquid.app` in its output directory. Never rebuild over the executable of a running or retained baseline target.

```sh
set -eu
repository_root=$(git rev-parse --show-toplevel)
cd "$repository_root"
qualification_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
build_receipt="$repository_root/QualificationArtifacts/AgentUI-builds/$qualification_id"
mkdir -p "$build_receipt"
git rev-parse HEAD > "$build_receipt/source-revision.txt"
git status --porcelain=v1 > "$build_receipt/source-status.txt"
git diff --binary HEAD > "$build_receipt/source.patch"
git ls-files --others --exclude-standard > "$build_receipt/untracked-files.txt"
cp Package.swift Package.resolved "$build_receipt/"
cp BuildInputs/native-sdk.json Scripts/native-dependencies.lock.json "$build_receipt/"
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- env \
  ILLIQUID_BUNDLE_ID=com.example.IlliquidBenchmark \
  ILLIQUID_BUILD_ROOT="$build_receipt/build" \
  Scripts/build-illiquid-app.sh --adhoc --output "$build_receipt/bundle" \
  > "$build_receipt/kyoto-submit.json"
build_job_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
  "$build_receipt/kyoto-submit.json")
python3 /Volumes/seed1/Projects/kyoto/kyoto.py show "$build_job_id" \
  > "$build_receipt/kyoto-show.json"
# Preserve logs even if wait reports a build failure.
build_status=0
python3 /Volumes/seed1/Projects/kyoto/kyoto.py wait "$build_job_id" \
  > "$build_receipt/kyoto-wait.json" || build_status=$?
python3 /Volumes/seed1/Projects/kyoto/kyoto.py logs "$build_job_id" \
  > "$build_receipt/build.log"
test "$build_status" -eq 0
# Continue only after the completed build and a successful packaging audit.
app_bundle="$build_receipt/bundle/Illiquid.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist"
shasum -a 256 "$app_bundle/Contents/MacOS/Illiquid" > "$build_receipt/executable.sha256"
```

These are actual flags from [build-illiquid-app.sh](../Scripts/build-illiquid-app.sh): `--output DIR`, `--adhoc`, `--unsigned`, and `--developer-id`. Release is built automatically in an isolated SwiftPM scratch directory using `--configuration release --force-resolved-versions`; there is no `--benchmark` or `--release` packaging flag. `ILLIQUID_BUNDLE_ID` supplies the required benchmark identity. `ILLIQUID_BUILD_ROOT` retains build intermediates/symbols for diagnosis. Record any explicit architecture, SDK, version, build-number, or signing overrides. Ad hoc signing is appropriate for this local recipe; an unsigned bundle audit alone does not establish Apple Silicon launchability.

The standard local packager also supports a benchmark bundle, using its own actual flags: `Scripts/build-app.sh --configuration release --bundle-id com.example.IlliquidBenchmark --output "$build_receipt/local-bundle"`. It builds by default and signs ad hoc; do not add `--skip-build` when qualifying new source. This route uses the checkout's shared `.build` directory, so serialize it with other SwiftPM work. The recipe above provides a separate scratch build as well as a separate app bundle.

Archive and hash relevant untracked source as well: `git diff HEAD` and the runner's `artifacts/source.patch` omit untracked files. This matters while the runner/scenarios themselves are untracked. Retain the packaged `NativeDependencyProvenance.json`, build log, exact script/environment settings, available matching symbols, and source hashes. Binary identity and source revision are different evidence; do not infer clean-source provenance from the plist's commit alone.

## Exact runner commands

Before the first run, or after Swift helper/toolchain changes, prepare both helper caches through Kyoto and verify that job succeeds. This step compiles helpers without launching an app or posting input; subsequent runtime operations use the cache. The runner otherwise compiles missing helpers automatically.

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Scripts/agent-ui/prepare.py
```

The plan calls this a proposed interface; these examples follow the current [runner parser](../Scripts/agent-ui/agent_ui.py). Run `python3 Scripts/agent-ui/agent_ui.py --help` after integration to check for drift. Each invocation prints one versioned JSON envelope to stdout; inspect `status`, nested availability/permission results, and the exit code. Diagnostic output belongs on stderr. `ok` means the named operation succeeded at its stated endpoint.

```sh
python3 Scripts/agent-ui/agent_ui.py doctor
run_dir="$repository_root/QualificationArtifacts/AgentUI/$qualification_id-inspection"
python3 Scripts/agent-ui/agent_ui.py launch \
  --app "$app_bundle" --run-dir "$run_dir" --timeout 30
python3 Scripts/agent-ui/agent_ui.py inspect --run-dir "$run_dir"
python3 Scripts/agent-ui/agent_ui.py hook --run-dir "$run_dir" --action capabilities
python3 Scripts/agent-ui/agent_ui.py hook --run-dir "$run_dir" --action agent-state
python3 Scripts/agent-ui/agent_ui.py run --run-dir "$run_dir" \
  --scenario Tests/AgentUI/Scenarios/inspection.json
python3 Scripts/agent-ui/agent_ui.py close --run-dir "$run_dir" --timeout 15
```

Use a **new, absent run directory for each scenario**. A run retains one scenario and refuses to replace its receipt; capture also refuses to overwrite an existing artifact. `launch` selects the exact benchmark bundle executable and retains PID, executable hash, start identity, owned status, session/control-file paths and readiness. It creates run-owned home/temp/session/cache state and opts into the guarded benchmark channel. Its recorded planar software-output selection matches the intended production path; it is an explicit override, not proof that every backend matches production. Live validation found existing benchmark preferences were inherited: `CFFIXED_USER_HOME` does not provide per-run preference isolation here. Preferences use the shared benchmark bundle domain. Do not assume fresh defaults or concurrently run settings-mutating scenarios; record the effective preference context for comparisons. Full per-run preference isolation remains pending. Launch activates the exact owned process as semantic setup, then waits for an on-screen owned window. The activation helper pumps its run loop until frontmost ownership is observed, then checks AX focus; this is semantic setup rather than an input-routing assertion. The windows-only probe does not require AX discovery and returns `elements: []`, `truncated: true`, and `inspection_scope: "windows-only"`. Neither endpoint proves layout/presentation readiness.

If focus is lost after launch, request it explicitly and record it as semantic setup:

```sh
python3 Scripts/agent-ui/agent_ui.py act --run-dir "$run_dir" \
  --request '{"action":"focus","mode":"accessibility"}'
```

Attaching requires an exact known PID and executable, not an application name:

```sh
python3 Scripts/agent-ui/agent_ui.py attach \
  --pid "$target_pid" --executable "$target_executable" --run-dir "$attach_dir"
```

Attach authorizes interaction but does not acquire process ownership or install a benchmark channel in a normal app. `close` detaches an unowned target; `--terminate-unowned` is an explicit additional choice. Owned close requests normal termination, preserves evidence and stops the run's recorder. `--force` explicitly permits bounded SIGTERM after graceful quit times out; it is not a default retry policy. Always inspect cleanup results, including trace cleanup failures. Never use `killall`, application-name targeting, or a replacement PID to finish a run.

## Fixtures and scenario setup

Generate fixture-owned media into a new directory:

```sh
fixture_dir="$build_receipt/fixtures"
python3 Scripts/agent-ui/fixtures.py --output "$fixture_dir"
```

The generator produces a 12-second tone, `video.mp4`, two playlist copies, `captions.srt`, and `fixtures.json` with hashes. `--audio-only` avoids FFmpeg but does not satisfy video/chrome/drag prerequisites. It does not provide multi-track, chapter, HDR, corrupted-history, remote-service, or missing-source fixtures. Provision those separately and retain their generation inputs and hashes. Generated media need not be byte-identical across FFmpeg versions.

For a fixture-dependent example, launch a fresh run and open the generated video as **hook setup**, then focus the player. Publish JSON with Python rather than interpolating a path into JSON by hand:

```sh
setup_request="$build_receipt/open-fixture.json"
python3 - "$fixture_dir/video.mp4" "$setup_request" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "action": "open", "sourcePath": str(pathlib.Path(sys.argv[1]).resolve(strict=True))
}) + "\n")
PY
run_dir="$repository_root/QualificationArtifacts/AgentUI/$qualification_id-playback"
python3 Scripts/agent-ui/agent_ui.py launch \
  --app "$app_bundle" --run-dir "$run_dir" --timeout 30
python3 Scripts/agent-ui/agent_ui.py hook --run-dir "$run_dir" --request "$setup_request"
python3 Scripts/agent-ui/agent_ui.py act --run-dir "$run_dir" \
  --request '{"action":"focus","mode":"accessibility"}'
python3 Scripts/agent-ui/agent_ui.py run --run-dir "$run_dir" \
  --scenario Tests/AgentUI/Scenarios/playback-shortcuts.json
python3 Scripts/agent-ui/agent_ui.py close --run-dir "$run_dir" --timeout 15
```

Prefer a fresh process and state per case rather than changing unknown persistent preferences. Playback examples assume default shortcuts, VoiceOver off, no focused text field/slider, and no modal or transient UI. Chrome additionally requires always-visible controls and benchmark pinning disabled, no interaction/focus pins, and an idle pointer. The launcher strips inherited `ILLIQUID_*` values; shell overrides do not automatically customize scenario state. Record explicit fixture setup and verify it through `agent-state`; never assume inherited tuning flags took effect.

| Scenario | Scope and prerequisites | Current evidence limit |
| --- | --- | --- |
| [inspection](../Tests/AgentUI/Scenarios/inspection.json) | One owned visible player; AX and capture permissions; no media needed | Window/tree and capture smoke; no per-control qualification |
| [playback-shortcuts](../Tests/AgentUI/Scenarios/playback-shortcuts.json) | Generated seekable video; Space/Right/Left delivered as real keys | Pause intent and bounded position observations; no visible frame/audio assertion |
| [settings-menu](../Tests/AgentUI/Scenarios/settings-menu.json) | One player, no other windows/modals; Command-comma and Command-W | Shortcut/window-count smoke; Settings content identity, individual preferences and pointer menu tracking pending |
| [chrome](../Tests/AgentUI/Scenarios/chrome.json) | Loaded video and unpinned chrome; real Space transitions | Model visibility after play/pause; pointer zones, timeouts and presentation pending |
| [window](../Tests/AgentUI/Scenarios/window.json) | Normal focused player; no modal or PiP; Command-F twice | Fullscreen state transitions; resize/minimize/multi-display pending |
| [timeline-grip-pending](../Tests/AgentUI/Scenarios/timeline-grip-pending.json) | Deliberately unavailable `timeline-grip-global-input` requirement | Must fail unsupported; diagnostic discovery is not a completed grip drag |

All examples use `schema_version: 1`, unique step IDs, explicit input modes, and bounded waits. `metrics.required: []` means correctness smoke only, **not** a performance pass. The timeline requirement is a deliberate pending sentinel, not a capability advertised by the app; do not remove it and claim drag coverage.

## Delivery modes, selectors, and assertions

`act` with `mode: "input"` delivers native pointer/keyboard events and exercises event routing. For example:

```sh
python3 Scripts/agent-ui/agent_ui.py act --run-dir "$run_dir" \
  --request '{"action":"key","mode":"input","key":"space","modifiers":[]}'
```

`mode: "accessibility"` uses semantic AX operations, for example focusing a window or pressing a discovered button. It can validate semantic behavior but cannot establish pointer hit testing. `menu` is an AX action against a currently discovered target, not an invented title-path API; inspect and resolve the current menu element's ephemeral ID first. Native menu shortcuts in the provided Settings/window cases use real input. Direct menu traversal still needs a case with fresh selectors and outcome assertions.

`hook` bypasses input and is for deterministic setup or state observation. Existing `play`, `pause`, `seek-exact`, `open`, and other benchmark commands must remain labeled hook work. Structured `capabilities`/`agent-state` responses require the benchmark bundle ID, override gate, valid session, absolute control file, and correlated session/command ID. Do not hand-signal a normal installed app. Commands are serialized through the runner; a timeout must not blindly replay non-idempotent input.

Hook results nest the app envelope: the pause-intent condition is `data.state.data.playback.pause_desired`. `wait` conditions evaluate each observation; a successful wait preserves that observation's data and adds `data.wait` metadata. Thus an `assert` immediately following that wait reads `data.state.data.playback.position_seconds`. An assertion follows the **last envelope**, not a persistent global state object. Dotted paths and JSON pointers are supported; arbitrary expression evaluation is not.

Launch uses `inspect` with `windows_only: true` for readiness; that response is explicitly marked as an incomplete UI tree. Use normal `inspect` for Accessibility discovery. Inspect the current tree immediately before targeting. Identifiers in [coverage.json](../Tests/AgentUI/coverage.json) were read from source; live presence and uniqueness are unqualified. Ephemeral `id` values are tree-bound and must be rediscovered after changes. Repeated rows require stable data identity; labels and list positions alone are insufficient. Ambiguous, missing, disabled or occluded targets fail; never silently replace real input with an AX press or hook.

The timeline grip remains AX-hidden. The app publishes `illiquid.timeline.grip` diagnostically in `swiftui-player-root-top-left-points`, with source revision and enabled state. Native pointer input uses `quartz-global-logical-points`; the window snapshot's frame uses AppKit bottom-left screen points. **These spaces are not interchangeable.** The grip container identifier and semantic `illiquid.timeline.position` slider do not select the grip. Its live input case remains pending until a tested transform accounts for content/window origin, scaling, sidebar, rotation and display geometry, then freshly resolves press/move/release points and asserts movement plus no accidental seek. Do not copy old screenshot coordinates or pretend the diagnostic target is an AX element.

## Trace collection and measurement limits

First discover tools and templates; `trace.py doctor` requires an evidence directory:

```sh
run_dir="$repository_root/QualificationArtifacts/AgentUI/$qualification_id-trace"
python3 Scripts/agent-ui/agent_ui.py launch \
  --app "$app_bundle" --run-dir "$run_dir" --timeout 30
python3 Scripts/agent-ui/agent_ui.py hook --run-dir "$run_dir" --request "$setup_request"
python3 Scripts/agent-ui/agent_ui.py act --run-dir "$run_dir" \
  --request '{"action":"focus","mode":"accessibility"}'
python3 Scripts/agent-ui/trace.py doctor --run-dir "$run_dir"
python3 Scripts/agent-ui/agent_ui.py trace start --run-dir "$run_dir" \
  --template 'Time Profiler' --seconds 30 --timeout 240
# Check status=ok and the data.ready recorder receipt before measured input.
python3 Scripts/agent-ui/agent_ui.py run --run-dir "$run_dir" \
  --scenario Tests/AgentUI/Scenarios/playback-shortcuts.json
python3 Scripts/agent-ui/agent_ui.py trace stop --run-dir "$run_dir" --timeout 60
python3 Scripts/agent-ui/agent_ui.py trace export --run-dir "$run_dir" --timeout 120
```

The runner reserves outer deadlines of at least 240 seconds for start, 60 for stop, and 120 for export so the adapter can finish bounded cleanup; shorter CLI values are rejected before profiling. These are watchdog budgets, not permission to retry a failed recording.

The start result's `data.ready` is a recorder receipt object, not a boolean; check its nested `ready` field and recorder identity. Keep setup/warmup outside the interaction interval and verify actual overlap in timestamps; a bounded recorder may finish before a long scenario. Do not assume template names or export tables exist on another Xcode version. The standalone exporter supports diagnostic extraction explicitly:

```sh
python3 Scripts/agent-ui/trace.py export --run-dir "$run_dir" \
  --metrics --require-metric time_profile_samples
python3 Scripts/agent-ui/agent_ui.py close --run-dir "$run_dir" --timeout 15
```

Retain raw `.trace`, recorder ownership/start/exit receipts, TOC, XML, stderr and export failures. The initial known extractor counts `time-profile` rows; `time_profile_samples` has no target-row or interaction attribution. It is not CPU utilization, latency, SwiftUI updates, hitch rate, displayed FPS, or proof that a regression improved. Default TOC export alone does not supply required measurements. Missing/empty required tables must remain unsupported/incomplete. Do not manually add invented zero metrics to make comparison pass.

SwiftUI, hitches, allocations, GPU and actual presentation data remain availability-dependent until exported, interpreted and correlated with action IDs. Hook acknowledgement, main-actor state, layout, draw submission and observed presentation are separate endpoints. Readiness explicitly leaves unsupported layout/draw/presentation milestones null. CPU stacks support hypotheses; screenshots, display-link callbacks and video-frame cadence do not establish UI displayed FPS. Recordings add overhead and have their own capture-rate ceiling. Validate any performance pipeline with a controlled slow fixture and a smooth control before setting a gate.

## Reproduction, comparison, and evidence

Retain each run under `QualificationArtifacts/AgentUI/<run-id>/`: `manifest.json`, `actions.jsonl`, immutable action artifacts, `app.log`, `scenario.json`, `assertions.json`, `metrics.json`, `report.md`, scoped captures and trace outputs. Failure is evidence too. The manifest must be supplemented where discovery is incomplete: fixture hashes and generator versions, exact build flags/dependencies, untracked source, OS/hardware/power mode, display resolution/refresh rate/backing scale, theme/UI scale/reduced motion, cache state, permissions, adapters, and instrumentation.

Pass a JSON file to `launch --context context.json` containing matching `fixtures`, `instrumentation`, `display`, `cache_state`, and `preferences` fields for intended comparisons. Populate these from measured/configured values and retained fixture hashes; do not use placeholder context as a qualification receipt. Keep source/binary identity different between baseline/candidate while keeping workload context identical. Run serial cohorts in alternating order, using separate immutable bundle paths and run directories.

```sh
python3 Scripts/agent-ui/agent_ui.py compare \
  --baseline "$baseline_run" --candidate "$candidate_run"
```

Comparison needs passing scenario receipts, identical scenario hashes, matched context/environment, and nonempty compatible measurements with retained raw artifacts and named units/endpoints. The supplied correctness examples intentionally export no required performance metrics; comparing them alone must not yield a performance claim. A single pair does not establish variation, tail percentiles or a regression threshold. Record correctness separately from diagnostic/measurement availability, contamination, and acceptance.

## Troubleshooting and coverage updates

| Result or symptom | Action and evidence boundary |
| --- | --- |
| `permission-required` | Inspect the named AX/post-event/capture/profiling permission and responsible executable; authorize it in the dedicated session, then start a fresh recorded attempt. Never count denial as pass. |
| No interactive session, focus lost, held input or occlusion | Restore the isolated test environment; preserve the failed action. Do not force global events into another app or claim all physical-input contamination is detected. |
| `target-lost` | Compare PID, process start identity, executable path/hash and bundle ID. Stop interacting with the stale receipt; launch a new run. |
| Hook rejected or times out | Check bundle identity, lifecycle/override gates, control-channel ready line, session/command correlation and `app.log`. A normal source executable does not enable the benchmark channel. Never resubmit a mutation blindly. |
| `assertion-failed` | Retain the observation and confirm fixture, default shortcuts, key window, text focus, VoiceOver and actual envelope path. Desired pause state is not decoded/presented output. |
| Missing/ambiguous AX selector | Reinspect the current tree, increase bounded inspection only with cause, and check truncation. Add coverage only after source/contract integration; do not invent IDs. |
| Settings example sees the wrong second window | Its prerequisite is exactly one player before opening Settings. Use a clean fresh run; window ordering alone does not identify Settings content. |
| Grip target exists but drag cannot run | Check coordinate-space metadata; the current diagnostic map does not implement a global input selector. Preserve pending coverage. |
| Build fails on SDK/dependency audit or dylib loading | Read `build.log`, reviewed native-input locks and runtime rpaths. Repackage into a fresh path using repository tooling; audit/compile success is not launch proof. |
| Trace template/export unavailable or empty | Retain discovery, TOC/raw trace and errors. Report unavailable measurements, not zero FPS or a successful performance gate. |
| Scenario/artifact already exists | Use a new run. Preserve previous attempts, reports and captures. |
| Cleanup times out | Inspect owned target/recorder identity and cleanup receipt; do not broaden to app-name kills. Cleanup success and scenario success are separate. |

The inventory assigns every listed family `automated`, `partial`, `pending`, or `environment-dependent`, with explicit prerequisites and gaps. It separately identifies five runnable examples after their prerequisites and one deliberately gated pending probe. No family is currently marked automated or fully live-qualified. Two examples have retained historical smoke passes (inspection: three steps; playback-shortcuts: 19 steps), explicitly scoped to those receipts; current helper edits still require aggregate validation. Partial means a supplied example covers only named behavior; a pending probe is not a skipped pass. Use representative playing/paused/loading, sidebar, theme, scale, window and fixture combinations rather than claiming the full Cartesian product. Multi-display, HDR, hardware audio, PiP, controlled network/update services and VoiceOver require their own environment receipts. The parent updates final CLI/selector integration and qualification status after real validation; JSON validation alone must not promote any family.

## Component validation without live UI

The [Agent UI tools workflow](../.github/workflows/agent-ui-tools.yml) runs component tests (including native helper compilation) and scenario/inventory contract tests on macOS. It uses Kyoto when the shared queue is present; hosted runners explicitly report its absence before compiling directly. It does not launch Illiquid, grant permissions, deliver native input, profile rendering, or qualify these scenarios live. The inventory tests check scenario schema, reference/count consistency, and synthetic playback assertion paths without native input. The following standalone check uses the runner's schema validator without creating an adapter or running a scenario:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util, json
from pathlib import Path
spec = importlib.util.spec_from_file_location('agent_ui', 'Scripts/agent-ui/agent_ui.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
for path in sorted(Path('Tests/AgentUI/Scenarios').glob('*.json')):
    runner.validate_scenario(json.loads(path.read_text()))
    print(path, 'schema valid; live UNRUN')
json.loads(Path('Tests/AgentUI/coverage.json').read_text())
PY
```
