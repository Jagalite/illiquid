# Statelessness migration status

Status: **migration implemented on branch `statelessness/migration-phase0`**,
prepared 2026-11-01 against [the migration plan](../STATELESSNESS_SWIFT_MIGRATION.md).
Playback verification runs only on the native Swift Statelessness engine,
pinned to `3fbdca7c49be3cf32da613f887a7f149e0b97087`. The custom traversal,
reduction loops, SCC analyzer, minimizer and replay loop have been deleted.
The frozen explorer remains reproducible from its git revision and the
immutable fixtures below.

Statuses are kept distinct: source review, compiled, executed tests, bounded
search, native integration, live UI and release qualification. This migration
establishes verification behavior only. It is not native playback, UI, or
release qualification.

## Architecture after the migration

| Component | Owner | Location |
| --- | --- | --- |
| Production transitions | `IlliquidPlaybackCore` | `PlaybackCore.update(_:)` (unchanged) |
| Model adapter (`step` = `apply`, at most one core call) | Illiquid | `PlaybackModelTransitions.swift`, `Statelessness/PlaybackStatelessnessModel.swift` |
| Seeds and enabled actions | Illiquid | `PlaybackSearchModels.swift` (unchanged) |
| Search identity (semantic quotient) | Illiquid | `PlaybackSearchCanonicalizer.swift` (unchanged) |
| Codecs (lossless executable state, inputs, observations) | Illiquid | `Statelessness/PlaybackModelCodec.swift`, `CanonicalJSONEncoder.swift` |
| Progress predicates and ranks | Illiquid | `Statelessness/PlaybackProgressPolicy.swift` |
| Reduction eligibility, projection and diamond candidates | Illiquid | `Statelessness/PlaybackReductionPolicy.swift` |
| Provenance envelope, legacy converter, runtime promotion | Illiquid | `Statelessness/PlaybackVerificationArtifact.swift` |
| Acceptance (trend baseline, records, exit codes) | Illiquid | `PlaybackSearchTrend.swift`, `Statelessness/PlaybackVerifier.swift`, CLI |
| Graph search, failure collection, coverage | Statelessness | `exploreGraph` (S1/S2) |
| SCC, reverse reachability, closed components | Statelessness | `analyzeProgress` (S3) |
| Reduction, diamonds, reduced/unreduced comparison | Statelessness | `EquivalenceReduction`, `validateDiamonds`, `compareReduction` (S4) |
| Recording, replay, shrinking | Statelessness | `recordContinued`, `replayContinued`, `shrink64`, `shrinkContinued` (S5) |

## Phase gates

| Phase | Exit gate | Evidence |
| --- | --- | --- |
| 0 Freeze | Baseline reproducible; consumed package buildable | Legacy oracle manifest [legacy-oracle-ea2ff568.json](legacy-oracle-ea2ff568.json) (30 files, aggregate `50314d31…`). Inventory fixture. Legacy PR run on all 40 seeds (Kyoto `66a19f83…`, exit 0). Upstream pin qualification `20261101-illiquid-pin-3fbdca7`: external consumer ok, 732 tests, 0 failures. Full Illiquid package builds with the pin |
| 1 Upstream foundation | S1/S2 semantics tested; S5 witness design agreed | Upstream PR #14 at the pin, with its own contracts and fixtures. No Illiquid change |
| 2 First model | Seek agrees at small bounds; controls and fresh-process replay pass | Strict edge-by-edge parity. Versioned deterministic codec. Fresh-process replay (Kyoto `bb6699da…`→`efabdb81…`, and CLI `539a5b26…`) |
| 3 All families | All inventories; small-bound graph and failure parity | All 40 seeds in strict parity at validation depth 5, and at PR bounds (Kyoto `49fa2831…`) |
| 4 Remaining machinery | Progress, POR, replay/shrink, legacy conversion | Progress identical to the frozen analyzer for every seed. Conservative and validation POR match the frozen reducer on states, digest, reduced edges, diamonds, failures and progress (Kyoto `c9ac1f5a…`). `compareReduction` reports equivalence. Native `shrink64`/`shrinkContinued`. Legacy v1 artifact converted and replayed |
| 5 Default switch | All PR seeds qualify; nightly/qualification receipts; no unexplained differences | CLI and runner use Statelessness only. PR runner (Kyoto `2d246e11…`) matches the frozen legacy PR receipt exactly on all 40 seeds. Nightly and qualification have explicit receipts, both timed and untimed. Qualification under reduction policy v2 (Kyoto `b0659006…`) has 0 findings and 0 undeclared noncommuting diamonds (D29 resolved). The remaining incomplete seeds (D23) stop at a reviewed deadline, transition cap or graph-memory budget, never silently; the frozen explorer stops on the same seeds. Coverage is not claimed for them |
| 6 Retirement | Sole active path is Statelessness; history accessible | Legacy algorithms and the old `PlaybackSearchResult` family deleted. Golden fixture recorded from the frozen engine replaces it as the comparison oracle |

