# Shuffled checkpoint identity reconciliation

## Result and qualification boundary

The complete ID-reconciliation expression used by shuffled checkpoints takes
about **48–49% less CPU time for ordinary unique playlists** on the measured
Linux x86_64 host. At 4,096 items, the unchanged-order case improves from
**23.612 ms to 12.081 ms** per call. The edited-playlist case improves from
23.997 ms to 12.220 ms. The duplicate-heavy control is effectively at parity.

[Portable CI run 40639666445](https://github.com/Jagalite/illiquid/actions/runs/40639666445) passed on 2026-10-28 with Swift 6.4,
Ubuntu 24.04, Linux 6.17.0-1022-azure, and four reported logical CPUs. Both
implementations passed **32 tests in five suites in debug and release**, with
warnings treated as errors. All 384 timing observations and 57 calibration
observations are retained.

These are **Linux Foundation component results**. At completion of this study,
the [macOS component and coordinator run](https://github.com/Jagalite/illiquid/actions/runs/40639377314)
had not started because its jobs were queued. No macOS timing, native app-graph
test, live playback, or visible UI result is claimed. Consult the PR checks for
the current native status; the PR is initially a draft pending native validation.

## Why this path

While shuffle is enabled, the main-actor
[checkpointSession](../../Sources/IlliquidPlayer/Player/PlaybackController.swift)
path reconciles the saved base order. Position progress of at least ten seconds,
pause changes, playlist edits and lifecycle operations can reach checkpoints,
subject to the existing authority and history guards.

The old checkpoint expression is:

```swift
PlaylistMutation.restoringOrder(
    state.playlist, ids: unshuffledPlaylistIDs ?? []
).map(\.id)
```

With a saved order, this constructs a dictionary and result array of complete
playlist items, then immediately discards those items and recomputes their IDs.
The new
[restoringIDs](../../Sources/IlliquidCore/Playlist/PlaylistMutation.swift)
helper works directly with a Set and arrays of IDs. The existing item-returning
restoration operation still serves actual unshuffle operations.

For N current entries and U unique identities, ordinary reconciliation changes
N + U identity evaluations to N. The baseline's singleton with an empty saved
order already evaluates its identity once; the new singleton fast path does too.
Empty input avoids all identity work. With an empty saved order and multiple
entries, the new path also avoids the second normalization pass, although the
baseline does not construct the same full-item dictionary in that case.

The implementation preserves the first current identity's exact UTF-8 spelling.
A saved decomposed Unicode string can compare equal to a composed current path;
returning the value removed from the Set preserves the current spelling.
Removed and repeated saved IDs disappear, surviving IDs retain saved order,
and additions retain current order. There is no persistent cache, invalidation
state, filesystem lookup, actor change, or persistence schema change.

The full current playlist is still passed to the checkpoint writer and saved in
the session record. This change optimizes only preparation of its unshuffled IDs.

## Measurements

Each row uses 12 fresh-process baseline/candidate pairs with balanced AB/BA
order. CPU medians are per complete expression, including the same lightweight
output consumer. Reductions use the median **paired candidate/baseline ratio**,
which can differ from the ratio between the two displayed medians.

The last column is the deterministic bootstrap 95% interval for that median
paired ratio; 1.0 means parity. It describes sampling variation on this host,
not variation across machines, toolchains, or platforms.

| Input entries | Unique IDs | Case | Baseline CPU (ms) | Candidate CPU (ms) | Paired CPU reduction | Ratio interval |
| ---: | ---: | --- | ---: | ---: | ---: | --- |
| 0 | 0 | Saved order, reversed current queue | 0.000010781 | 0.000006594 | 39.5% | 0.588–0.616 |
| 1 | 1 | Saved order, reversed current queue | 0.005150 | 0.002438 | 52.8% | 0.468–0.479 |
| 1 | 1 | Empty saved order | 0.002445 | 0.002424 | 0.6% | 0.986–0.995 |
| 16 | 16 | Saved order, reversed current queue | 0.081746 | 0.042431 | 48.1% | 0.515–0.523 |
| 16 | 16 | Empty saved order | 0.079086 | 0.040955 | 48.0% | 0.514–0.525 |
| 256 | 256 | Saved order, reversed current queue | 1.341869 | 0.698171 | 47.9% | 0.519–0.523 |
| 256 | 256 | Removed entries and appended additions | 1.342741 | 0.700620 | 47.6% | 0.515–0.526 |
| 512 | 256 | Repeated current and saved entries | 1.995100 | 1.346739 | 32.4% | 0.673–0.680 |
| 256 | 256 | Empty saved order | 1.291934 | 0.671941 | 47.9% | 0.516–0.523 |
| 256 | 256 | Long Unicode paths | 4.483970 | 2.759201 | 38.5% | 0.606–0.618 |
| 4,096 | 4,096 | Saved order, reversed current queue | 23.611639 | 12.080925 | 48.7% | 0.500–0.523 |
| 4,096 | 4,096 | Removed entries and appended additions | 23.996627 | 12.220224 | 49.3% | 0.494–0.515 |
| 8,192 | 4,096 | Repeated current and saved entries | 35.381751 | 23.211719 | 34.5% | 0.646–0.662 |
| 4,096 | 4,096 | Empty saved order | 22.359780 | 11.622019 | 47.9% | 0.518–0.527 |
| 4,096 | 4,096 | Long Unicode paths | 75.691644 | 46.082716 | 39.0% | 0.603–0.616 |
| 4,096 | 16 | Duplicate-heavy control | 10.773690 | 10.690145 | 0.2% | 0.982–1.011 |

Wall-clock paired results agree: the largest CPU-versus-wall difference in
median paired reduction is below 0.05 percentage points. All wall observations,
ratios and intervals are retained in the results file.

The ordinary 16-item result is an absolute saving of about 39 microseconds per
reconciliation. Large percentages on the empty control correspond to only a few
nanoseconds and are not an application performance claim. The singleton with
empty saved order is near parity. For 4,096 entries containing only 16 unique
IDs, the paired ratio is 0.998 with an interval spanning 1.0; no meaningful gain
is established for that control.

The duplicate cases have twice the nominal base size in current entries and
twice the base size plus two in saved entries. The edited cases remove every
fourth original entry and append the same number of new entries. Ordinary
fixtures use already normalized local URLs; the Unicode cases deliberately
stress long paths.

## Correctness

The new test suite exhausts **41,261** current/saved sequence combinations using
an independent integer-label oracle. It also checks explicit expectations for:

- Empty and singleton queues, duplicates, removed entries and additions.
- Successive edits while shuffled.
- Saved strings being compared as keys rather than reinterpreted as URLs.
- Decoded local aliases that bypass the normalizing item initializer.
- Unsupported local URL forms retaining their existing absolute-string fallback.
- Distinct remote query strings and fragments.
- Saved NFD/current NFC identities, compared byte for byte.

The same tests run against the old expression through CHECKPOINT_BASELINE.
Candidate tests additionally compare with the original expression. Existing
full-item restoration, filename-ordering and playlist tests also run. Every one
of the 16 benchmark fixtures passes complete ordered UTF-8 equality against an
independent rank-based oracle in both variants and both build configurations.

A new coordinator integration test covers shuffled removal, append, checkpoint,
shutdown, relaunch and unshuffle through public operations and the existing
fake playback backend. It checks saved base IDs, the complete saved current
playlist, selection and source. Shutdown joins persistence work, avoiding a
debounce timing assumption. **That native test was added but remains unexecuted
in this study while macOS CI is queued.** It is not included in the passing
component test count.

## Method and evidence

The pinned baseline is ea2ff568237e2667f7b1aeee67b11a44ebe95b72.
The measured candidate is e526b1335d6371f2f3c71301628eab5d112bb4ca.
Subsequent evidence/documentation changes do not alter the measured production
sources, tests, harness or runner.

Four exact production core files are compiled into a separate IlliquidCore
module. The timing caller imports that module, matching the production
core/player boundary. No model or rewritten URL implementation replaces
production code, and the app package and dependency locks are unchanged.

Fixture construction, complete output equality and full UTF-8 checksums are
outside timing. Every timed process validates its complete output before and
after measurement. A noninlined iteration consumes a rotating output element
and releases the returned Swift array before returning a scalar checksum.
The loop's checksum is also validated against independently expected outputs.

A common iteration count is calibrated toward 150 ms of CPU time for the slower
variant, capped at 2,000,000 iterations. Faster candidates can therefore have
shorter measurement intervals. Zero-duration pilot samples are allowed to
increase their iteration count; final measured samples require positive CPU and
wall time. Calibration observations are retained separately from paired samples.
The initial native-only run was cancelled while still queued to apply that
calibration robustness fix; it produced no measurement cohort.

Each timed iteration consumes and releases the returned Swift ID array. The
benchmark does not instrument Foundation's internal temporary-object lifetimes
or explicitly drain a Darwin autorelease pool after each call. These repeated
component calls do not measure allocation counts, peak or retained memory, RSS,
full event-loop cleanup, complete persistence-checkpoint latency, energy use,
or visible UI/playback performance.

Retained evidence:

- [All results, samples, calibration and source/test/binary receipts](evidence/results-linux-swift-6.4.json).
- [Decoded CI job log with the complete structured receipts](evidence/portable-component.log).
- [Independent receipt audit](evidence/audit.json).
- [Original Actions artifact](https://github.com/Jagalite/illiquid/actions/runs/40639666445/artifacts/12795550548), including exact staged sources,
  fixture outputs and complete build/test logs; it has the workflow's 30-day
  retention and is supplementary to the committed records.

The receipt audit independently recomputed every full and timed checksum,
verified source/test/caller Git blob hashes against the repository, checked all
384 samples and paired execution orders, and recomputed every median and paired
ratio. The bootstrap implementation was reviewed and interval bounds checked;
its Python MT19937 resamples were not independently regenerated. No timing
samples or completed benchmark attempts were discarded.

## Reproduction

Ensure the pinned baseline commit is available in local Git history. Hosted
workflows use a full-history checkout. Use the shared Kyoto queue when available:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/CheckpointIdentities/run.py \
  --pairs 12 --target-ms 150 --output /tmp/checkpoint-identities
```

Inspect Kyoto show, logs and wait before reporting a result. On a host where
Kyoto is unavailable, explain the limitation and run the same Python command
directly. Both hosted workflows record its absence before compiling isolated
packages serially. Output directories must be new or empty to preserve attempts.

For the focused production regression suite:

```sh
bash Scripts/test-playlist-restoration.sh
bash Scripts/test-playlist-restoration.sh -c release
```

The macOS workflow additionally prepares the repository's pinned native SDK and
builds the full app graph for the new coordinator regression and the two adjacent
shuffle/restoration tests. Those checks remain a native qualification gate.

## CI whitespace comparison

Both component workflows run `Scripts/check-ci-whitespace.py` before qualification.
For pull requests it resolves the event's exact base/head commits and checks the
merge-base-to-PR-head diff, excluding unrelated base-branch history. Push and
manual runs resolve the repository's default remote branch and compare its merge
base with the checked revision. Runs on the default branch compare the push's
previous commit (or the current commit's parent for manual/new-branch events).
Missing refs fail rather than silently falling back to the historical benchmark
baseline. Full-history checkout supplies these objects without script fetches.

The separate uploaded `*-whitespace.json` receipt records the checkout, event,
requested/resolved base, merge base, comparison head, command, output and exit
status. The script adds no path filters or whitespace-attribute overrides; it
uses the existing repository whitespace policy. Changed-line violations still
fail. Existing evidence logs, attributes and benchmark baseline are unchanged.
For a local check, pass an explicit base, for example:

```sh
python3 Scripts/check-ci-whitespace.py --base 8e51176463b873cca080d92d9c4854a1d078be35 \
  --output /tmp/checkpoint-identities-whitespace.json
```

## Integration regression qualification

Push and pull-request component jobs use `--regression-only`. This runs the
same five test files and all 16 exact-output fixtures in debug and release for
both variants, with no calibration or timing. The baseline compiles the pinned
historical `PlaylistMutation.swift` verbatim, and `CHECKPOINT_BASELINE` retains
`restoringOrder(...).map(\.id)`. Both variants compile identical captured current
bytes for the other three supporting sources. The runner checks all four
current source SHA-256 pins before staging the regression cohort; changed pins
require a source review. It retains full historical sources and source hashes,
records each variant's source origin, and labels completion as
`current-support-regression` with `performance_measured: false`.

Default and manual workflow-dispatch runs retain the historical comparison and
strict unchanged-support guard. They reject current support drift rather than
turning regression qualification into performance evidence. Historical native
measurements apply only to their recorded source cohort. Run
`python3 -B Scripts/tests/benchmark-source-policy-tests.py` for noncompiling
source-policy controls. Local Swift qualification must still use Kyoto.
