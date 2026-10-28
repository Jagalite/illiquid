# File identity key research

## Question and proposed change

`NormalizedFileURL.persistenceKey(for:)` currently obtains a path by validating
and standardizing a URL, converting the path to canonical Unicode, constructing
a new file URL, and reading its path again. Playlist item identity and folder
lookup call it repeatedly. This study tests whether ordinary ASCII paths can
skip the final Unicode/URL reconstruction without changing a single key byte.

Only validated, absolute, non-NUL ASCII paths without the Darwin file-reference
prefix use the shortcut. Unicode and file-reference paths retain the exact
previous reconstruction. Local authority validation, symlink preparation, the
`normalize` API, persistence format, and playlist ordering are unchanged.

The fallback is deliberate: Darwin's file-path constructor performs filesystem
Unicode conversion, and Swift String equality can hide a change in UTF-8
representation. Tests compare optional UTF-8 byte arrays against the unchanged
`normalize(url)?.path` oracle as well as independently specified ASCII keys.
See the Foundation implementations of
[POSIX path construction](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/URL/URL_File.swift)
and [file-reference conversion](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/URL/URL_Impl.swift).

## Reproduce

On macOS with the repository's supported Swift toolchain:

```sh
python3 Benchmarks/FileIdentityKeys/run.py --mode all --pairs 10 \
  --output /tmp/illiquid-file-identity-run
```

Use a new output directory for every run. Submit the entire command through
the shared Kyoto queue when it is available, as required by `AGENTS.md`.
The GitHub workflow uses an isolated macOS runner where Kyoto is unavailable
and serializes all builds.

`--mode tests` runs correctness only; `--mode benchmark` runs measurements.
The harness compiles actual production files; it does not reimplement or stub
playlist behavior. The frozen baseline is the complete helper at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, checked against its Git blob
`d90e4fc199eabfa4e554c3c8d01a1ed48277ae20`. Other production and test files
are identical between variants and are copied from the checked-out candidate.

## Method and acceptance criteria

- Both variants run the same local-source, exact-key-byte, folder-playlist,
  and folder-lookup regression tests in debug and release, with warnings treated
  as errors.
- Release libraries and the measurement driver are compiled separately with
  optimization and whole-module optimization, without cross-module optimization.
- Fixture creation, playlist sorting, result verification, and warmup happen
  outside the timed region. Measured loops consume returned results.
- Each workload has one common iteration count, calibrated against both
  variants for approximately 100 ms or more per process.
- Ten fresh-process pairs alternate baseline/candidate and candidate/baseline.
  All observations, source hashes, binary hashes, compiler/environment details,
  result signatures and checksums are retained.
- Short paths, roots, long ASCII paths, Unicode fallback, invalid authority,
  empty/singleton playlists, and early hits are controls. Real playlist item IDs
  and 32/512-entry last-hit/miss lookups measure downstream impact.
- Correctness is mandatory. A useful improvement must repeat across valid ASCII
  workloads and real playlist lookups. The initial decision threshold is at least
  15% median improvement and 8/10 faster pairs on ordinary ASCII keys and the
  512-item last-hit/miss cases; investigate any repeatable control regression
  above 10%. Timing is reported, not used as a flaky CI pass/fail assertion.

These are component latency measurements, not an end-to-end player, filesystem
I/O, frame rate, CPU utilization, or energy benchmark. Full native playback and
interactive UI behavior require separate qualification.

## Results

Pending native measurement. Raw data and a complete per-case summary will be
recorded after qualification, including fallback and control results.
