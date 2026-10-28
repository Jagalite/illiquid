# Source visibility root lookup

This experiment measures preparation of source-root lookup data in the real
source-browser projection. The baseline is `main` at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.

## Change and relevance

`SourceVisibilityMatcher` finds the longest configured root containing a row's
path. Flat-row construction uses the result for relative labels, and visibility
evaluation uses it for regex candidates and ancestor boundaries. The original
lookup filters the complete root array, reconstructs descendant prefixes and
selects the longest match by character count. It repeats this work across rows
and ancestor evaluations.

The candidate prepares each normalized root's path, descendant prefix and
character count once. An ordered loop selects the first longest match without
the temporary filtered array. Relative-path construction and ancestor checks
reuse the prepared count and prefix. The root order, filesystem-root handling,
Unicode string operations, regex rules and inheritance behavior are unchanged.
There is no mutable cache or invalidation policy.

Preparation has a cost and retains an additional prefix per configured root.
The experiment measures that setup cost explicitly. It makes no allocation,
resident-memory, energy or whole-player performance claim.

## Criteria fixed before measurement

The primary workloads are complete cold `.filesOnly` projections with 8 and 32
disjoint roots and 1,024 entries. Each uses one enabled visibility rule that
hides 64 trailer entries. The experiment should achieve at least a 5% median
paired process-CPU reduction in both primary workloads, with the candidate
faster in at least 8 of 10 pairs.

All controls remain in the report. A common control is flagged as a material
regression when it is slower in at least 8 of 10 pairs and the median increase
exceeds both 5% and 0.05 ms per operation. The absolute threshold prevents a tiny
setup difference from dominating a percentage comparison; setup-only results
are still reported in microseconds. These are research decision criteria, not
timing assertions in CI. Correctness is required independently of performance.

## Workloads and timing boundaries

| Workload group | Measured operation |
| --- | --- |
| Primary: 8 and 32 roots, 1,024 files | Complete cold browser projection, including fresh actor/matcher construction, row building, sorting, visibility, output construction and release |
| Long Unicode roots | Same complete projection using 32 longer roots with accents, CJK and multiscalar emoji |
| Single-root projection | Complete 1,024-file projection with one source root |
| Small/default controls | Empty and one-row tree projections with no visibility rules; one-row files-only projection with 32 roots |
| Setup control | Repeated construction/replacement of a 32-root matcher; final observability probe outside timing |
| Lookup diagnostics | A reused matcher processing 1,024 relative-path queries: one root, broad-first and deepest-first nested roots, and unmatched paths |

The 12 workloads use synthetic in-memory URLs and values. Input construction is
outside timing. No directory enumeration, sidecar read or media decode occurs.
Entries are generated in natural filename order; the production sorter still
runs, but these fixtures do not characterize shuffled-input sorting costs.
"Cold projection" means a fresh browser-filter actor with empty projection
caches; it does not mean a cold disk or filesystem cache.

The complete projections call the actual `SourceBrowserFilter.project(input:)`
and include the original sorting, normalization, row construction and visibility
logic. The benchmark does not substitute a simplified root matcher. Matchers
are reused only in the separately labelled lookup diagnostics.

Both variants use the same workload driver and supporting production sources,
compiled as separate modules. After one untimed warmup in each fresh process,
timing records both monotonic elapsed time and process CPU time. Calibration
chooses a common iteration count; ten paired blocks rotate workload order and
balance baseline/candidate process order. All observations, including unfavorable
controls and short samples, are retained without outlier removal.

## Correctness and source identity

The runner uses the existing source-tree snapshot helper to stage the production
projection and exact Foundation-only declarations. The only production
difference between variants is the complete `SourceVisibilityMatcher`
declaration, pinned against the baseline commit. Shared-source hashes and final
input/staging audits protect attribution. Linux applies the established import
adaptations separately from the native macOS comparison.

Eight new regression tests cover nested and reordered roots, `/`, exact roots,
prefix neighbors, empty/remote roots, normalization, literal percent-like names,
grapheme counts, exact UTF-8 suffixes, ordered regex matches, ancestor precedence
and immutable initialization snapshots. Existing projection, search, media
organization and directory-state suites run with the new tests in debug and
release against both variants.

Untimed differential output includes 24 lookup-corpus groups and all 12 workload
outputs. It retains complete ordered projection rows, every visibility field,
regex counts, thumbnail URLs and media paths. Relative-path strings also include
their exact UTF-8 bytes. Each large primary projection independently checks that
960 entries remain visible and 64 are hidden.

## Reproduce

Follow `AGENTS.md` and use Kyoto when available. The isolated CI runners record
its absence and compile each package serially. The Linux comparison uses Swift
6.3.2 on Ubuntu 24.04; native qualification uses macOS 26 and pinned Xcode.
The dedicated workflow runs on research-branch pushes and manual dispatch.
The regression tests also belong to the normal `IlliquidAppTests` target.

```sh
python3 Benchmarks/SourceVisibilityRootLookup/run.py \
  --output /tmp/illiquid-root-lookup --pairs 10 --target-ms 350

python3 Benchmarks/SourceVisibilityRootLookup/run.py \
  --output /tmp/illiquid-root-lookup-correctness --correctness-only
```

Use a new output directory. The runner preserves source and executable hashes,
compiler/host metadata, test receipts, exact output comparisons, calibration,
the predetermined run order, raw measurements and paired summaries. Native
results and qualification status will be recorded after execution.

## Related research

This change is separate from tree/projection reuse, unchanged-row storage,
manual-only visibility fast paths and ancestor-evaluation caching. The earlier
source-presence traversal candidate from this investigation was stopped before
measurement when an independently published concurrent branch was found to
contain the same change. No result from that abandoned candidate is attributed
to this optimization.
