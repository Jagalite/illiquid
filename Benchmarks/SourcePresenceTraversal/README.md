# Source media presence traversal

This experiment measures whether constructing directory paths only for traversable
directories reduces the cost of the real source-media-presence cursor.

The baseline is `main` at `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`.
`SourceMediaPresenceCursor.nextBatch` originally reconstructed a path from the
parent identity and entry filename for every filesystem entry. Only ordinary
directory entries use that path. The candidate moves the same expression into
that branch, after the existing package/symlink checks. It keeps the parent
guard, metadata lookup, directory identity, caching, cancellation and deadline
checks intact. It adds no cache or persistent storage.

## Experiment declared before measurement

The primary workloads are `flat-media-4096` and `flat-nonmedia-4096`. A successful
experiment should reduce median paired process CPU time by at least 5% in both,
with the candidate faster in at least 8 of 10 pairs. Directory-heavy and fully
cached-directory controls should show no consistent regression above 5%.
Correctness must pass regardless of timing. These are research decision criteria,
not timing assertions in CI.

The nine workloads include an empty directory, a 24-file season, 4096 media
files, 4096 nonmedia files, 4096 mixed files across 32 seasons, 2176 directory
entries (128 parents and 2048 children), 64 cached subtrees, 1024 files under
Unicode/escaped-looking directory names, and hidden/package/symlink controls.
The files are empty because this cursor only inspects metadata and extensions;
it never reads media contents. The fixtures are synthetic and do not estimate
the distribution of a user's library.

## Method and scope

The runner builds separate baseline and candidate packages from the complete
production scanner file and its actual dependencies. The shared
`SourceTreeIdentity` declaration is extracted verbatim from `SourcesSidebar.swift`
with imports added. There is no rewritten scanner or mock enumerator.

Fixture creation occurs once, outside measurement. Each timed process performs
one untimed warmup scan and then complete scans of the same immutable filesystem
tree. A calibration pilot chooses the same iteration count for both variants,
targeting 350 ms in the slower variant. Ten fresh-process pairs alternate AB/BA
order, with workload order rotated between pairs. Both elapsed and process CPU
time are retained; no observations are discarded or overheads subtracted.

Timed traversal uses 256-entry batches and a generous time budget so elapsed
speed does not change slice boundaries. Only scalar counts survive each batch;
the benchmark does not retain historical child sets or sort output in the timed
region. It excludes fixture creation, output serialization, the scanner's
asynchronous yields, publication to the main actor, UI rendering and playback.
These are **warm filesystem cursor measurements**, not cold-storage, whole-library
UI completion, memory, energy or whole-player performance measurements.

## Correctness

Untimed differential runs compare complete result maps, directory summaries,
child identities, completion/readability flags and visited-entry counts. They
also compare fixed-entry batch traces on the same immutable fixture, using
one-entry and seven-entry slices for smaller controls. Paths are compared through
canonical JSON without Unicode normalization. Separate checks compare final
outputs under the normal 20 ms deadline with the entry-limited traversal;
wall-clock slice boundaries are allowed to differ.

Existing cache-reuse and recomputation tests and new traversal regressions run
against both variants in debug and release. Native app-graph tests additionally
cover scanner integration, empty-folder visibility and source-preparation
admission. New tests exercise literal percent-like names, Unicode, files versus
directory children, cached positive/negative subtrees, links, hidden entries,
packages and the macOS `/var` versus `/private/var` namespace.

## Reproduce

Use macOS 26 with the repository's supported Swift toolchain. Follow `AGENTS.md`
and submit builds through Kyoto when it is available; GitHub's isolated ephemeral
runners record that Kyoto is unavailable before compiling serially.

```sh
python3 Benchmarks/SourcePresenceTraversal/run.py \
  --output /tmp/illiquid-presence-traversal --pairs 10 --target-ms 350

python3 Benchmarks/SourcePresenceTraversal/run.py \
  --output /tmp/illiquid-presence-correctness --correctness-only
```

Use a new output directory. Source identities, compiler/host metadata, test logs,
parity receipts, calibration pilots, raw measurements and paired summaries are
retained. Native timing results will be recorded here after qualification.
