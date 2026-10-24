# Source visibility row-storage memory research

## Status

The unchanged-projection candidate has passed its initial Linux component
experiment and focused storage tests. The formal paired study and native macOS
qualification are in progress. This report will record those results before a
pull request is opened.

## Problem and change

`SourceBrowserFilter` retains tree rows in its tree cache and visibility key.
The original visibility pass nevertheless builds another array by appending
every accepted row, including when all rows remain included and unannotated.
The cached projection then keeps that second backing allocation alive.

The candidate leaves the output unmaterialized until the first excluded row or
the first original/computed visibility annotation. It then copies the accepted
prefix once and follows the existing append behavior. If the entire projection
is unchanged, it returns the existing immutable array storage. There are no
changes to rule matching, hidden counts, preview annotations, search, media
grouping, thumbnail eligibility, or cancellation checks.

Previously published values remain independent when a caller changes an array.
This follows Swift Array's documented copy-on-write behavior, and the new tests
explicitly exercise mutations of the caller array and a returned projection.
See [Apple's Array documentation](https://developer.apple.com/documentation/swift/array).

## Measurement design

The [reproduction runner](../Benchmarks/SourceVisibilityStorage/README.md)
compiles the actual filter at immutable baseline
`6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635` and the candidate source. All supporting
production bytes must match. No synthetic substitute for the filter or row
types is used.

The formal cohort uses six balanced AB/BA pairs in fresh processes for six
workloads at 1,000, 10,000 and 100,000 rows. Both the input and the actor/result
remain alive during live allocator sampling. Timing includes one cold awaited
projection; fixture generation and output encoding occur outside measurement.
The full tree-input case additionally includes row construction and sorting.

The principal metric is incremental live allocator bytes immediately after the
projection returns, with its input, actor and result held. There is no forced
autorelease-pool drain or quiescence interval: this sample can include pending
Foundation autoreleases and runtime allocations. The runner's
`retained_allocator_delta_bytes` field denotes this at-return delta, not a
measurement of steady-state or post-drain retained heap. It is not RSS,
physical footprint, peak memory, or total app memory.
The row array's URL/string/metadata references are not claimed as deep copies.
Unchanged values share these references in both variants; the eliminated
allocation is the duplicate array backing storage and its capacity overhead.

## Initial exploratory result

Linux x86-64, Swift 6.3.2, two AB/BA pairs at 1,000 rows:

| Case | Baseline retained delta | Candidate retained delta |
| --- | ---: | ---: |
| Unchanged rows | 499,840 B | 163,968 B |
| Enabled nonmatching rule | 499,968 B | 164,096 B |
| Hide alternate rows | 251,536 B | 251,536 B |
| Hide final row | 499,856 B | 487,440 B |
| Reveal/annotate alternate rows | 531,968 B | 531,968 B |
| Tree construction plus visibility | 939,808 B | 608,000 B |

These pilot values demonstrate the mechanism and select the final experiment;
they are not the final native result. Twenty-four complete-output comparisons
also matched byte for byte. The focused nine-function storage suite passed.

## Qualification gates

The PR requires the final allocator study, baseline/candidate semantic tests,
an expected failure of the old code's storage-sharing assertion, complete-byte
projection parity, independent code/evidence review, and native application
integration. Controls preserve filtered and annotated paths. Results at large
synthetic library sizes will be presented as stress measurements.

Native and full-cohort results are pending.
