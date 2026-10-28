# Canonical file identity keys

## Question

Can persistence and playlist identity lookups avoid constructing a new file URL
only to extract its path immediately afterward?

The experiment changes only `NormalizedFileURL.persistenceKey(for:)`.
Authority validation, lexical standardization, Unicode composition,
`normalize`, and filesystem identity resolution keep their existing contracts.
The frozen baseline is the complete source at
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; its Git blob is verified before any run.

## Reproduce

When Kyoto is available, submit each complete command through the shared queue:

~~~sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/FileIdentityKeys/run.py --output /tmp/file-key-timing
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
  python3 Benchmarks/FileIdentityKeys/run.py --test --output /tmp/file-key-tests
~~~

If Kyoto is unavailable, explain that limitation and run those Python commands
directly. Output directories must be new. Builds are serial and isolated from
the application's `.build`.

The dedicated GitHub Actions workflow uses macOS 26 and Xcode 26.6. It needs
no FFmpeg, libass, Sparkle, signing credentials, or playback fixtures.

## Method

The harness compiles the actual production file-key, media-source, natural-sort,
file-support and folder-playlist sources into separate optimized baseline and
candidate libraries. Only the file-key source differs. A separately compiled,
identical driver calls the production APIs without cross-module optimization.

Before timing, both drivers emit complete receipts for the deterministic URL
corpus. Keys are compared as UTF-8 bytes, preserving the exact stored
representation even when Swift string equality would consider two Unicode
spellings equal. The corpus covers URL and bridged NSURL construction,
canonical and decomposed Unicode, percent escapes, separators, embedded NUL,
directory hints, relative bases, query/fragment components, and rejected
authorities. A mismatch stops timing.

Each workload is calibrated to at least 100 ms for the faster variant.
Eight fresh-process pairs alternate baseline/candidate and candidate/baseline
order, with equal operation counts and output checksums within each pair.
Setup and warmup are excluded from measured intervals. All observations are
retained. Results report median paired candidate/baseline ratios and their
observed range.

Workloads include prepared, Unicode and lexical-alias keys; same-file checks;
unchanged rejected-key and normalize controls; and actual
`FolderPlaylist.index(of:)` calls over 32, 1,000 and 10,000 items. Playlist
queries cycle equally through first, middle, last and missing items.

The test mode runs the existing local-source validation, utilities, folder
playlist and folder lookup suites plus the new identity-key regressions against
both baseline and candidate in debug and release configurations. It uses the
toolchain's bundled Testing module and no package dependencies.

## Qualification

Results and their complete receipts will be recorded here after native
validation. These measurements qualify Foundation components and playlist
lookups only; they do not measure playback throughput, frame pacing, startup,
or live UI interaction.
