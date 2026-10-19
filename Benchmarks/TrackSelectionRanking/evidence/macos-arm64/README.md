# Native evidence

These results were produced by the successful
[macOS qualification run](https://github.com/Jagalite/illiquid/actions/runs/39067310230)
at `20dedeaa37e51eb6e5dfd2e18605d760b20f3e24`, against baseline
`68274d1b09dcc866296321a5a8858efc297c4f19`.

- `summary.json` contains all 16 workloads' medians, ranges, paired ratios,
  iteration counts, and absolute differences.
- `provenance.json` identifies the exact commit, compiler, SDK, source hashes,
  Actions run, and artifact digest.
- `receipts.zip` is the unmodified 306,489-byte Actions artifact, including all
  raw final and calibration measurements, individual process logs, complete
  selection receipts, test logs, and build manifests. Its SHA-256 is
  `aa47bf42c98c3bf74ba5240e3ae3615c1198b0762989f87d2e48ed8a22571446`.

The 320 final observations cover ten pairs per workload, equally split between
AB and BA order. Both variants pass the 12 behavior tests in debug and release;
their complete differential receipts agree for 55,296 selections. The benchmark
uses real Foundation on macOS 26.6.2/arm64 with Apple Swift 6.3.3 and the selected
macOS 26.5 SDK, targeting macOS 26.0.

To recompute the summary from the original measurement rows, from the repository
root:

```sh
unzip -q Benchmarks/TrackSelectionRanking/evidence/macos-arm64/receipts.zip -d /tmp/track-ranking-receipts
python3 Benchmarks/TrackSelectionRanking/run.py summarize --output /tmp/track-ranking-receipts/benchmark
```

The earlier SDK-configuration failure is linked in `provenance.json`. It produced
passing test results but no timings. Every reported timing comes from the one
successful run identified above.
