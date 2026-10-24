# Agent UI preference launch contract

The app implements this contract in `Sources/IlliquidApp/App/AppPreferences.swift`.
The runner must supply the variables below when launching a new owned benchmark
process. `CFFIXED_USER_HOME` alone is insufficient. This contract does not claim
live UI validation or a fresh system/LaunchServices environment.

## Required environment

For session token `S`, the launcher must set:

```text
CFBundleIdentifier (packaged identity): com.example.IlliquidBenchmark
ILLIQUID_ENABLE_BENCHMARK_OVERRIDES=1
ILLIQUID_BENCHMARK_CONTROL_SESSION=S
ILLIQUID_BENCHMARK_CONTROL_FILE=/absolute/run/state/control.json
ILLIQUID_BENCHMARK_SESSION_FILE=/absolute/run/state/session.json
ILLIQUID_BENCHMARK_PREFERENCES_SUITE=com.example.IlliquidBenchmark.AgentUI.S
ILLIQUID_BENCHMARK_PREFERENCES_RECEIPT=/absolute/run/artifacts/preferences.json
```

`S` is the existing control-session token, not the scenario name or an unrelated
run ID. It is 1–96 ASCII letters, digits, periods, underscores or hyphens. Reuse
of an existing preference suite is refused, including a suite first created
with an empty seed. Generate a fresh session for each launch. The app never
resets/removes a shared or run-specific preference domain.

All state-file paths must be absolute, distinct, and free of NUL bytes. The
receipt parent directory must already exist; the receipt must be absent. The
app publishes a complete receipt atomically using a same-directory hard link,
and refuses to overwrite an existing receipt, including a concurrent creator.
Initialization errors print `[agent-ui-preferences]` to stderr and exit 78.

Exact benchmark identity plus `overrides=1` and a control session requires the
whole isolation contract. Missing/invalid fields fail closed rather than
falling back to the shared benchmark preference domain. A normal production
bundle ignores all benchmark preference variables. A benchmark process without
a control session and without preference variables retains the existing
non-agent benchmark behavior; its preferences are **not** session isolated.

## Optional seed

```text
ILLIQUID_BENCHMARK_PREFERENCES_SEED_FILE=/absolute/run/state/preferences-seed.json
```

Omit it for fresh code defaults. A seed is a JSON object of at most 1 MiB,
containing only keys beginning `Illiquid.` or the existing app-owned
`player.shortcut-overrides.v1` key, and property-list-compatible values
(no JSON null, including nested null). The internal
`Illiquid.agent-ui-preference-suite.v1` reservation key cannot be seeded.
For example:

```json
{
  "Illiquid.controls-always-visible": false,
  "Illiquid.controls-position-locked": false,
  "Illiquid.interface-scale.v1": 90
}
```

Retain the exact seed bytes and their hash in the run manifest. The app hashes
the bytes it actually reads. This version supports JSON scalar/array/dictionary
seeds; it does not import binary UserDefaults history/source-tab payloads from
another domain. No implicit shared-preference import or legacy migration runs
for an isolated benchmark.

## App behavior and diagnostics

`BenchmarkSuiteDefaults` uses only its own seeded/written values and local
registration defaults. Typed getters, `dictionaryRepresentation`, and removal
cannot reveal the application, global, argument, or shared benchmark domains.
The adapter sends KVO and UserDefaults change notifications for AppStorage.
App-owned preference stores, AppModel's explicit reads/writes, AppDelegate,
startup history/source reads and both Window/Settings scenes use this adapter.
Playback-session persistence is explicitly injected with the required run-owned
session path, bypassing legacy-session migration for that path.

The explicit/default `.standard` audit covers all Swift sources: none remain in
the app target outside the resolver's normal production branch. The core
library retains its public injectable default arguments in
`PlaybackPersistenceStore` and `LegacyPreferencesMigration`; the app passes the
selected store and production migration is gated to the production bundle.
`IlliquidPlayer/Player/ArchitectureValidation.swift` creates its own validation
suite, independently of app startup. AppKit/SwiftUI framework state, system
permissions, LaunchServices defaults, and media files are outside the app-owned
preference domain guarantee.

The receipt contains:

- `schema_version: 1`, `session`, `suite`, PID, `isolation_mode: "session-suite-only"`,
  and `fallback_domains: []`;
- exact seed path, SHA-256 of seed bytes (both null when omitted), and seed values;
- `effective_initial_values`, sampled after initial sidebar preference setup,
  and `effective_initial_sha256`, the SHA-256 of that object's compact JSON
  encoding with sorted keys using Foundation JSONSerialization;
- the run-owned session path and an explicit initialization-only evidence scope.

The effective initial snapshot includes persisted initialization values and the
suite reservation key. Code-level defaults applied inside individual stores
without persistence are not materialized in this dictionary. A receipt proves
which store/seed initialized; it does not prove Settings rendering, interaction,
visible presentation, or preference durability across a crash. A separate live
Settings check is required to qualify scene observation/update behavior.

`effective_initial_canonical_json` is the exact JSON text whose UTF-8 bytes are
hashed. To verify across languages, parse that string and compare it to
`effective_initial_values`, then hash the string's exact UTF-8 bytes. Do not
re-encode it with Python and assume identical slash/Unicode/number encoding.

## Parent runner integration still required

The preference owner intentionally does not edit `agent_ui.py` (drag owner).
After that owner releases it, the parent must:

1. Derive the exact suite from `manifest["session_token"]` and supply the suite
   and absolute absent receipt path in the explicit launch environment.
2. Optionally copy a reviewed seed into the new run directory before launch,
   supply its absolute path, and retain bytes/hash. Do not inherit arbitrary
   `ILLIQUID_*` variables from the shell.
3. Retain suite, receipt path, seed identity, and effective hash in the manifest;
   read the app receipt and verify PID, session, suite, isolation mode and empty
   fallback list before reporting isolated readiness. A missing or mismatched
   receipt is a failed isolation check, not a fresh-defaults claim.
4. Preserve the receipt and errors on launch failure. Do not reset a domain or
   retry the same session. Attach to an existing process does not establish
   this isolation contract.

Run focused controls through Kyoto:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Scripts/agent-ui/tests/test_preferences.py
```

They compile only the production preference, chrome timeout and interface scale
sources and portable controls in a
temporary directory; fake domain access is polluted with shared values. They
exercise gates, seed validation, typed read/write paths, AppStorage binding,
no-fallback behavior, suite reuse rejection, hashes and atomic receipt refusal.
No product build, GUI input, profiler, or persistent userprefs mutation occurs.