## Evidence chain

1. **Strict parity while both engines existed.** A comparator, deleted in
   Phase 6, rebuilt the legacy edge sequence and compared every edge: concrete
   action, full observation (disposition, ordered effects, snapshot,
   envelope, violations, fairness), Statelessness disposition, checks and
   target. It also compared admitted nodes with their predecessors, coverage
   and expansion, findings with witnesses, and the cap policy. All 40 seeds
   matched at validation depth 5 and at PR bounds.
2. **Progress and POR parity** against the frozen analyzer and reducer for all
   40 seeds, in both POR modes (job `c9ac1f5a…`).
3. **Golden fixture.**
   [statelessness-migration-golden-v1.json](../../Tests/IlliquidPlaybackStateSpaceTests/Fixtures/statelessness-migration-golden-v1.json)
   was recorded in the same job, only after strict parity passed. It holds
   per-seed legacy counters, canonical digest, progress, reduced-run
   counters, and the SHA-256 of the canonical Statelessness edge sequence.
   The legacy v1 artifact fixture was written by the frozen artifact builder
   and replayed by the frozen replayer in that job.
4. **After retirement**, `everySeedMatchesTheGoldenEvidence` re-derives all of
   this from the Statelessness engine alone. Negative controls must break it:
   - dropped transition
   - identity merged by lifecycle
   - stale ingress treated as current
   - forced `accepted` disposition
   - omitted observed effects
   - suppressed checks
   - false progress classification
   - pruning reduction, caught by `compareReduction`
   - corrupted, truncated, incompatible or retargeted artifacts
5. **Frozen legacy PR receipt.** The production runner's PR records match it
   field for field (job `2d246e11…`).

The oracle's sources remain at `ea2ff568`, and their hashes are in the
manifest. Replaying an artifact under old semantics requires that historical
checkout. No alternate engine remains in active code.

## Receipts

Kyoto job records and logs (progress lines removed; full-log SHA-256 kept)
were saved with
[save-kyoto-receipt.py](../../Scripts/statelessness-migration/save-kyoto-receipt.py):

- [receipts/phase0-20261101](receipts/phase0-20261101): jobs 01–10, Phase 0
  through PR-bound parity
- [receipts/migration-20261101](receipts/migration-20261101): jobs 11–49,
  Phases 4–6: profile runs (timed and untimed), legacy comparisons,
  full-package tests and the diamond probe. Untimed runs keep per-seed
  summaries (`*.summaries.json`) and provenance
- Copies of the PR qualification records, provenance, the CLI-written
  artifact and the converted legacy artifact

Failed jobs are kept:

