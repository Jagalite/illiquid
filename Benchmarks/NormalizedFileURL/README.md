# File URL persistence-key research

## Question and candidate

Does avoiding an unnecessary file-URL round trip make prepared-file identities
and real folder-playlist lookup cheaper while preserving every returned byte?

The frozen implementation comes from main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. It calls
`normalize(url)?.path`, which validates the authority, standardizes the
path, composes Unicode, reconstructs a file URL and immediately reads its path.

The candidate returns the standardized path directly only when it is absolute
ASCII and outside Foundation's `/.file/id=` namespace. ASCII needs no
Unicode composition. The fallback retains the original file-URL reconstruction
for Unicode and special file references. It changes no caller, cache, stored
schema, validation policy, symlink-resolution boundary or public API.

## Reproduce

On macOS 26 with the selected Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
python3 Benchmarks/NormalizedFileURL/run.py --mode all --pairs 8 \
  --target-ms 80 --output /tmp/illiquid-file-key-study
```

The output directory must be new or empty. The script serializes all compilation
and test invocations, using isolated packages with Foundation and the toolchain's
bundled Testing module. It does not resolve the app's FFmpeg or SwiftPM dependencies.

When the shared Kyoto queue is available, submit the complete harness command
through it and add `--under-kyoto`:

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/NormalizedFileURL/run.py --under-kyoto --mode all \
  --pairs 8 --target-ms 80 --output /tmp/illiquid-file-key-study
```

Preserve the intended toolchain environment and inspect Kyoto `show`,
`logs` and `wait` for the returned job before reporting results.
The harness refuses to build directly if it detects the queue. On a hosted runner
where Kyoto is unavailable, it prints that limitation before direct compilation.

## Correctness and measurement

- Baseline provenance is verified against the original Git blob. Both variants
  use identical snapshots of the unchanged production consumer/support sources.
- Existing local-source, utilities and folder-lookup regressions plus the new
  byte-level corpus tests run against both variants in debug and release.
- The corpus exercises URL-string and file-path constructors, Objective-C
  bridging, local and rejected authorities, relative bases, slash/dot variants,
  escaped separators and controls, Unicode representation and file references.
  Constructor failures are retained explicitly.
- The separately compiled optimized driver emits full verification receipts,
  including every optional key's UTF-8 bytes and complete folder lookup outputs.
  Baseline and candidate JSON must match exactly; unchanged normalization serves
  as an additional production oracle.
- The production module and identical driver compile separately with `-O`
  and whole-module optimization, without cross-module optimization. Every
  measurement runs in a fresh process and consumes every returned value.
- URL creation, playlist construction/sorting, expectation generation and warmup
  are excluded from timing. The helper workloads rotate through 64 URLs; consumer
  cases use the actual `FolderPlaylist.index(of:)` implementation.
- Both variants are calibrated to one common call count targeting at least
  80 ms for the faster variant (64 ms admission tolerance). Eight retained pairs
  alternate baseline-first and candidate-first order. All calibration and final
  rows remain available; no outliers are removed.
- The 25 workloads cover ordinary, long, escaped, dot-segment, localhost and
  relative ASCII keys; early/late Unicode fallback; rejected inputs; unchanged
  normalization controls; and first/last/missing queries in 1-, 32- and 1,000-item
  playlists, including a Unicode consumer control.

The automated gate covers compilation, regression results and exact output
equivalence. Timing has no percentage threshold: review absolute changes,
paired distributions and controls before accepting a performance claim.

## Evidence

Each run emits an incremental summary, raw calibration and measurement JSONL,
full verification receipts, source and binary hashes, toolchain/OS information,
exact source snapshots and complete command logs. The workflow uploads them as
`normalized-file-url-evidence` for 30 days. Compact receipts are also
printed in the job log so a successful run can be retained in this directory.

Native results are pending. This study qualifies component CPU work through
elapsed wall time; it does not qualify playback frame pacing, energy use,
live UI responsiveness or full-app integration.
