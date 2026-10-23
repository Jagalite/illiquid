# macOS Agent UI Automation and Performance Debugging

Status: initial implementation available, 2026-10-23. Scope: Illiquid on macOS. Baseline: `2cf3817`. Use the [runbook](MACOS_AGENT_UI_AUTOMATION_RUNBOOK.md) for the implemented CLI and the [coverage inventory](../Tests/AgentUI/coverage.json) for remaining interaction work.

The first implementation adds a PID-scoped runner, native AX/input/capture adapter, bounded Instruments adapter, guarded app snapshots, stable identifiers, generated media fixtures, and scenario contracts. A prior component suite passed 117 tests before the latest activation run-loop changes; current-source aggregate validation is pending. Retained live preflight detected the required permissions and profiling templates on the development Mac. Retained inspection/capture (three steps) and playback-shortcut (19 steps) receipts passed for their recorded helper version. Instruments readiness timed out with confirmed cleanup, so no displayed-performance result is available. The roadmap below remains the broader target; per-run preference isolation, custom grip screen-coordinate mapping, comprehensive scenarios, reliable live trace capture, and presentation metrics are still pending.

## Objective

Enable an agent to launch the intended build, discover and operate the entire UI, reproduce a reported problem, capture diagnostic evidence, and compare a candidate with a baseline without requiring a person to perform each interaction.

Keep native rendering and UI automation on macOS for now. Reuse generic computer interaction tools for exploration and Apple profiling tools for diagnosis. Add a small repository-owned runner and adapters so tests do not depend on one agent provider. This plan does not require a Linux renderer or a replacement UI framework.

The initial timeline investigation illustrates the gap: a CPU sample captured actual dragging and identified avoidable UI rebuilding, but the reported improvement from roughly 20 to 45–50 FPS was subjective. Neither stack samples nor geometry microbenchmarks establish displayed UI frame rate.

## Existing foundations

| Component | Available today | Change needed |
| --- | --- | --- |
| [Direct launcher](../Scripts/run-app.sh) | Builds and runs release by default with native SDK library selection | Return a launch receipt with PID, executable identity, readiness, and owned windows; support isolated test state |
| [Benchmark controller](../Sources/IlliquidApp/App/BenchmarkPlaybackControl.swift) | Session-tagged JSON command file, SIGUSR1 notification, bounded payloads and command deduplication | Version the protocol; add capability discovery, structured state, correlated completion events, and explicit failure results |
| [App command handlers](../Sources/IlliquidApp/App/AppModel.swift) | Open/close/reopen, sidebar, resize, preview hover, source query, and other benchmark actions | Distinguish setup/model actions from real UI input; expose diagnostic state without bypassing input tests |
| [App control helper](../Scripts/performance-app-control.swift) | PID-targeted quit and Accessibility close-window action | Extend through an interaction adapter, with target identity and window selection checks |
| [Performance suite](../Scripts/profile-performance-suite.py) | Serial baseline/candidate cohorts, isolated benchmark bundles, receipts and validity checks | Add UI interaction scenarios and rendering trace results to the existing evidence model |
| [Responsiveness probes](../Scripts/profile-responsiveness.py) | Preview/navigation workloads and window screenshots | Supplement injected hover commands with real pointer, keyboard, and gesture scenarios |
| [Lifecycle instrumentation](../Sources/IlliquidCore/Utilities/LifecyclePerformance.swift) and [nondecode instrumentation](../Sources/IlliquidCore/Utilities/NonDecodePerformance.swift) | Signposts and opt-in benchmark diagnostics | Add correlated interaction intervals and documented completion endpoints |
| Existing component tests and geometry benchmarks | Deterministic logic and layout contracts | Retain as fast checks; add native interaction coverage rather than treating them as UI qualification |

The benchmark controller currently requires bundle identifier `com.example.IlliquidBenchmark`, `ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1`, a valid control session, and an absolute command-file path. Running the ordinary source executable does not automatically enable this channel. Preserve this distinction when selecting a runner target.