- 01: the missing baseline (D1)
- 05: the host `dlopen` failure (D2)
- 03, 12, 17: compile errors that were fixed
- 15: three control-test defects
- 19: the PR deadline before the optimization (D19)
- 26: nightly, exit 2 (incomplete seeds, D23)
- 27: `DYLD_LIBRARY_PATH` stripped by `/usr/bin/env` (D2)
- 29: qualification, exit 1 (D29) and incomplete seeds (D23)
- 38, 45, 46, 47: exit 2, incomplete seeds only (D23)
- 39, 40, 42: runs whose build raced a source edit, cancelled or discarded
- 41: the runner's zsh `status` variable (D31)
- 43: the progress crash at the graph budget (D30)

Job 48 is the full-package run of the state-space suite on the finished tree
(55 tests, 0 failures) with the D2 workaround. Job 49 repeats it with plain
`swift test` after the D2 relink: 55 tests, 0 failures.

## Profile runs

| Profile | Kyoto job | Outcome |
| --- | --- | --- |
| PR | `2d246e11f9cd47029ff92205ba52a119` | Exit 0, 207 s, peak RSS 771 MB. 40/40 finished (18 exhaustive, 22 depth-bounded), no findings, no trend violations; identical to the legacy receipt |
| Nightly | `e2575b3ddbf84dd881708cfa1d9ed5e7` | Exit 2 (incomplete), 1,703 s, peak RSS 2.2 GB, 0 findings. 37/40 finished (22 exhaustive, 15 depth-bounded). `seek/seek-in-flight`, `recovery/recovery-in-flight` and `preroll-buffering/playing-av` reached the 300 s per-seed deadline and are **incomplete, not covered** (D23). Built from the source before the final review fixes (D24–D28), none of which change search results. |
| Qualification | `965c5ad53a6b4579a9d8b7fdaa7afc20` | Exit 1, 8,190 s, peak RSS 3.1 GB. Validation POR: 2.33 M diamonds validated, 0 findings, no stuck states or closed components. 35/40 finished (27 exhaustive, 7 depth-bounded). Five seeds reached the 600 s deadline (**incomplete**): `seek/seek-in-flight`, `recovery/recovery-in-flight`, `track-subtitles/embedded-selected`, `preroll-buffering/playing-av`, `preroll-buffering/playing-format`. The exit 1 comes from 167,297 noncommuting diamonds on `preroll-buffering/playing-av` (D29), which the frozen explorer reports too. |
| Legacy comparison, nightly | `ef62157961224338b511a57cd0e60619` | Frozen explorer from a clean `ea2ff568` checkout, run on the three nightly deadline seeds: all three also reach `timeBudgetReached`, at 143,027 / 166,884 / 96,494 states (Statelessness: 144,672 / 165,069 / 110,915). The deadline is not a migration regression |
| Legacy comparison, qualification | `9e2ce67e88094c2293335128feb025ef` | Frozen explorer on `preroll-buffering/playing-av` at qualification bounds: `timeBudgetReached`, 48,364 states, 333,110 diamonds validated, **38,240 noncommuting**. Legacy qualification fails on the same diamond class |
| Qualification, policy v2 | `b0659006ae7b4af7bf54f3517a9cf047` | Exit 2 (incomplete only), 8,093 s, peak RSS 2.7 GB. 0 findings, 0 trend violations, **0 undeclared noncommuting diamonds**; declared-dependent queue diamonds are reported separately (D29). 35/40 finished. The same five seeds reach the 600 s deadline (D23) |
| Nightly, untimed | `a3c9f9e4be9f4c0f8af5ad3429b98c70` | The three nightly deadline seeds with `--time-limit none`, 1,838 s, peak RSS 2.6 GB. `preroll-buffering/playing-av` **finishes** (depth-bounded, 142,636 states, 0 findings). `seek/seek-in-flight` (274,572 states) and `recovery/recovery-in-flight` (331,738) reach the 3 GiB graph budget: incomplete |
| Nightly, untimed, 6 GiB graph | `e429eb503e3e4fb0add2ebfe01073618` | The same two seeds with a 6 GiB graph budget, 2,132 s, peak RSS 3.0 GB. Both reach the nightly profile's 5,000,000-transition cap (334,726 and 445,612 states), 0 findings: incomplete by profile cap, not by host memory |
| Qualification, untimed | `c52f2b6f631645ce9bbc470685aae686`, `33dca0a60a6e435ab1024bb12c1d3a11` | Untimed qualification of the deadline seeds, peak RSS 3.1 GB. All reach the 3 GiB graph budget with 0 findings: `seek-in-flight` 305,622, `recovery-in-flight` 332,492, `playing-av` 210,001, `playing-format` 224,041, `embedded-selected` 238,166 states (the last in job 43, before the D30 fix) |
| Full package tests | `5ea8447912c64404a6906fd28b456897` | `swift-test --filter IlliquidPlaybackStateSpaceTests` in the full Illiquid package, with pinned `swift-testing`: 51 tests, 0 failures. Run with `DYLD_LIBRARY_PATH=/opt/homebrew/Cellar/x265/4.2/lib`, launched without `/usr/bin/env` (job 27 shows SIP stripping the variable through `env`) |

