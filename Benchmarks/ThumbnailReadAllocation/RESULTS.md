# Thumbnail read allocation results

## Finding and review status

The conditional reservation reduces cumulative allocation traffic for multi-chunk
thumbnail reads in the measured Linux component. Several larger synthetic inputs
also retain less live allocator storage while the returned bytes are held.
Single-chunk controls retain their original allocation behavior.

This is a narrow allocation result. Current RSS did not improve consistently,
and timing moved in both directions. The change should remain a draft until
macOS component measurements and native image-lifetime tests complete. The
research does not establish a whole-player memory reduction or a general speedup.

## Production change

The bounded reader already obtains the file size before reading. It now keeps
that validated size and reserves destination capacity only when the file is
larger than the existing 64 KiB read chunk. The destination starts empty, and
the original bounded read loop still determines actual bytes and EOF behavior.
Files initially above 16 MiB are rejected before reservation.

The first experiment used unconditional reservation. It increased held allocator
bytes for the 41,904-byte JPEG from 41,920 to 45,072 bytes, a 3,152-byte regression.
That version was rejected. The final condition preserves the existing path for
files that fit in one chunk. The complete exploratory cohort is retained under
[`evidence/exploratory-unconditional`](evidence/exploratory-unconditional),
separately from the final results.

## Method and provenance

- Date: 24 October 2026.
- Environment: Swift 6.3.2, x86-64 Linux 6.18.55, glibc 2.39.
- Baseline: `4abf4b44f13386ccd04f1ce4ad0e756255ca4d14`.
- Measured production source matches commit
  `985f4936b511341e97ebc67f60f9689d278f68f5`.
- Candidate full-source SHA-256:
  `4df8edde50b3e1a610a926b74f081f967060a8d0011f5c3413a17e3b61475706`.
- Thirteen fixtures, eight balanced AB/BA pairs per fixture and measurement mode,
  totaling **624 fresh-process observations** plus **26 preflight checks**.
- The complete production function is compiled into separate baseline and
  candidate modules. Only its access level and enclosing type are adapted for
  this isolated Foundation component. The algorithm is not reimplemented.
- Memory, allocation traffic, and timing run in separate observations. Timing
  uses an executable without the allocation interposer. Reads use a warm
  filesystem cache; full-byte comparisons run outside the measured phase.

The runner recorded the previous checkout commit plus a dirty working tree
because measurement began before the final code checkpoint. Its source hashes,
frozen inputs, and compiled artifact hashes identify the exact measured code;
the independent audit verifies the production hash against the final source.
Kyoto was unavailable in the research environment, so compilation ran directly,
serially, in isolated build directories.

## Allocation traffic

Values below are median **successful intercepted allocation-request bytes per
read**, including the function's FileHandle/Foundation work. They sum `malloc`,
`calloc`, and `realloc` requests, including repeated requests for the same logical
payload. Other allocation families are outside this Linux/glibc meter. These
values are neither peak memory nor resident memory.

| Input | Baseline requested bytes/read | Candidate requested bytes/read | Change | Allocation calls/read |
|---|---:|---:|---:|---:|
| 320 × 180 JPEG, 41,904 B | 215,534 | 215,534 | 0.00% | 15 → 15 |
| 640 × 360 JPEG, 162,337 B | 777,521 | 711,985 | −8.43% | 30 → 29 |
| 65,537 B raw boundary input | 357,073 | 279,248 | −21.80% | 20 → 19 |
| 256 KiB raw input | 1,577,809 | 1,037,137 | −34.27% | 39 → 36 |
| 1 MiB raw input | 7,083,613 | 4,134,493 | −41.63% | 127 → 120 |
| 5 MiB raw input | 42,919,581 | 20,653,725 | −51.88% | 582 → 568 |
| 16 MiB raw boundary input | 140,055,373 | 66,081,613 | −52.82% | 1,819 → 1,800 |

