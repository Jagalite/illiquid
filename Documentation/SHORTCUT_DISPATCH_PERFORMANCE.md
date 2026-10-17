# Player shortcut dispatch performance research

Date: October 17, 2026. Baseline: `main` at
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

## Result and scope

Keep the compiled-binding table and navigation-key switch. Both changes remove
repeated work from the player's main-thread keyboard handler while preserving
its dispatch results. The production diff is **35 inserted / 7 removed lines
in one file**, `Sources/IlliquidApp/App/PlayerShortcutBindings.swift`.

The final Linux component cohort contains **200 fresh-process timing
observations** across ten workloads, with ten pairs per workload and equal
AB/BA order. All nine dispatch workloads improve. The mixed sequence falls
from **33.297 to 0.466 microseconds per event** (98.60% less measured dispatch
time). Repeated Right-arrow seeking falls from **13.937 to 0.139 microseconds**.

This is an optimization of input interpretation. These numbers do not measure
physical keyboard-to-display latency, seek completion, whole-player CPU,
playback frame rate, energy, or process memory. Linux substitutes event/menu
value types for AppKit/SwiftUI; native qualification is a separate step below.

## Why this subsystem

This investigation owns A07.03 (commands, shortcuts, focus, accessibility, and
Now Playing) from the repository's agent hierarchy. The changed subsystem is
keyboard shortcut dispatch. It is independent of the concurrent decoder,
packet, renderer-recovery, subtitle, elastic-bar geometry, playlist, and
filesystem work.

In the baseline, `resolve` walks 25 shortcut definitions and constructs a
`PlayerShortcutChord` for each definition it reaches. Each construction checks
control characters, lowercases and splits the string, trims its parts, validates
key/modifier names, and builds the normalized chord. The strings normally have
not changed since the previous event.

For every chord whose modifiers match, `matches` also constructs the same
eight-entry navigation dictionary. Late matching and unmatched inputs do this
repeatedly. The `AppModel` local key monitor invokes `resolve` before
first-responder, focus-owner, and VoiceOver deferral, so unhandled typing can
also pay this cost. No changes were made to those routing checks.

Source anchors:

- [Baseline bindings](https://github.com/Jagalite/illiquid/blob/8c3cc3d4008d5d1b8d436bcf2d51d891382b6548/Sources/IlliquidApp/App/PlayerShortcutBindings.swift)
- [Baseline input monitor and fallback actions](https://github.com/Jagalite/illiquid/blob/8c3cc3d4008d5d1b8d436bcf2d51d891382b6548/Sources/IlliquidApp/App/AppModel.swift)
- [Agent subsystem hierarchy](Agents/HIERARCHY.md)

## Implementation decisions

1. Store an ordered array of `(action, chord)` values per bindings object.
   Build it after all startup conflict repair and after successful `set` or
   `reset`. Rejected edits preserve the active table. Rebuild before writing
   preferences so synchronous persistence observers see aligned settings and
   dispatch.
2. Keep the table `@ObservationIgnored`. Keyboard dispatch does not publish UI
   state. The existing `key(for:)` and `menuShortcut(for:)` implementations still
   read observable overrides, preserving menu/help/settings updates.
3. Keep definition order and the first matching action's repeat rule. A valid
   `Option+/` override can overlap the built-in `?` shortcut on some layouts;
   an unordered dictionary lookup or unconditional special-case priority could
   change the selected action. The compiled array preserves the existing rule.
4. Replace only the constant navigation dictionary with an equivalent switch
   for Space, arrows, Page Up/Down, and Delete. Modifier handling, character
   normalization, fallback actions, and suppression of remapped defaults remain
   the same.

No mutable global cache, persisted schema, background task, timer, or command
policy is added. There are 25 retained compiled records per bindings object in
the current definition table. This is a small added lifetime allocation, not a
claim of reduced resident memory.

## Experiments and controls

An initial exploratory ablation compared the baseline, cached chords with the
original navigation dictionary, and cached chords with the switch. Both
changes contributed, so both were retained. Those short scout runs were used
for implementation selection; their timing figures are not the publication
cohort below.

The final driver compiles production as one optimized shared module and the
timing harness separately. This stops whole-module optimization from combining
a constant synthetic input loop with the dispatch body. The driver's observable
checksum consumes every result. Both variants use the same actual fallback
`PlayerKeyboardAction` declaration, frozen by an extraction/hash check.

All dispatch inputs and preference setup occur before the clock starts. Every
process warms its workload before timing. The construction control intentionally
measures construction, reading all 25 displayed keys, and destruction against
an already prepared empty preference suite. It exposes the work shifted to
initialization; it is not cold app launch or disk-loading performance.

The final run used Swift 6.3.2, Swift 6 language mode, `-O`, whole-module
optimization within each module, and Linux x86_64 on a shared host with nine
visible CPUs. There was no concurrent benchmark/build in this investigation's
agent team during the final cohort. Host-wide contention was not controlled.
Each workload has five baseline-first and five candidate-first pairs. Per-pair
operation counts and checksums agree. Short paths use higher iteration counts;
all commands and elapsed intervals are retained.

## Final Linux measurements

Medians in microseconds per event, except construction (per object).
Changes are ratios of the two medians; paired ratios and both variants' ranges
are also retained in `summary.json`. The range column below is the candidate's
minimum–maximum observation. No observation in this cohort was discarded.

| Workload | Baseline µs | Candidate µs | Time change | Candidate range µs |
| --- | ---: | ---: | ---: | ---: |
| First binding (Go to Time) | 1.502 | 0.035 | -97.65% | 0.032–0.039 |
| Repeated Right-arrow seek | 13.937 | 0.139 | -99.00% | 0.133–0.159 |
| Mute / inspector | 48.903 | 0.336 | -99.31% | 0.296–0.484 |
| Unassigned letter keys | 51.897 | 0.449 | -99.13% | 0.339–0.574 |
| Escape fallback | 53.112 | 1.859 | -96.50% | 1.758–2.571 |
| Command / Control misses and frame repeat | 42.989 | 0.130 | -99.70% | 0.112–0.141 |
| Layout-dependent question mark | 46.945 | 0.276 | -99.41% | 0.246–0.384 |
| Mixed seven-event sequence | 33.297 | 0.466 | -98.60% | 0.410–0.515 |
| Custom bindings and old-key suppression | 36.006 | 0.456 | -98.73% | 0.407–0.696 |
| Construct object and read 25 keys | 4.154 | 51.939 | +1150.44% | 48.322–82.103 |

The construction control adds **47.785 µs per object** at the median.
That is the intended tradeoff from eager parsing. Against the measured median
savings, it amortizes after roughly two mixed-sequence events, four repeated
seek inputs, or 33 first-binding inputs. These are arithmetic comparisons of
component timings, not measured app-startup or usage distributions.

The large relative dispatch gains save tens of microseconds per later or
unmatched event. They should not be interpreted as an equivalent improvement
to end-to-end responsiveness. Candidate Escape and mixed-path ranges are
reported instead of substituting the faster exploratory values.

## Correctness evidence

The original and candidate implementations both pass **14 Swift Testing test
functions in two suites**, in **debug and release**: four successful runs.
This includes 13 new dispatch tests and the existing persistence/remapping test.
Tests state expected routing independently of the cache implementation.

Coverage includes all 25 editable default actions and Escape fallback,
key-code navigation with unrelated character payloads, allowed repeats,
Shift/Option matching, ignored incidental flags, reserved modifiers, active
keyboard-layout characters, the `?` overlap ordering rule, successful and
rejected edits, immediate old-default suppression, reset, remap chains/cycles,
cascading saved-conflict repair, invalid/unknown saved entries, instance-local
preference snapshots, and Observation updates for keys and menu equivalents.

Before the timing run, baseline and candidate binaries also produced **exactly
matching full output receipts for 174,080 event/settings combinations**:
34 event shapes × 256 modifier combinations × two repeat states × ten settings
states. Every resolved action code, displayed key, menu equivalent/modifier,
and settings-operation result is retained and compared. The supplemental hash
is not the sole parity check. Every timed pair separately matches its checksum
and operation count.

The initial test-authoring pass caught Swift Testing errors from throwing event
creation inside assertion macros. Those test expressions were corrected to
evaluate events first; all four final runs use the same corrected test source.
A restricted Linux SwiftPM driver statistics path also required the integrated
driver option. These were validation-harness fixes, not production defects.

Independent reviews covered cache invalidation, definition-order semantics,
Observation dependencies, benchmark isolation, and the final numerical receipts.

## Native qualification and practical limits

The dedicated `shortcut-dispatch-performance.yml` workflow runs both versions'
debug and release component tests on macOS 26, then collects the same paired
benchmark with actual AppKit `NSEvent` objects and SwiftUI menu values. Direct
compiler invocations explicitly target macOS 26. The complete production
bindings file is compiled unchanged on macOS. The existing native lifecycle
workflow also includes the two shortcut suites in the full app/test dependency
graph.

The Linux results above were executed locally. Native results and exact tested
revision are recorded in the pull request's checks and the
`shortcut-dispatch-native` artifact. CI constructs events programmatically;
physical keyboard layouts, VoiceOver interaction, typing into live controls,
menu tracking, visible playback, and input-to-photon latency still require an
interactive macOS session. Passing these component tests alone does not certify
those end-to-end behaviors.

## Deferred opportunities

A separate exploratory track-ranking probe found avoidable repeated language
normalization during media-open selection, but its first candidate regressed
singleton catalogs with language preferences. It is not included here. A future
investigation should defer ranking a lone candidate and qualify native media-open
behavior before shipping. Runtime lease-history growth was also considered, but
changing historical diagnostics would require a broader lifecycle contract.

These candidates do not expand this PR's scope.

## Reproduction and retained evidence

See [benchmark instructions](../Benchmarks/ShortcutDispatch/README.md) and
[retained Linux evidence](../Benchmarks/ShortcutDispatch/evidence/linux).
The evidence includes all 200 rows, source/compiler/executable hashes, passing
test logs, exact verification output, and per-process receipts. Compressed files
are ordinary gzip streams with JSON/JSONL/text contents. `files.json` records
artifact sizes and SHA-256 hashes. Build products are regenerated by the runner.
