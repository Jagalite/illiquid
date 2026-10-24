# Player shortcut dispatch benchmark

This harness measures the production `PlayerShortcutBindings` implementation,
including its real `PlayerShortcutChord` parser/matcher, `PlayerKeyboardAction`
fallback, Foundation preferences, and Observation machinery. It compares the
current source against `main` at
`8c3cc3d4008d5d1b8d436bcf2d51d891382b6548`.

The optimization compiles the 25 ordered bindings when settings change and
replaces the repeated eight-entry navigation dictionary with a switch.

## Reproduce

Use the same Swift toolchain for `swift` and `swiftc`. The application and the
native component tests target macOS 26. The native workflow selects Xcode 26.6.

```sh
python3 Benchmarks/ShortcutDispatch/run.py test --configuration debug --output /tmp/shortcut-debug
python3 Benchmarks/ShortcutDispatch/run.py test --configuration release --output /tmp/shortcut-release
python3 Benchmarks/ShortcutDispatch/run.py benchmark --output /tmp/shortcut-benchmark
```

The test command defaults to testing **both** source versions. `--variant
candidate` or `--variant baseline` selects one. The isolated package copies both
the pre-existing shortcut tests and the new dispatch tests; it does not resolve
the full player's native dependency graph.
The temporary package adapts the initializer's `AppPreferences.defaults` default
to the legacy `.standard` dependency because it has no app/session context.
Source receipts record this separately from platform import adaptations;
dispatch logic and the pinned baseline remain unchanged.

The benchmark defaults to ten paired rounds and a base iteration count of
10,000. Each workload receives five AB and five BA pairs. Short paths multiply
that base count to improve timer resolution; the construction control caps it
at 500. Both members of each pair always use the same count. Exact arguments
and operation counts are retained per observation.

For a quick harness smoke check:

```sh
python3 Benchmarks/ShortcutDispatch/run.py benchmark --rounds 2 --iterations 500 --output /tmp/shortcut-smoke
```

Smoke timings are unsuitable for quoting a performance result. Regenerate the
summary from existing raw observations with:

```sh
python3 Benchmarks/ShortcutDispatch/run.py summarize --output /tmp/shortcut-benchmark
```

`SWIFTC` and `SWIFT` can select an installed compiler and package tool. Linux
toolchains may also need their normal runtime library search path. The runner
sets writable module caches without replacing `HOME`.

## What is measured

| Workload | Input |
| --- | --- |
| `head-hit` | Go to Time, the first editable binding |
| `seek-repeat` | Repeated Right-arrow seek |
| `late-hit` | Mute and inspector, near the end of definition order |
| `unmatched` | Two unassigned letter keys |
| `fallback` | Escape, handled by the fallback resolver |
| `modifiers` | Command/Control misses and an Option-arrow frame repeat |
| `question-layout` | `?` produced with Shift or Option and a different unmodified character |
| `mixed` | Seven navigation, transport, letter, unmatched, and fallback events |
| `cached-remap` | Six events after successful custom bindings, including old-key suppression and repeats |
| `construction` | Construct the bindings object, read all 25 displayed keys, and release it |

Events, the preference suite, successful remaps, and warmup are outside dispatch
timing. The construction control intentionally includes object creation and
destruction; its preference suite is prepared outside timing. It exposes the
work moved to initialization. It is not a measurement of cold process launch
or disk preference loading.

Every timed result contributes to an emitted checksum. Production code is
compiled as a separate optimized shared library, then linked by an independently
compiled optimized driver. No cross-module optimization or inlinable benchmark
copy of the dispatcher is used. This prevents a synthetic loop from exposing
the repeated input and production function body to one optimizer at once.

## Correctness and platform boundary

Before timing, separate binaries produce full, deterministic output receipts
for 174,080 event/settings combinations: 34 event shapes, 256 combinations of
modifier flags, two repeat states, and ten settings states. The receipts retain
every resolved action code, displayed binding, menu equivalent/modifier, and
settings operation result. Full receipts must compare equal; the supplemental
digest alone is not the acceptance check. Every timing pair must also agree on
operation count and output checksum.

The production tests provide independently stated expected behavior, including
immediate remapping, rejection, reset, saved conflict repair, ordering of
overlapping layout chords, per-instance preferences, and Observation callbacks.
The baseline is expected to pass: this optimization changes cost, not routing.

On **macOS**, the runner compiles the complete production bindings file without
modifying it and constructs real `NSEvent` objects with real SwiftUI menu values.
The action enum is extracted unchanged from `AppModel.swift`. The app-level
restoration workflow also includes these tests in the complete application
dependency graph.

On **Linux**, only the AppKit/SwiftUI imports are adapted, with their event and
menu value types supplied by `PlatformStubs.swift`. Foundation, Observation,
binding parsing, conflict handling, and dispatch are real. These results
qualify a component algorithm; they do not measure AppKit event delivery,
physical keyboard layouts, focus routing, VoiceOver, or visible playback.

## Evidence

Each run records raw process output, timing rows, environment, compiler and
source hashes, both executable/shared-library hashes, full parity receipts,
test logs, and summary statistics. The frozen baseline is checked against its
manifest. The runner rejects changes to the extracted fallback action enum so
a future comparison cannot silently mix two unrelated modifications.

The checked-in `evidence/linux` directory contains the publication cohort and
passing test logs. Full verification and process receipts are gzip-compressed
to keep the repository small; they are ordinary UTF-8 JSON/JSONL/text after
decompression. Build products are reproducible and are not committed.

See [the research report](../../Documentation/SHORTCUT_DISPATCH_PERFORMANCE.md)
for measurements, the construction/storage tradeoff, and native qualification
status. The dedicated macOS workflow uploads its receipts as
`shortcut-dispatch-native`.
