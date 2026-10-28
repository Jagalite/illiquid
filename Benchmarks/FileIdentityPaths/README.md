# File identity path construction

## Question

`NormalizedFileURL.persistenceKey(for:)` previously called `normalize(url)?.path`.
For each identity lookup this validates and standardizes the URL, maps Unicode,
constructs a new file URL, and extracts its path. Playlist selection, item IDs,
deduplication and persistence all consume these keys.

This experiment removes the last URL construction only for ordinary printable
ASCII paths. Non-ASCII, control characters, repeated/trailing separators, decoded
dot components and the `/.file/` namespace retain the original Foundation round
trip. Local-authority validation, `normalize()`, and explicit filesystem
resolution retain their behavior. There is no identity cache.

The fallback matters on macOS: the file-URL constructor can alter Unicode byte
representation and interpret file-reference paths. Swift `String ==` alone
does not establish byte compatibility.

## Reproduce

When Kyoto is available, submit the commands through the shared queue described
in the repository's `AGENTS.md`, and inspect the completed job and logs. On a
host without Kyoto, explain that limitation and run the isolated builds directly:

```sh
python3 Benchmarks/FileIdentityPaths/run.py --mode all --pairs 10 \
  --output /tmp/illiquid-file-identity-new
```

The output directory must be empty or new. Builds run serially. The macOS 26
workflow uses the repository's pinned Xcode 26.6 installation. No app bundle,
native decoding SDK, user preferences or media files are needed.

## Method

- The frozen identity implementation is from commit
  `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
  `d90e4fc199eabfa4e554c3c8d01a1ed48277ae20`. The runner verifies that blob.
  Both variants use the same current, unmodified playlist and ordering sources.
- Both implementations run the new byte-parity corpus and existing local-source,
  playlist identity, mutation, restoration and folder tests in debug and release.
  The corpus covers ASCII punctuation and controls, escaped separators/NUL,
  encoded dots, Unicode spellings, unusual path shapes and relative authorities.
- Each optimized production variant is a separate dynamic library. The identical
  driver links against it without cross-module optimization, keeping real calls
  inside the timed loops.
- All fixtures, sorting, expected results and UTF-8 parity checks are prepared
  outside the clock. Two warmup iterations precede each sample. The clock covers
  actual key/lookup calls and consumption of their results.
- Both variants are calibrated to at least 80 ms. A pair uses identical iteration
  counts, and ten fresh-process pairs alternate baseline/candidate order.
  Every calibration and measurement is retained; no outliers are discarded.
- Cases cover prepared/aliased/escaped/long/localhost ASCII paths, Unicode early
  and late in a long path, unusual paths, rejected authorities, and the unchanged
  normalization API. Actual folder and mutation lookups cover 32, 1,000 and
  10,000 items with last/missing matches, plus first-match and Unicode controls.
- Manifests retain source/binary hashes, compiler flags, host details and the
  candidate commit. Logs and JSON receipts are uploaded as CI artifacts.

These are warm component timings. They do not measure decoding, rendering, app
startup, UI frame rates, physical-storage latency or end-to-end playback.