## Cost

Budgets per profile are recorded in
[PLAYBACK_STATE_SPACE_COST_BUDGET.json](../Baselines/PLAYBACK_STATE_SPACE_COST_BUDGET.json),
measured from the runs above (PR 300 s / 1.5 GB, nightly 2,400 s / 4 GB,
qualification 10,800 s / 6 GB of runner wall time and RSS). They are resource
limits for scheduling, not acceptance criteria. They were measured on a shared
8 GB host, so they are upper bounds rather than isolated measurements.

On the same host and the same workloads, sequential and untimed, the strict
parity run measured 209.0 s for the legacy engine and 238.3 s for
Statelessness at PR bounds. That run predates the lazy pre-transition key
(D19). The production PR runner now takes 207 s, against 203 s for the frozen
legacy runner. The per-seed budget that matters is
`recovery/recovery-in-flight` against the 60 s PR deadline. Timing on this
shared host varies by about 25 %. Before D19 the seed overran (job `7ad547f2…`,
`incomplete(deadline)`); after it, the seed finished. That seed is close to
its budget for both engines; an isolated (dedicated-host) measurement would
tighten the budgets above. The fix belongs in seed splitting or a reviewed budget change, not in
relaxing acceptance. Peak memory comes from Kyoto's process sample (771 MB for
the PR runner). Graph bookkeeping is capped by
`ILLIQUID_STATE_SPACE_MAX_GRAPH_BYTES` (default 3 GiB).

## Discrepancy register

Categories: **defect** (fixed), **format** (lossless mapping), **semantic**
(reviewed change), **environment**, **evidence limit**.

