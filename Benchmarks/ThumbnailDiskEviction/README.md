# Thumbnail disk-cache eviction

The disk cache can retain up to 8,192 physical image files. When a completed
write needs space, `NativeThumbnailDiskCache.trimDisk` filters and sorts every
eligible file before removing enough files to admit the write. A full cache
often needs only one eviction, but still pays for the complete ordering.

This experiment replaces that complete sort with a temporary minimum heap.
The heap contains only filename, last-use date, and background status. It is
built for each trim and discarded afterward. There is no persistent index to
update on cache hits, promotions, inventory changes, or failed writes.

The ordering remains background files first, then oldest last-use date, then
physical filename. Eligibility, byte/count limits, queued foreground claims,
the reservation around unlink, stopping after an unlink failure, and deferred
budget reconciliation remain in the disk actor.

Selection work changes from O(n log n) to O(n + k log n), where n is the
eligible inventory and k includes evicted files and protected files skipped
while selecting victims. Removing most of the inventory remains O(n log n);
large reductions and disabling the cache are included as controls.

## Reproduce

Use the project's macOS/Xcode toolchain. The benchmark exercises the actual
disk cache with CoreGraphics, ImageIO, CryptoKit, and disposable filesystem
fixtures. It requires no user media or native playback SDK.

```sh
python3 Benchmarks/ThumbnailDiskEviction/run.py \
  --pairs 8 --output /tmp/illiquid-thumbnail-disk-eviction

swift test --force-resolved-versions --filter \
  'ThumbnailDiskEviction|NativeThumbnailCacheTests|ThumbnailPhysicalEntryTests|ThumbnailInventoryRegressionTests|ThumbnailPromotionMailboxTests|QueuedThumbnailPromotionTests'
```

The app-graph tests require the repository's pinned native SDK. The
`Thumbnail disk eviction` workflow prepares it using the existing verification
and installation scripts.

## Measurement scope

The frozen baseline is main revision
`33fff16155c3472960f88e04c72dfdfdefd56dcf`. Baseline and candidate run in separate
optimized Swift executables, with alternating baseline-first and
candidate-first pairs. Source and executable hashes, commands, environment,
raw observations, and output receipts accompany each run.

The experiment measures cache work around completed persistence operations.
Fixture preparation and output verification are outside timing. A fixed
pre-encoded image isolates cache overhead from JPEG encoding; real filesystem
writes, victim selection, and unlink still run. This is not a measurement of
video decoding, thumbnail generation, whole-player CPU use, or energy use.

The permanent native results and validation record are added after successful
qualification. There is no noisy elapsed-time threshold in CI; correctness,
complete observations, and matching output receipts are mandatory.
