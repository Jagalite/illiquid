# Media file classification research

[Recorded results and all 33 scenarios](RESULTS.md) include the final bounded
candidate, the earlier experiment, correctness receipts, and qualification limits.

This experiment measures the cost of classifying file URLs as media or external
subtitles. `FolderPlaylistDiscovery`, source scanning, and sidebar discovery use
these predicates repeatedly. The production change returns an extension
unchanged when it has at most four UTF-8 bytes, every byte is ASCII, and none is
an uppercase letter. All other extensions use the original `en_US_POSIX`
locale-aware lowercase operation. The iterator examines at most five bytes,
including the first byte that exceeds the shortcut's length limit.

Foundation still extracts `URL.pathExtension`; the accepted extension sets and
the file-URL check are unchanged. In particular, `mKv` must continue to lowercase
to `mkv`. An ASCII-only acceptance rule would break that existing behavior.
The change adds no cache, shared state, or filesystem work.

Four bytes covers all currently supported extensions. This is an optimization
limit, not an acceptance limit: a future longer supported extension would still
be normalized and checked through the existing fallback.

## Reproduce

From the repository root on macOS with the project's Xcode toolchain selected:

```sh
python3 Benchmarks/MediaFileClassification/run.py \
  --output /tmp/illiquid-media-classification-results \
  --pairs 12 --target-ms 250 --discovery-target-ms 100
```

Use a fresh output directory. Follow the repository's `AGENTS.md` build policy:
submit this command through the shared Kyoto queue when available, then inspect
its status, logs, and completion. When it is unavailable, explain that limitation
before using direct builds. The runner keeps its build and module-cache paths
inside its output directory and compiles configurations serially.

The runner also supports Linux for component research. Set `SWIFTC` and `SWIFT`,
or pass `--swiftc` and `--swift`, to select matching compiler drivers. Linux
results do not establish performance on the player's native macOS platform.
`--skip-tests` and fixed `--iterations` are available for exploration; the
qualification command includes tests and calibrates both variants.

The [native workflow](../../.github/workflows/media-file-classification.yml)
runs the same protocol on macOS 26 and uploads the complete evidence directory,
including failure logs. It also verifies the frozen baseline against the
original GitHub revision. The repository's existing PR workflows separately
cover the native application graph and full release test suite. A successful
benchmark job means the correctness checks and protocol completed; assess the
recorded ratios and controls before drawing a native performance conclusion.

## Comparison and correctness

The baseline is the exact `MediaFileSupport.swift` from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Its Git blob and SHA-256 are pinned in
[`baseline/manifest.json`](baseline/manifest.json). The other six production
sources are shared between variants, so only the classification implementation
differs. Each variant is compiled as an optimized library; the classification
and discovery drivers are compiled separately, without cross-module optimization.

Before timing, the runner:

1. Runs the new classification tests and existing discovery, filesystem, and
   external-subtitle regression suites against both variants in debug and
   release configurations. These are actual production source files in an
   isolated package, not a reimplementation or the full native app build.
2. Compares complete JSON receipts for 16,014 URL cases on the recorded Linux
   toolchain. Receipts include URL, extracted extension, file-URL status, and
   both classification results. The corpus covers every supported spelling's
   case variants, Unicode lowercasing, canonical representations, ASCII controls,
   percent encoding, URL authorities, relative URLs, non-file schemes, and
   extensions up to 4,096 characters. The actual count is recorded per platform.
3. Compares complete playlists from 11 real filesystem fixtures, including
   ordering, item URLs, metadata dates, and subtitle associations. Fixtures cover
   unrelated files, subtitle-heavy folders, uppercase and Unicode names,
   symlinks, hidden files, media-looking directories, and filename boundaries.
4. Checks equal checksums within every timed pair and compares each discovery
   observation's complete post-run playlist with its expected receipt. Timed
   scans themselves consume a scalar checksum; full JSON serialization occurs
   outside the timed loop.

The runner snapshots and hashes all source inputs, tests, harnesses, and itself.
It checks that those inputs remain unchanged when the experiment completes.

## Timing protocol

There are 22 classification scenarios and 11 discovery scenarios. Each uses 12
fresh-process pairs with equal iteration counts within each pair. Baseline-first
and candidate-first order alternate by scenario and pair, giving six of each.
Calibration observations are saved separately and excluded from final summaries.
The faster variant must reach the requested process-CPU target during calibration;
one slow scan can exceed that target. Hash randomization is fixed identically for
both timed processes with `SWIFT_DETERMINISTIC_HASHING=1`.

Classification scenarios exercise complete public calls, including Foundation
extension extraction and set lookup. The `paired` mode calls both media and
subtitle predicates for each URL. Additional modes model the caller's
short-circuit expression and media-only classification. Lowercase and mixed-case
sweeps contain 1, 24, 1,000, or 10,000 URLs. Controls include uppercase, Unicode,
unsupported, extensionless, remote, and 128-character extensions, including one
with an uppercase final character.

Discovery scenarios call the real `FolderPlaylistDiscovery.discover`, including
filesystem metadata, filtering, URL resolution, sorting, and subtitle matching.
They use warm filesystem/runtime caches. Fixture creation, process launch,
expected-result generation, warmups, and JSON serialization are outside timing.
Classification, discovery results, scalar consumption, temporary-value release,
and macOS autorelease-pool work are inside timing.

Both process CPU time and monotonic wall time are recorded. One reported
operation means an entire URL sweep or an entire directory scan, **not one
predicate call or one file**. The primary comparison is the median of the
within-pair candidate/baseline ratios. Independent baseline/candidate medians,
their ratio, all individual ratios, ranges, and faster-pair counts are also
reported. No outliers or unfavorable cases are discarded.

## Evidence and limits

`evidence/manifest.json` records compiler/frontend hashes, toolchain version,
platform, source hashes, arguments, and timing environment. `commands.json`
records exact commands, exit status, duration, and output hashes. Raw calibration
and final observations, complete parity receipts, test logs, and build hashes are
retained in the output's `evidence` directory.

This is a component optimization investigation. Classification improvements do
not establish faster playback, rendering, startup, or folder opening. Real
directory scans also spend time in filesystem operations, URL normalization,
sorting, and subtitle matching. Their results must be assessed separately.
Linux Foundation and the shared host differ from Apple Foundation and the
player's target hardware; native results remain a separate qualification gate.

### Why the probe is bounded

The first candidate inspected the entire extension with `allSatisfy`. Its
12-pair Linux experiment reduced the paired median CPU cost of lowercase
24/1,000/10,000-URL sweeps by 33.2%/21.5%/24.3%, respectively, with all 12 pairs
faster in each case. However, the 128-byte all-uppercase and uppercase-final-byte
controls increased by 9.4% and 6.9%, with the candidate faster in only 4/12 and
3/12 pairs. The code was revised to bound the extra inspection before fallback.
The all-uppercase case already exited at its first character; the bounded probe
does not by itself explain that result. The follow-up measures all controls
again rather than assuming that every unfavorable observation had the same cause.

That first cohort is retained in
[`evidence/unbounded-linux`](evidence/unbounded-linux), including every raw
observation and an archive of its complete source snapshots, command logs,
parity receipts, and tests. Its timings describe the first candidate, not the
production version proposed by this PR. The final version is measured in a
separate cohort against the same pinned original baseline.