The earlier [lifecycle audit](LIFECYCLE_PERFORMANCE.md) already distinguishes command acknowledgement, first frame submission, visible windows, and actual display output. Reuse those definitions and its isolated-state practices.

## Proposed agent interface

Add one CLI with machine-readable results, usable directly by agents or wrapped by an MCP tool. A new MCP server is optional; the CLI and result schema should be the shared implementation.

Implementation location: `Scripts/agent-ui/`. The following is the original design contract; consult the runbook and `agent_ui.py --help` for exact implemented arguments:

| Operation | Required behavior |
| --- | --- |
| `doctor` | Report OS/Xcode versions, selected developer directory, display/session readiness, available automation adapters, permissions, trace templates, and export support |
| `launch` / `attach` | Select exact executable or bundle, resolve PID and windows, validate build identity, and wait for bounded readiness |
| `inspect` | Return control tree, stable identifiers, role, label, value, enabled/visible/focused state, bounds, and window identity |
| `act` | Click, double-click, secondary-click, hover, move, drag, scroll, type, key chord, menu action, focus, and window operations |
| `wait` / `assert` | Wait for a specific observable condition or assert it with a deadline and diagnostic failure |
| `capture` | Save owned-window screenshots, optional recordings, UI tree, and relevant app-state snapshots |
| `trace start` / `trace stop` | Start the selected profiler, confirm recording before input begins, stop and export with bounded waits |
| `run` / `compare` | Execute a declarative scenario and compare valid matched runs |
| `close` | Release inputs, stop owned profilers, and clean up only the processes/state created by the run |

Each result needs a schema version, run ID, action ID, monotonic timestamps, target identity, status, error details, and artifact paths. Report `unsupported`, `permission-required`, `timed-out`, `target-lost`, and `assertion-failed` separately. Never report a missing measurement as zero or a skipped interaction as a pass.

Provide explicit execution modes:

- **Real input:** exercise application event routing using an approved computer-use adapter, macOS input delivery, or XCUITest where appropriate.
- **Accessibility action:** invoke a control semantically; useful for discovery and behavior tests, but not proof that its pointer hit target works.
- **App hook:** deterministic setup, fault injection, state inspection, and narrow component benchmarks. Record that it bypasses native input.

Require scenarios to declare their mode. Do not silently replace a failed click with an internal command that produces the expected final state.

## Changes to application observability

### Stable targets across the whole app

Audit existing accessibility metadata and add stable identifiers to player windows, video surface, transport controls, timeline and grip, utility controls, sidebar/search/results, tabs, settings, popovers, sheets, and recovery/error actions. Use stable data identity for repeated rows rather than visible text or list position alone.

Native accessibility and visual targeting need separate treatment. The timeline grip is currently accessibility-hidden; define how automation obtains its visible hit region without creating a misleading VoiceOver element. A diagnostic target map can supplement the accessibility tree for custom geometry. Keep labels and keyboard behavior usable for actual accessibility users.

Normalize screen, window, and content coordinates, including backing scale, interface zoom, sidebar displacement, fullscreen, and curved/rotated controls. Resolve target bounds immediately before input; a saved screenshot coordinate is insufficient after layout changes.

Primary update sites:

- `Sources/IlliquidApp/UI/ElasticPlaybackControlBar.swift`
- `Sources/IlliquidApp/UI/PlayerRootView.swift`
- `Sources/IlliquidApp/UI/SourcesSidebar.swift`
- `Sources/IlliquidApp/UI/SettingsView.swift`
- `Sources/IlliquidApp/App/PlayerCommands.swift`
- `Sources/IlliquidNativePlayback/Presentation/NativePlayerView.swift`

### Readiness and completion

Expose read-only diagnostic snapshots for source identity/revision, playback state and position, chrome phase/pins, active interaction, window/layout state, focused target, loading work, and pending presentation. Use these with visible UI assertions.

Define different milestones: input dispatched, event handled, state changed, layout settled, draw submitted, and presentation observed where supported. A `seek` acknowledgement is not proof that the selected frame became visible. A pointer move acknowledgement is not proof that a grip drag was recognized.

