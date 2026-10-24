# macOS agent UI automation runbook

Status: initial implementation, integrated 2026-10-23; evidence updated with the 2026-10-24 UTC development receipts. Read the [plan](MACOS_AGENT_UI_AUTOMATION_PLAN.md), [implementation contract](../Scripts/agent-ui/IMPLEMENTATION_CONTRACT.md), [preference launch contract](../Scripts/agent-ui/PREFERENCE_ISOLATION_CONTRACT.md), and [coverage inventory](../Tests/AgentUI/coverage.json) together. A structurally valid scenario is not a passing native UI test.

Historical integration validation on the development Mac (2026-10-23) follows. Each receipt applies to its recorded source/helper version and is preserved independently of the newer evidence below:

| Check | Result and evidence boundary |
| --- | --- |
| Optimized product build | Passed; `/tmp/illiquid-agent-ui-build.log`. Existing Metal Sendable warnings remain. |
| Packaging and helper preparation | Kyoto job `f675d92fcc8a46eebaf4b8f373d3b0fd` succeeded; benchmark bundle audit passed for 32 arm64 Mach-O images with valid signatures. |
| Component suite | 117 tests passed through Kyoto job `b868f79e3f5249c4b5aced4c1cdb805b` before subsequent activation run-loop changes. These receipts do not qualify later helper edits. |
| App protocol | Four tests passed in an isolated harness with stubbed playback dependencies; this is not a full app test-suite result. |
| Preflight | Accessibility, post-event and Screen Recording access detected; Instruments templates discovered. |
| Inspection scenario | Passed all three steps, including an owned-window screenshot; receipt directory `/tmp/illiquid-agent-ui-live-20261023-inspection-4`. |
| Playback shortcuts | Passed all 19 steps with generated video, real Space/Left/Right input, and app-state assertions; receipt directory `/tmp/illiquid-agent-ui-live-20261023-playback-6`. This proves those input/state transitions, not visible-frame latency. |
| Time Profiler | Failed: readiness notification did not arrive before the deadline. Recorder received SIGINT and was reaped; `cleanup_confirmed: true`, `measurement_valid: false`. Failure retained under the playback run's `trace/7aabdf4d197649bb938adccf922e297d`. No performance pass or metric export is claimed. |
| Post-trace screenshot | Refused because no owned window was on-screen at capture time; this is not a renderer result. |
| Cleanup | The inspection and playback apps terminated gracefully. Playback close preserves the earlier profiler failure in its result even though app termination and recorder cleanup completed. |
| Preference isolation | These historical launches inherited existing benchmark preferences; `CFFIXED_USER_HOME` alone was insufficient. Their receipts do not establish isolation. The newer session-suite contract and receipt are described below. |

Newer development evidence is scoped to the retained bundle, helper versions and individual checks; it does not promote any inventory family to automated or live-qualified:

| Check | Result and evidence boundary |
| --- | --- |
| Product/package | Kyoto job `21a6ad7fbd0647d1999f5fb4ceb0441b` passed compilation and 6/6 `AgentUIProtocolTests`; `/tmp/illiquid-agent-ui-app-20261023-r2/Illiquid.app` passed the 32 arm64 Mach-O image/signature audit. Executable SHA-256: `70b30f19f97924c61091ef93c050d662e925a5c510b528fedd5a6f588a261779`. Helpers were prepared through Kyoto. This does not qualify later source/helper changes. |
| Component checks | Runner: 76 tests passed; trace: 71 tests passed; inventory: 10 Python contracts passed. These are separate component/contract results, not a full app suite or live UI pass. |
| Preference isolation | Standalone Kyoto job `ea21da702ec543c58fe3e953b2b43cfe` passed 71 controls. Live launch `/tmp/illiquid-agent-ui-live-20261024-grip-r1` validated a session-bound `session-suite-only` receipt with `fallback_domains: []`. This proves preference initialization for that launch, not all Settings controls, scene updates or persistence behavior. |
| Grip scenario | Failed before mouse-down: native full-tree inspection returned `AX count AXChildren failed: -25204`. The runner records `input_attempted: true`, which does not establish delivered pointer input. The full-tree coordinate-input fix is ongoing separately; no live drag pass is claimed. |
| Time Profiler | Actual recorder readiness was confirmed by Darwin notification. Stop failed at the bounded 10-second recording/finalization deadline; owned recorder cleanup was confirmed and reaped. Export failed with `Document Missing Template Error`; `measurement_valid: false`, no qualified metric. This is distinct from the historical readiness timeout above. |
| Cleanup | App close reported `terminated: true`, `forced: false`; the outer close result remained `timed-out` and propagated the trace failure. Cleanup success is not workload or measurement success. |
| Source corrections | Command-T help now says “New Video Tab”; subtitle-delay completion captures/checks source identity and shutdown before applying a change. Focused Kyoto job `c2ad910c28514ed9b80a53e23f1b546e` failed compilation in the test fixture (`NSTextField(frame:)` stub mismatch). These source corrections have no passing focused-test or live-dialog qualification from that job. |

