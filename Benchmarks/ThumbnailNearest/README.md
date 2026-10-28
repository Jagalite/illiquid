# Nearest thumbnail cache lookup research

## Production path and proposed change

`NativeTimelineThumbnailGenerator.cachedThumbnail` first tries an exact cache
hit, then calls `NativeThumbnailCache.nearest` to display an existing preview
near the requested timeline position. The resident cache holds at most 96
images. Storyboard fallback times also supply potential disk keys after a
restart.

The original lookup filters resident keys, constructs a `Set<Key>`, and sorts
that set into another array. Hashing each complete key includes the media path,
content version, dimensions, and renderer identifier. All admitted candidates
already have the same source, version, and dimensions; only their integer
half-second bucket varies.

The candidate keeps the filtered array, deduplicates fallback times with a
`Set<Int>` of those buckets, and sorts the array in place. It therefore avoids
full-key hashing during candidate deduplication and the conversion from a set of
complete keys back into an array. The normal image-cache lookup still uses its
complete key.

## Behavioral contract

The change retains the original resident key values. This is necessary because
Swift string equality can consider differently encoded Unicode strings equal,
while the JSON used for a disk-cache digest can preserve their different
representations. Rebuilding resident keys from the query could change which
disk entry gets promoted or loaded.

All admitted resident keys have equal path, version, width, height, and renderer
fields. The resident dictionary cannot contain two equal keys for the same
bucket. Deduplicating a fallback by bucket therefore makes the same decision as
inserting its complete key into the original set, including retaining the
resident key when a fallback duplicates it.

Distance calculations continue to convert each bucket to `Double` before
subtraction. The existing inclusive distance bound, rounding of fallback times,
invalid-input handling, earlier-bucket tie-break, cancellation checks, and
ordered asynchronous image attempts are preserved. In particular, large
integer buckets keep the existing floating-point precision and tie behavior.

## Qualification plan

The baseline is main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`; its complete
`NativeThumbnailCache.swift` Git blob is
`66b8127d5c1ea269860b2c1b63e3dcede4262807`.

The focused runner will compile the complete cache and its real dependencies,
run the same regression tests against both variants in debug and release, and
compare detailed lookup receipts. Tests cover source/version/size isolation,
distance boundaries, duplicate and invalid fallback times, cancellation,
Unicode key identity, and disk restart behavior.

Timing will exercise actual asynchronous `nearest` calls with real resident
`CGImage` values, including the existing cache hit and recency bookkeeping.
Image construction, cache population, and verification serialization stay
outside the clock. Timed fixtures exclude disk I/O; disk behavior is checked
separately for correctness. Empty, small, mixed-identity, storyboard, and
full-resident-cache cases provide controls.

Measurements must use optimized production modules and a separately compiled
driver with cross-module optimization disabled. Fresh-process pairs use equal
work counts, alternating baseline/candidate order, and validated result
checksums. The runner records the compiler, host, source hashes, commands,
calibration, raw measurements, and summaries.

This is a component experiment. It does not establish an improvement in video
decoding, end-to-end hover latency, frame rate, battery life, or live UI
responsiveness. A performance PR is warranted only after the experiment
demonstrates a repeatable benefit with matching behavior.