The empty, missing, oversized, 4 KiB, 65,535-byte, and 65,536-byte controls also
have identical allocation counts and requested bytes. No control or outlier
was dropped. The two valid JPEGs contain deterministic synthetic RGB noise;
they do not represent a measured distribution of user thumbnails. Large raw
fixtures exercise the reader's capacity and size bound.

## Held allocator storage and resident memory

The held values are allocator-wide live-byte deltas from the before-read
checkpoint, sampled while the result is retained. The release checkpoint runs
after an out-of-line helper has returned without any `Data` in its return value.

| Input | Baseline held allocator delta | Candidate held allocator delta | Savings |
|---|---:|---:|---:|
| 320 × 180 JPEG | 41,920 B | 41,920 B | 0 B |
| 640 × 360 JPEG | 163,856 B | 163,856 B | 0 B |
| 65,537 B raw input | 81,968 B | 69,680 B | 12 KiB |
| 256 KiB raw input | 327,696 B | 262,160 B | 64 KiB |
| 1 MiB raw input | 1,146,896 B | 1,048,592 B | 96 KiB |
| 5 MiB raw input | 6,062,096 B | 5,242,896 B | 800 KiB |
| 16 MiB raw input | 18,923,536 B | 16,777,232 B | 2,146,304 B |

Released-allocator paired differences were zero across all fixtures. This does
not imply that freed pages leave the process's resident set.

**RSS is not a demonstrated improvement.** For the 640 × 360 JPEG, the median
paired difference in held current-RSS delta is **+57,344 B**, and the released
current-RSS difference is **+159,744 B**. Several larger raw cases also have
approximately 49–57 KiB higher held RSS deltas in the candidate. All observations
are retained. The benchmark samples current RSS rather than peak or physical
footprint and does not measure ImageIO's retained `CGImage` storage.

## Timing and remaining tradeoffs

Timing is descriptive. Median paired changes include **+7.35% CPU** for the
1 MiB input, **+18.84% wall time** for 256 KiB, and **+13.32% CPU / +11.98% wall
time** at the 16 MiB boundary. Other cases improve, and even unchanged-path
controls vary. This cohort does not establish a general speedup or rule out a
latency tradeoff. Per-pair deltas, CPU time, and wall time are all retained.

If a file larger than 64 KiB shrinks after the size probe, the candidate can keep
capacity for its earlier size despite returning fewer bytes. This reservation
is bounded by 16 MiB. Growth remains subject to the original extra-byte rejection
check. Static fixtures do not qualify concurrent file mutation.

## Validation and native gate

The independent [`audit.json`](evidence/linux/audit.json) verifies:

- Exactly 624 observations and 26 preflight receipts, with 156 AB and 156 BA pairs.
- Exact returned-byte and rejection parity across every recorded receipt.
- All 416 measured-loop checksums and iteration counts.
- Fixture content hashes, all 104 summary metrics recalculated from raw pairs,
  663 successful commands, and source/compiled-artifact hashes.
- Identical allocation counts, requested bytes, and held allocator bytes for
  the small JPEG in every final pair.

The existing codec-adapter qualification passes **6 tests** after updating its
literal guard assertions. Its exact-function and surrounding-source checks
remain intact. Workflow YAML, shell, and embedded Python were parsed, and the
existing disk-eviction benchmark's pinned dependency check passes.

The macOS workflow now runs this component study and includes
`ThumbnailImageLifetimeTests` in its native test selection. Those tests cover
the encoded-size boundary, oversized-alias fallback, and exact decoded pixels
after autorelease-pool drainage, promotion, rename, and deletion. They have
**not completed for this change at report creation**. The initial native run is
[`40103784539`](https://github.com/Jagalite/illiquid/actions/runs/40103784539);
the PR checks show the current run if a later commit supersedes it.

## Retained evidence

[`evidence/linux`](evidence/linux) contains the final manifest, full summary,
preflight receipts, independent audit, compressed raw observations and command
logs, and both extracted function sources. The benchmark source and JPEG
fixtures are committed alongside them. See [`README.md`](README.md) for the
reproduction command and measurement definitions. The interrupted unconditional
eight-pair attempt is not used for the final claim.