Extend `BenchmarkPlaybackControl.swift` and its `AppModel` integration first. Keep setup commands opt-in and scoped to the isolated benchmark identity. Use correlated command/event IDs, atomic command publication, and serialized delivery to avoid overwriting commands in the current single-file transport. Retries must not repeat non-idempotent input blindly.

## Interaction coverage

Maintain a scenario inventory with an explicit disposition for every user-visible action: automated, partially covered, environment-dependent, or pending. “Whole app” means accountable coverage, not a claim that every combination is exhaustively tested.

| Area | Required scenarios |
| --- | --- |
| Launch and lifecycle | Empty launch, restored session, open file/folder, drag-and-drop media, close/reopen, quit during loading, second-window behavior where supported |
| Playback | Play/pause, stop, previous/next, repeat/shuffle, exact/relative seek, scrub, speed, supported frame-step actions, keyboard and menu equivalents |
| Video and chrome | Click hide/show, double-click zones, pointer exit/reentry, paused timeout policy, pinning, focus, interruption/cancellation |
| Movable timeline | Grip press/move/release, bends/rotations, lock/reset, edge constraints, sidebar interaction, scale changes, scrub-versus-move routing |
| Audio and subtitles | Volume/mute, track menus, external subtitles, timing changes, unavailable tracks, popover dismissal |
| Sources and tabs | Add/remove test sources, expand/collapse, search/filter/sort, scroll, select/open, switch/close tabs, missing media and restoration |
| Settings and dialogs | All preference controls, reset defaults in isolated state, file panels, sheets, inspector, help, errors and recovery actions |
| Window and presentation | Resize, fullscreen transitions, minimize/restore, multiple displays where available, Picture in Picture, fit-to-video |
| Accessibility and input | Tab/arrow focus, activation, Escape, shortcut conflicts, menu tracking, focus return after dialogs; separate VoiceOver qualification |

Run representative combinations of playing/paused/loading, sidebar open/closed, theme, UI scale, window size, reduced-motion setting, and fixture type. Use a smaller smoke cohort for each change and broader scheduled coverage; do not run the entire Cartesian product by default.

## Performance collection

