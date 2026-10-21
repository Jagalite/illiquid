# Source visibility ancestor evaluation

Recursive Files Only and Media projections evaluate visibility for each file and
its ancestors. Siblings repeatedly evaluate the same ancestor paths against the
same rules. The candidate retains direct ancestor evaluations inside the matcher
for one visibility pass, with a maximum of 1,024 entries. It preserves the existing
upward walk, nearest hidden ancestor precedence, ordered regex matches, and root
boundaries. Leaf evaluations and the existing root evaluation cache are unchanged.

The cache checks exact UTF-8 spelling before accepting a dictionary hit. Swift
String equality treats canonically equivalent Unicode spellings as equal, while
regular expressions can distinguish them. Cancelled evaluations are neither
reused nor inserted.

## Reproduce

With Swift 6.1 or newer and its bundled Testing module:

```sh
python3 Benchmarks/SourceVisibilityAncestors/run.py --output /tmp/visibility-results
```

The harness has no network dependencies and works on macOS and Linux. The
`Source visibility ancestor performance` workflow runs it on macOS with the same
Xcode selection as the app's integration workflows. `--tests-only` runs behavior
checks without timing. `--pairs`, `--target-ms`, `--cases`, and `--operations` can
adjust a research run; `--cpu` optionally pins measurement processes on Linux.

## What is measured

The baseline retains the exact matcher declaration and complete browser filter
from `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`. The manifest records the original
Git blobs and SHA-256 hashes. The candidate is extracted directly from production
sources using `Scripts/test-source-browser-search.py`; no alternate implementation
of the visibility algorithm is used. Shared declarations and supporting files are
identical in the two disposable packages. Source receipts record every compiled
file, and the runner rejects inputs that change during a run.

Each variant runs the nine existing source-browser tests and seven ancestry
regression tests in both debug and release. The regression cases cover nearest
ancestor precedence, ordered and deduplicated matches, always-shown overrides,
nested roots, distinct Unicode spellings, literal URL-like path characters,
revisiting more than 1,024 parents, and projection invalidation after rule/root
changes. The existing browser suite also covers cancellation.

Release measurements use two operations:

- `matcher`: construct a matcher and evaluate a complete inventory.
- `project`: construct a fresh production `SourceBrowserFilter` actor and run a
  complete visibility projection, including row annotations, hidden/rule counts,
  thumbnail candidates, and normalized media paths.

Both operations rebuild their cache on every measured pass. Input construction,
one warm-up pass, output serialization, and equality checks are outside timing.
The executable is a separate target that consumes the production library. Every
measurement consumes all output counts and retains the final complete output for
validation. This measures visibility rebuilds, not the existing cross-request
projection cache hit.

The workloads include a 100-file small library; 5,000 files sharing ancestors with
one or eight regex rules; 2,500 files with ten directory levels; an immediately
hidden parent; 2,000 files with unique parents exceeding cache capacity; manual
rules only; no rules; nonrecursive Tree mode; and Unicode paths. No-rules projection
and Tree mode are controls. The standalone matcher still evaluates ancestry for
the no-rules fixture; the real projection skips that unnecessary work.

Before timing, complete baseline and candidate outputs must match for every
workload and both operations, including a 1,300-parent capacity case. Each timing
sample also must match the full output receipt from every other sample of the
same workload. Calibration chooses an iteration count targeting at least 100 ms
for the faster variant, followed by six pairs of fresh processes with alternating
baseline/candidate order. Summaries report per-pass medians and the distribution
of paired time reductions; raw calibration and timing records are retained.

## Scope and evidence

Native measurement results will be recorded here after qualification. The harness
compiles the actual Foundation-based component code, including on macOS, but does
not build SwiftUI or native playback targets. The repository's normal PR workflows
provide app integration validation. These workloads do not measure UI frame time,
playback throughput, energy use, or a user's full filesystem scan.

`SourceTreeVisibility` is a separate historical benchmark for tree reuse. Its
shared matcher snapshot is refreshed to keep this optimization equal in both of
that benchmark's variants; its historical algorithm, comparison gate, and past
evidence are retained.