Retain `/tmp/illiquid-agent-ui-live-20261024-grip-launch-r1.json`, `/tmp/illiquid-agent-ui-live-20261024-grip-scenario-r1.json`, `/tmp/illiquid-agent-ui-live-20261024-trace-start-r1.json`, `/tmp/illiquid-agent-ui-live-20261024-trace-stop-r1.json`, `/tmp/illiquid-agent-ui-live-20261024-trace-export-r1.json`, and `/tmp/illiquid-agent-ui-live-20261024-close-r1.json`, together with the run directory and its original manifest/helper hashes. These attempts are retained failures where indicated; subsequent fixes require new receipts.

These temporary development receipts are not portable CI artifacts. The run manifests explicitly report incomplete checkout provenance when Git diff capture times out or untracked source is omitted; no frozen baseline/candidate performance qualification is claimed. The coverage inventory describes wider app interactions that still need implementation or live qualification.


Latest follow-up validation: Kyoto `4714f7f5876748889029ba5ff5dd41fb` prepared the updated coordinate-input helper; `6e2123aecedf422a87972fbf938771b7` passed all nine native tests. The helper bypasses full AX enumeration only for coordinate input constrained to an owned window, retaining identity, focus, window, hit and cleanup checks. A fresh live grip run with this helper remains pending. Kyoto `df8285adb8cb4924a6254969229c47fc` compiled and executed 60 production subtitle-delay/help checks with fake UI after the fixture geometry alias correction; this supersedes the earlier focused fixture-compilation failure, without qualifying live dialogs. Trace finalization/export remains failed with no valid performance measurement.

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

Use a **new, absent run directory for each scenario**. A run retains one scenario and refuses to replace its receipt; capture also refuses to overwrite an existing artifact. `launch` selects the exact benchmark bundle executable and retains PID, executable hash, start identity, owned status, session/control-file paths and readiness. It creates run-owned home/temp/session/cache state and opts into the guarded benchmark channel. Its recorded planar software-output selection matches the intended production path; it is an explicit override, not proof that every backend matches production.

Owned launch requires the [preference launch contract](../Scripts/agent-ui/PREFERENCE_ISOLATION_CONTRACT.md): an exact benchmark bundle/override gate, control-session-derived suite, run-owned session path, and an absolute, initially absent receipt path. The runner validates the app's receipt before reporting isolated readiness: PID/session/suite, seed identity, `isolation_mode: "session-suite-only"`, `fallback_domains: []`, and the canonical effective-value hash must match. A missing, mismatched or invalid receipt fails launch; it must not fall back to the shared domain. `CFFIXED_USER_HOME` alone remains insufficient. Attach does not establish this contract. The live receipt above qualifies initialization for its recorded launch; it does not qualify all Settings controls or system/framework preferences.

Omit the seed for fresh app code defaults, or provide a reviewed app-owned JSON seed explicitly:

```sh
python3 Scripts/agent-ui/agent_ui.py launch \
  --app "$app_bundle" --run-dir "$run_dir" --timeout 30 \
  --preferences-seed-file "$preference_seed"
```

This is an alternative launch into a new run directory, not a second launch into the earlier run. The runner copies the seed byte-for-byte to `state/preferences-seed.json` and retains its path/hash and values. Seeds are at most 1 MiB, use contract-approved app keys and property-list values, and cannot set the suite reservation key. Retain `artifacts/preferences.json` and the manifest's validated preference record. The receipt snapshots initial persisted values, not every unpersisted code default, live Settings behavior, or crash durability. Never reset/reuse a suite or overwrite its receipt to repair a failed attempt.

Launch activates the exact owned process as semantic setup, then waits for an on-screen owned window. The activation helper pumps its run loop until frontmost ownership is observed, then checks AX focus; this is semantic setup rather than an input-routing assertion. The windows-only probe does not require AX discovery and returns `elements: []`, `truncated: true`, and `inspection_scope: "windows-only"`. Neither endpoint proves layout/presentation readiness.

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
| [timeline-grip-pending](../Tests/AgentUI/Scenarios/timeline-grip-pending.json) | Loaded seekable video, focused player, visible chrome and unlocked controls; fresh app-published grip geometry | Target-driven drag/outcome checks implemented; retained attempt failed at native AXChildren inspection before mouse-down; no live drag pass |

All six examples use `schema_version: 1`, unique step IDs, explicit input modes, and bounded waits. `metrics.required: []` means correctness smoke only, **not** a performance pass. The timeline scenario retains its historical filename and requires the implemented `timeline-grip-global-input` route; absent capability must still fail before steps. Runnable after prerequisites does not mean live-qualified; its retained actual attempt failed. The Settings scenario description still contains older shared-domain wording, mirrored verbatim in the inventory's `setup` field by contract. Its `current_prerequisites` and the preference launch contract above govern new owned launches.

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

The timeline grip remains AX-hidden. The app publishes `illiquid.timeline.grip` diagnostically in `swiftui-player-root-top-left-points`, with source revision and enabled state, plus fresh NSView/window-to-Quartz screen geometry. Native pointer input uses `quartz-global-logical-points`; the window snapshot's frame uses AppKit bottom-left screen points. **These spaces are not interchangeable.** The grip container identifier and semantic `illiquid.timeline.position` slider do not select the grip. The transform and target-driven movement/no-seek/released-pin checks are implemented, but the retained actual attempt failed in native full-tree AXChildren inspection before mouse-down. The coordinate-input fix is ongoing separately. Transform behavior across content/window origins, scaling, sidebar, rotation and display geometry, actual event delivery and asserted drag outcomes still require live qualification. Do not copy old screenshot coordinates or pretend the diagnostic target is an AX element.

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

For isolated launches, comparison also requires validated preference records, empty fallback domains, matching isolation mode, seed-byte hash and effective initial values. Verify each receipt's `effective_initial_sha256` against the exact UTF-8 `effective_initial_canonical_json` supplied by the app; parsing must agree with `effective_initial_values`. Do not re-encode with Python and assume identical canonical bytes. The raw hash includes the unique `Illiquid.agent-ui-preference-suite.v1` reservation, so it normally differs between runs. Compare validated effective values with only that reservation removed; retain the complete raw receipt/hash. Matching operator context cannot replace receipt validation. Historical manifests retain their explicit historical context and do not acquire isolation evidence retroactively.

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
| Grip target exists but drag cannot run | Check fresh named-root-to-Quartz geometry and exact target/window/source identity. The retained actual attempt failed with `AX count AXChildren failed: -25204` before mouse-down; a separate native coordinate-input fix is ongoing. Keep that failure and require a fresh live receipt after helper preparation; published geometry is not drag success. |
| Build fails on SDK/dependency audit or dylib loading | Read `build.log`, reviewed native-input locks and runtime rpaths. Repackage into a fresh path using repository tooling; audit/compile success is not launch proof. |
| Trace template/export unavailable or empty | Retain discovery, TOC/raw trace and errors. Report unavailable measurements, not zero FPS or a successful performance gate. |
| Scenario/artifact already exists | Use a new run. Preserve previous attempts, reports and captures. |
| Cleanup times out | Inspect owned target/recorder identity and cleanup receipt; do not broaden to app-name kills. Cleanup success and scenario success are separate. |

