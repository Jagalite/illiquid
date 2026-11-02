# Supplementary Linux evidence

Host: shared x86-64 Ubuntu 24.04 environment, AMD EPYC 9V74, Swift 6.3.2.
The full benchmark used eight alternating AB/BA pairs, a 100 ms calibration
target, and the 28 workloads defined in the archived `workloads.json`. All 448 measured
observations passed complete output parity and checksums. Every variant met the
25 ms minimum CPU/wall sample qualification; the shortest CPU observation was
49.1 ms. This is supplementary evidence, not macOS qualification.

| Last-item workload | Baseline CPU per record | Candidate CPU per record | Median paired CPU change |
| --- | ---: | ---: | ---: |
| No folder, 1,000 items | 17.42 ms | 5.65 ms | -64.6% |
| No folder, 10,000 items | 175.33 ms | 56.16 ms | -65.4% |
| Folder, 1,000 items | 16.64 ms | 9.93 ms | -30.4% |
| Folder, 10,000 items | 209.14 ms | 136.81 ms | -30.1% |

The absolute columns are separate medians; the percentage is the median of the
eight paired ratios, so it need not equal a ratio of those displayed medians.
The host showed substantial timing variance. Controls include +10.1% paired CPU
for a singleton folder playlist, +6.3% for a 32-item first-match folder playlist,
and +1.9% for entirely unsupported item URLs. Remote-source control CPU changed
by -0.2%. Do not interpret these supplementary controls as proof of a native
regression or improvement; retain them when comparing with the macOS study.

Both revisions passed 22 tests in three suites in debug and release. These test
logs come from the initial smoke run. Its short timing observations are not the
reported study: the full timing run uses the revised CPU/wall calibration and
2,000,000-iteration cap. The production and test source hashes are unchanged.

`summary.json` and `manifest.json` are direct runner outputs. `review.json.gz`
is a JSON mapping from relative evidence paths to their complete UTF-8 contents,
including every raw observation, calibration trial, command, benchmark log,
source snapshot, and test receipt. It can be inspected with Python's standard
`gzip` and `json` modules. Build products and caches are excluded.

The remote research commit has the same production, test, and harness contents
as the local measured worktree. The native receipt records that remote commit
directly; the Linux manifest records the earlier main HEAD plus its worktree
changes and exact source hashes.
