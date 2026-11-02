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
Setup and small-projection controls use short ASCII roots; long Unicode roots
are covered by the separate 1,024-entry projection.
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
results and qualification status are recorded below as they become available.

## Related research

This change is separate from tree/projection reuse, unchanged-row storage,
manual-only visibility fast paths and ancestor-evaluation caching. The earlier
source-presence traversal candidate from this investigation was stopped before
measurement when an independently published concurrent branch was found to
contain the same change. No result from that abandoned candidate is attributed
to this optimization.

## Linux component result

The Linux run at `defc68eb90aa1e6086daf4de7a03df5841d4a399` passed all
42 component tests in each of baseline/candidate debug/release (168 executions),
full output parity for all four builds, and the final source identity audit.
The host exposed four logical CPUs of an AMD EPYC 7763, using Swift 6.3.2,
Ubuntu 24.04/glibc 2.39, and Linux 6.17.0-1022-azure. These results are
portable component evidence; native macOS qualification remains pending.

Both primary workloads cleared the predeclared CPU criteria with 10/10 faster
pairs. No common control reached the material-regression threshold. The setup
control cost 7.064 microseconds more per matcher (median paired CPU difference).
Empty and one-row no-rule projections cost 7.139 and 6.333 microseconds more.

All twelve cases are retained below. Times are medians per complete projection,
per 1,024-query lookup batch, or per matcher initialization as labelled.
Percentages are medians of paired reductions, so a negative value is a slowdown;
they need not equal the reduction computed from the two displayed medians.

| Case | Baseline wall ms/op | Candidate wall ms/op | Paired wall reduction | Paired CPU reduction | CPU faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| `projection-files-8-roots-1024` | 34.9438 | 31.0415 | 11.33% | 11.32% | 10/10 |
| `projection-files-32-roots-1024` | 46.0082 | 33.8003 | 26.72% | 26.75% | 10/10 |
| `projection-files-unicode-32-roots-1024` | 538.5640 | 402.7192 | 25.24% | 25.26% | 10/10 |
| `matcher-one-root-1024` | 0.4708 | 0.2572 | 45.38% | 45.38% | 10/10 |
| `matcher-nested-broad-first-1024` | 27.3077 | 2.3522 | 91.39% | 91.39% | 10/10 |
| `matcher-nested-deep-first-1024` | 35.3880 | 1.1208 | 96.83% | 96.83% | 10/10 |
| `matcher-no-match-32-roots-1024` | 4.5203 | 1.9210 | 57.63% | 57.63% | 10/10 |
| `matcher-init-only-32-roots` | 0.2273 | 0.2338 | -3.12% | -3.12% | 1/10 |
| `projection-no-rules-empty-32-roots` | 0.2807 | 0.2883 | -2.47% | -2.58% | 1/10 |
| `projection-no-rules-one-row-32-roots` | 0.3077 | 0.3132 | -2.13% | -2.11% | 1/10 |
| `projection-files-one-row-32-roots` | 0.6218 | 0.6245 | -0.05% | 0.02% | 5/10 |
| `projection-files-one-root-1024` | 31.5442 | 30.1380 | 4.39% | 4.38% | 10/10 |

[Linux job and logs](https://github.com/Jagalite/illiquid/actions/runs/40637278046/job/122647040407)
and [complete CI artifact](https://github.com/Jagalite/illiquid/actions/runs/40637278046/artifacts/12794705224).
Committed evidence includes [the summary](evidence/linux-summary.json),
[the independent numeric audit](evidence/linux-audit.json), and
[the complete numeric receipt bundle](evidence/linux-numeric.json.gz).
The bundle SHA256 is
`37d76095500f56f8707314e0e3b7b18e7028bf6c18972d85c323c8c4b058e03a`.

### Retained evidence

The gzip bundle is a JSON object mapping filenames to their exact text. It
contains the source manifest, test and parity receipts, calibration pilots,
predetermined schedule, all 240 observations, summaries, command log, source
audit, and completion receipt. It can be expanded without executing any code
from the archive:

```sh
python3 - <<'PY'
import gzip, json
from pathlib import Path
source = Path('Benchmarks/SourceVisibilityRootLookup/evidence/linux-numeric.json.gz')
target = Path('/tmp/illiquid-root-lookup-retained-linux')
files = json.loads(gzip.decompress(source.read_bytes()))
assert not target.exists()
assert all(Path(name).name == name for name in files)
assert all(isinstance(value, str) for value in files.values())
if files:
    target.mkdir()
    for name, value in files.items():
        (target / name).write_text(value)
PY
```

The independent numeric audit rechecked all 240 observations, balanced pair
order, calibration, summary arithmetic, scalar output equality, source receipts
and local input hashes. Full output JSON, raw XML, and staged source snapshots
were checked by the CI runner and retained in the complete artifact; they were
not re-downloaded for that separate numeric audit.

### Attempt history

The first [root-lookup run](https://github.com/Jagalite/illiquid/actions/runs/40637004286)
at `85641e12afe71358765ccc85614fb26e84ba7308` stopped before compilation because
Git rejected the container checkout ownership during metadata collection.
The follow-up confines `safe.directory` to that checkout for two read-only Git
commands. It also pins the observed official Swift image digest and excludes
build caches from evidence uploads. The production change, tests, workload
driver, and acceptance criteria were unchanged. There are no measurements from
the failed attempt to omit.