The [coverage inventory](../Tests/AgentUI/coverage.json) is a source feature audit at `b5ceab959c97b36be8a32d71da870538567db20c` (2026-10-23). It accounts for 73 families and 203 structured state variants: 0 automated, 8 partial, 51 pending, and 14 environment-dependent. Every family has `live_qualified: false`. Library/source browsing, open/drop routes, playlist and video tabs, restoration, all eight Settings destinations, all 25 editable playback shortcuts, native accelerators, dialogs, accessibility and the playback audit are represented. Routes, prerequisites, source paths, state variants, and expected outcomes describe work to execute and assert; their presence is not an automation pass. The Settings example only checks a second owned window and does not identify page content. Destination content anchors require separate live assertions and scaled-window scrolling checks.

Executable coverage is tracked separately: six scenario examples are runnable after their prerequisites, including the grip route whose actual attempt failed before mouse-down. None is marked live-qualified. The retained inspection (three steps) and playback-shortcuts (19 steps) smoke receipts apply only to their recorded source/helper versions and named steps. The old inventory baseline `2cf381767023c5e7f748e3e45a214e002a8b87ae` is preserved as historical inventory metadata; it is not a reconstructed pin for every receipt. Original run manifests and helper hashes govern that evidence. The `b5ceab9` feature audit does not requalify those receipts, the prior build, or the 117-test component result. The newer package, component, initialization and failed live receipts above are recorded separately from the original read-only audit. This documentation update performs no build, launch or live input. `partial` records limited example scope; a failed probe is not a skipped pass.

Use each state's expected outcome to design a fixture, deliver the named input route, and assert the resulting content/state and relevant persistence or output. For example, surface replace/Option-append and sidebar add-to-tab drops need distinct tests; Show Hidden concerns app rules, not filesystem-hidden files. Selecting a setting or opening a menu does not prove its effect. The historical Command-T help discrepancy is source-corrected to “New Video Tab.” The subtitle-delay sheet now captures source identity and checks it, with shutdown state, before applying or re-presenting input; Go to Time retains its separate guard. Preserve these variants as regression targets. Focused job `c2ad910c28514ed9b80a53e23f1b546e` failed in test-fixture compilation, so passing focused controls and live stale-source/dialog outcomes remain unqualified. This update changes documentation/inventory only.

Representative playing/paused/loading, sidebar, theme, scale, window and fixture combinations still need qualification. The audit does not claim the full Cartesian product or exhaustive dynamic third-party/system UI. Multi-display, HDR, hardware audio, PiP, controlled network/Sparkle signed feeds, Launch Services/Finder/native panels, fault injection and VoiceOver require their own environment receipts; do not invent system dialog details. Source anchors and Python contracts check inventory bookkeeping and detect source drift. They do not prove event delivery, visible presentation, audio output or UI correctness, and must not promote any family.

## Component validation without live UI

The [Agent UI tools workflow](../.github/workflows/agent-ui-tools.yml) runs component tests (including native helper compilation) and scenario/inventory contract tests on macOS. It uses Kyoto when the shared queue is present; hosted runners explicitly report its absence before compiling directly. It does not launch Illiquid, grant permissions, deliver native input, profile rendering, or qualify these scenarios live. The inventory tests check unique IDs, required fields, existing repository source paths, state/outcome structure, Settings destinations/content anchors, shortcut definitions/native accelerator anchors, scenario reference/count consistency, and synthetic playback assertion paths without native input. Run these Python-only contracts without preparing or compiling helpers:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/AgentUI -p 'test*.py' -v
git diff --check
```

The following standalone check uses the runner's schema validator without creating an adapter or running a scenario:

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
