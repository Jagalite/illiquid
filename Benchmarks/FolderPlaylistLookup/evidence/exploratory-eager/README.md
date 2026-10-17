# Excluded eager-query prototype

These five-case smoke results are retained to explain the refinement, and are
excluded from the final performance estimates. The smoke used two pairs and a
1 ms target while qualification builds were also active. It checked that the
separate-module driver, timers, output receipts, and URL fixtures worked.

`FolderPlaylist.swift` is the exact eager-query prototype used by this run; its
SHA-256 matches `results.json`. The other two production sources are unchanged
from the pinned baseline. The driver's and runner's hashes are also recorded.

The all-invalid-item control exposed avoidable query normalization before any
valid item was found. The final implementation computes the query key after
finding the first valid item. It is measured separately in `../linux/results.json`
with all 18 workloads and 12 balanced pairs each.