Use Instruments through `xctrace` for scripted capture and export. Discover installed templates and export schemas in `doctor`; do not assume all Xcode versions expose identical tables. Apple’s SwiftUI instrument provides update analysis alongside Time Profiler and Hangs/Hitches diagnostics. See [Apple’s profiling walkthrough](https://developer.apple.com/videos/play/wwdc2025/306/).

Collect metrics appropriate to each scenario:

- **Interaction responsiveness:** event handling and state/layout completion latency, with clearly named endpoints.
- **UI smoothness:** supported hitch/frame-deadline measurements for the interaction interval; record display refresh rate and actual metric availability.
- **SwiftUI work:** view/representable updates and expensive update chains associated with that interval.
- **CPU and memory:** main-thread stacks, process CPU, allocations and footprint; use Metal/GPU diagnostics when the renderer is implicated.
- **Playback rendering:** existing renderer metrics/readback alongside UI measurements; video-frame cadence and UI animation cadence are different quantities.

Add signpost intervals for action IDs around interaction recognition, update work, and completion. Mark the automation dispatch time separately. Verify correlation in a real trace before using it as a regression gate.

A display-link callback rate, CPU stack sample, screenshot, or successful draw submission alone is not displayed FPS. Screen recordings help inspect visible behavior but have capture-rate limits and add overhead. If presentation metrics cannot be exported reliably, report the limitation and retain the trace for inspection rather than inventing a frame-rate result.

Validate the capture pipeline with a controlled slow test fixture and a smooth control. A successful `xctrace` process with empty SwiftUI/hitch data is an incomplete capture. Keep trace startup/export overhead outside measured interaction intervals and compare the same instrumentation settings.

## Reproducible Mac runner

Use an optimized isolated benchmark bundle with a unique path and the existing benchmark identity. Record the exact binary, source revision and dirty patch, dependency manifest, build flags, and symbols. Do not identify the target by application name alone: earlier automation in this thread opened an installed app instead of the intended unbundled source executable.

The interactive lane requires a logged-in usable macOS GUI session. Detect lock state, visibility, focus, permissions, display configuration, and missing hardware capabilities before a scenario. A shell session or headless component test is not equivalent to a visible native rendering run. Prefer a dedicated Mac/account for sustained automation so user input does not contaminate results.

Use fixture-owned preferences, session files, sources, caches, and generated/licensed media. Preserve production defaults for renderer/backend selection unless a scenario explicitly tests an override. Record warm/cold cache conditions, refresh rate, resolution, UI scale, theme, power mode, OS, hardware, and tool versions. Detect user input or focus loss and mark contaminated runs.

Provision Accessibility, capture, developer-tool, or automation permissions as required by the selected adapter. Report missing prerequisites; do not disable platform protections. Local benchmark packaging and any required signing should reuse existing build tooling and remain separate from distribution/notarization.

## Evidence and comparison contract

Store each run under `QualificationArtifacts/AgentUI/<run-id>/` with:

- `manifest.json`: target/build/fixture hashes, environment, adapter versions, instrumentation, and scenario version.
- `actions.jsonl`: requested actions, actual delivery mode, timestamps, target bounds, completion and failure events.
- `assertions.json`: correctness results and required measurement availability.
- `metrics.json`: raw observations, units, endpoint definitions, sample counts, and summaries.
- Native trace, export files, logs, UI snapshots, and scoped screenshots/recordings when requested.
- `report.md`: reproduction command, observed issue, suspected cause, comparison, and unresolved limitations.

Use serial baseline/candidate runs with identical fixtures and scenarios and alternating order. Establish variation before setting performance thresholds. Record distributions and run counts; a handful of observations does not establish a reliable tail percentile. Keep correctness gates independent from performance gates.

## Implementation sequence

| Stage | Deliverable | Acceptance |
| --- | --- | --- |
| 1 | Runner preflight, isolated launch/attach, target receipts, structured output and cleanup | Never selects an installed copy accidentally; missing permission/session/target produces an actionable failure; user preferences remain untouched |
| 2 | Inspect/capture and real-input adapter with stable targets | Agent can discover controls and execute click, keyboard, hover, scroll, drag, menu and window operations; tests demonstrate native routing rather than hook substitution |
| 3 | Correlated state/events and scenario runner | Readiness and completion use bounded conditions; cancellation releases held buttons/keys; failed runs retain evidence |
| 4 | Trace adapter and export validation | Controlled slow/smooth scenarios produce useful correlated measurements; empty or unsupported metrics cannot pass |
| 5 | App-wide coverage inventory and smoke/regression cohorts | Every interaction area above has scenarios or an explicit gap; restart/reset is deterministic |
| 6 | Baseline comparison and Mac automation lane | Repeatable one-command reports, stable thresholds on a designated machine, and artifacts available to agents/reviewers |

Proposed new files are `Scripts/agent-ui/`, `Tests/AgentUI/Scenarios/`, and an agent runbook alongside this plan. Add an XCUITest runner target only where it provides more reliable interaction or assertions than the generic adapter; do not make XCUITest mandatory for every operation. Apple documents native drag actions in [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation/xcuielement/click(forduration:thendragto:)).

## Agent workflow after implementation

1. Run preflight and launch the exact build in isolated state.
2. Inspect the UI and translate the issue into a replayable scenario with assertions.
3. Warm up as specified, start capture, wait for recorder readiness, then execute real input.
4. Confirm the interaction occurred and required data exists before diagnosing it.
5. Correlate slow intervals with app-owned work; treat stacks as evidence for a hypothesis, not proof of causation.
6. Make a focused change, run relevant correctness tests, then replay matched baseline/candidate workloads.
7. Report measured changes and remaining gaps, retaining raw evidence and a reproduction command.

Completion means an agent can execute this workflow for each supported interaction family without asking a person to operate the UI. Hardware-dependent scenarios may remain explicitly conditional. The initial toolkit now implements part of this roadmap; the runbook and coverage inventory distinguish retained smoke receipts, current-source validation, and unimplemented interaction families. App-wide automation and displayed-performance qualification remain incomplete.