| ID | Category | Finding | Disposition |
| --- | --- | --- | --- |
| D1 | defect (legacy, resolved) | The runner required `Documentation/Baselines/PLAYBACK_STATE_SPACE_PR_BASELINE.json`, which had never been committed, so the default PR runner trapped. | The baseline is now derived mechanically from the frozen legacy PR receipt (40 entries, 25 % tolerance). The runner fails clearly if it is missing. Review it as a baseline change. |
| D2 | environment (resolved 2026-11-01) | The full test bundle could not `dlopen`: Homebrew's stock `ffmpeg 8.1.2` keg linked `/opt/homebrew/opt/x265/lib/libx265.216.dylib`, but the `opt` link had moved to `x265 4.3`, which provides `.217` (an ABI-incompatible build number). | With the owner's approval, the stock keg's four libraries and twenty tools were relinked to the installed `x265 4.2` keg (`install_name_tool`, ad hoc re-signing; originals and hashes backed up outside the repository). That matches the reviewed native lock, which pins `x265 4.2`. The reviewed `8.1.2-illiquid1` keg is untouched. `swift test` now runs without `DYLD_LIBRARY_PATH` (job 49). Homebrew `cleanup` must not remove `x265 4.2`. |
| D3 | semantic (improvement) | At the state cap the legacy explorer counted the edge but discarded its violations. Statelessness records the finding and a `rejected(state_limit)` edge. | Kept; tested (`stateCapEdgeFindingIsReported`). A cap hit is incomplete evidence. |
| D4 | format | Legacy `completeWithinBounds` merged depth cutoff and exhaustion. | Records keep `termination`, `coverage` and `completeWithinBounds` separately. |
| D5 | semantic | Deadlines are polled per Statelessness callback instead of per legacy layer and edge. | A timeout is `incomplete(deadline)` in records and exit code 2. |
| D6 | format | Legacy failures were deduplicated by `name\|details`. | Statelessness counts every finding and keeps witnesses with visible retention. Artifacts are built per failed property, and any unretained property fails the record. |
| D7 | semantic (benign) | Statelessness enumerates inputs at depth-limit nodes to classify them. | `enabledActions` is pure, with no production calls. This is a cost item. |
| D8 | defect (legacy, resolved) | `iterativeDeepening` was declared but never implemented. | Removed from `PlaybackSearchAlgorithm`. |
| D9 | resolved | POR modes were not migrated (Phase 0). | Migrated through `EquivalenceReduction` and `validateDiamonds`, with parity in both modes. |
| D10 | evidence limit | There are no state properties, and the initial seed is not checked. | Unchanged from the legacy explorer. A new state property is a separately versioned property change. |
| D11 | format | The legacy `noCore` path merged environment steps and actions that materialize no event. | Observation `kind` distinguishes them, and Statelessness dispositions summarize it. |
| D12 | resolved | There was no deterministic state codec. | `PlaybackModelCodec` v1 over canonical JSON: lossless executable state, sorted unordered collections, non-finite numbers rejected. |
| D13 | evidence limit | Parity used the same `apply` in both engines, so it proves the traversal and evidence carriage are faithful, not that `apply` is correct. | Independence comes from the manifest hashes, the counters, digest and progress anchored to legacy, and the negative controls. `apply` changed only by D19. |
| D14 | resolved | Progress, shrinking, replay and legacy conversion were not migrated (Phase 0). | Migrated as described under Phase 4. |
| D15 | resolved | The early test runs used the toolchain's Swift Testing in the focused package. | Re-run in the full package with the pinned `swift-testing` (job 30): 51 tests, 0 failures. |
| D16 | defect (test, fixed) | The dropped-violation control passed for the wrong reason. | Fixed. Found by the gpt-6.1-sol review. |
| D17 | defect (fixed) | The first comparator was too coarse. | Replaced by the strict comparator before any evidence was accepted. Found by the gpt-6.1-sol review. |
| D18 | evidence limit | Receipts contain local absolute paths and the host user name. | Review before publishing. |
| D19 | performance (fixed) | `apply` built the pre-transition search key for every action but used it only for stale transitions. Statelessness then overran the 60 s PR deadline on `recovery/recovery-in-flight`. | The key is now derived lazily from the unmodified input. The key excludes depth, so it is identical. Golden edge digests are unchanged. |
| D20 | semantic (documented) | Legacy minimization accepted a candidate if any step violated the property. Native shrinking requires the selected failure to end the witness, and `shrinkContinued` handles witnesses that cross earlier failures. | The plan's intended semantics. Causal validity is unchanged: a result must name an outstanding effect. |
| D21 | semantic (documented) | With POR, Statelessness still executes and counts reduced edges (`edgeCount` includes them; `graphEdgeCount` does not). The legacy reducer dropped them before execution. | Reachable states, digest, findings and progress are identical. The PR baseline is unreduced, so trend counts are unaffected. |
| D22 | semantic (documented) | Unmeasured nodes are now defined by expansion status, not by depth ≥ limit. Closed components with an unmeasured member are excluded and counted. | Classes were identical to the frozen analyzer for every seed. The new definition also covers caps and deadlines correctly. |
| D23 | evidence limit (pre-existing; accepted by the owner 2026-11-01) | Three nightly and five qualification seeds reach their per-seed deadlines. The frozen explorer reaches the nightly deadline on the same three seeds at comparable state counts. Untimed reruns (jobs 43 and 45–47): nightly `playing-av` finishes; the other two nightly seeds reach the nightly transition cap even with a 6 GiB graph budget; the five qualification seeds reach the 3 GiB graph budget, the practical limit on this 8 GB host. No run found a violation. | Resolved by explicit declaration: the owner chose to keep these seeds as documented bounded evidence rather than split them or change caps. Each run reports `incomplete(<reason>)` with exit 2, and nightly/qualification coverage is declared for every other seed only. Covering them later needs seed splitting (model-version bump) or a larger host. |
| D24 | defect (fixed) | Artifact replay did not bind traces to the named seed or the original witness: replay starts from the trace's embedded initial state. | Both traces' initial states must equal the encoded seed, and both witnesses must equal their traces. Tests: seed swapped, original witness replaced. Found by the gpt-6.1-sol final review. |
| D25 | defect (fixed) | `--resume` kept the stored trend result instead of evaluating the baseline supplied to the current run. | Resumed records are re-evaluated and rewritten. Tested at library level. Found by the gpt-6.1-sol final review. |
| D26 | defect (fixed) | Runner provenance skipped deleted files. | Every `git status` entry is recorded, with `deleted` for missing paths and rename handling. Found by the gpt-6.1-sol final review. |
| D27 | defect (fixed) | Canonical JSON gave different bytes for Swift-equal strings (NFC/NFD) and for `0.0`/`-0.0`. | Strings and keys are written in NFC and zero is normalized; decoded values are equal to the originals. Tested. Found by the gpt-6.1-sol final review. |
| D28 | defect (fixed) | `PlaybackVerificationRecord.passed` ignored completeness. | `passed` requires a finished search. `clean` covers findings only, and the CLI maps it to exit 1, with incompleteness as exit 2. Tested. Found by the gpt-6.1-sol final review. |
| D29 | resolved (reduction policy v2) | Validation POR reports noncommuting `queue.<stream>.consume × queue.<stream>.offer` diamonds on `preroll-buffering/playing-av`. Offer and consume do not commute at queue bounds (for example, full then consume then offer ends `full`, but full then offer then consume ends `partial`). The frozen reducer reports exactly 296 of 3,320 at validation depth 5 (golden fixture) and 38,240 at qualification bounds. | These actions are diamond candidates but are never reduced (only `wrongOperation` results are), so no unsound pruning results. Reduction policy v2 (`PlaybackReductionPolicy.version = 2`) declares same-stream offer/consume pairs dependent (`isDeclaredDependent`). Their diamonds are counted as `declaredDependentDiamondCount` and do not fail validation; any other noncommuting pair still does. Tests check that undeclared plus declared equals the golden count and that an undeclared pair fails. Qualification under v2: 0 undeclared (job 38). |
| D30 | defect (fixed) | When a seed reached the graph budget, Statelessness dropped edges, and `analyzeProgress` threw `progress analysis requires retained edges`; the untimed qualification crashed (job 43, exit 133). | `PlaybackProgressPolicy.graph` builds the progress graph from the retained report and marks unexpanded nodes as unmeasured. Tested with a graph budget that forces `edgesRetained = false`. |
| D31 | defect (fixed) | The seed-selection loop in the runner assigned zsh's read-only `status` (job 41). | Renamed to `result`. |
| D32 | defect (fixed) | The runner aggregated per-seed exit codes with a maximum, so incompleteness (2) hid a finding (1). | A finding or usage error now outranks incompleteness. |
