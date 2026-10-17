# Empty subtitle association

`ExternalSubtitleMatcher.associate` used to tokenize supported media filenames,
build a token trie, and sort empty result arrays even when its subtitle input was
empty. The candidate returns after constructing the required original-URL keys
and making the final cancellation observation.

This applies to `FolderPlaylistDiscovery.makePlaylist` when there are no sidecars.
It also applies to the later association call in
`PlaybackController.prepareOpenPlan` whenever no standalone subtitles were
selected. In that latter case, sidecars discovered inside a folder are already
attached to playlist items and remain intact.

## Reproduce

Requires Swift 6.1+ and Python 3.10+; no FFmpeg, libass, Sparkle, or media fixtures
are needed. Run one benchmark at a time. Use an empty output directory for each
attempt so earlier evidence is preserved.

```sh
python3 Benchmarks/EmptySubtitleAssociation/run.py --tests-only \
  --output /tmp/illiquid-empty-association-tests
python3 Benchmarks/EmptySubtitleAssociation/run.py \
  --pairs 8 --target-ms 80 --max-sample-ms 1500 \
  --output /tmp/illiquid-empty-association-timing
```

The frozen baseline is the original complete matcher from main commit
`68274d1b09dcc866296321a5a8858efc297c4f19`; its hash is checked before running.
Every other production source is identical between baseline and candidate and
its hash is recorded. The seven complete Foundation-only production files are
compiled as a separate optimized `IlliquidCore` library; the driver calls that
module through the same public API boundary used by the application. Production
sources are not rewritten, extracted, or replaced by benchmark models.

## Method

Fourteen workloads cover empty subtitle lists at 0, 1, 16, 1,000 and 10,000 media
URLs; Unicode names; duplicate media; unsupported media; nonempty matching and
unsupported subtitle controls; and complete playlist construction from prepared
listings. The fixture generator creates URLs with explicit file/directory flags
and supplies deterministic metadata dates without reading the filesystem.

Each workload runs eight fresh-process pairs with alternating baseline/candidate
order and a deterministic per-pair input shuffle. Calibration is excluded from
the reported results. Both variants in a pair perform the same number of calls:
calibration aims for 80 ms on the faster variant, capped at an estimated 1.5 s
on the slower one. Actual timings, including shorter or longer samples, are
retained. No observations are discarded and no control is subtracted.

Fixture creation, warmup, full output checks and JSON encoding are outside the
timer. The timed loop includes calls, previous result disposal, and a constant
time count checksum. The final output is retained until after timing and checked
against a separately constructed expected result. Complete receipts include
original URL strings, subtitle ordering, playlist ordering, and metadata dates.
Their canonical hashes and checksums must also agree in every measured pair.

`measurements.jsonl` preserves raw observations. `summary.json` reports absolute
medians and ranges, median per-pair time reductions, and the number of favorable
pairs. The runner records compiler commands, source/test/driver hashes, platform,
and commit identity. Full receipts accompany the workflow artifact.

## Correctness and limits

The same expanded regression suites run against baseline and candidate in debug
and release with warnings treated as errors. They cover exhaustive matching
and ambiguity, all supported formats, Unicode, duplicate and unsupported keys,
cancellation at every observed checkpoint, playlist ordering/mutation, and real
temporary-directory discovery behavior.

Cancellation checkpoint counts are intentionally allowed to decrease when work
is removed. Both implementations must discard all results as soon as they
observe cancellation, including a one-observation predicate and cancellation
immediately before returning. The nonempty subtitle path is unchanged.

These experiments measure warmed in-memory matching and playlist model
construction. They exclude directory enumeration, filesystem identity resolution,
metadata reads, `prepareOpenPlan`'s surrounding work, UI scheduling, media startup,
rendering, memory footprint and energy. A component improvement does not establish
the same percentage improvement in folder-open latency or whole-player CPU.

Native results will be recorded here after the branch validation run completes.
