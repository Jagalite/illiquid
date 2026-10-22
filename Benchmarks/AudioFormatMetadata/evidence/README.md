# Audio format metadata evidence

See the [research report](../../../Documentation/AUDIO_FORMAT_METADATA_PERFORMANCE.md)
for the scope, method, results, and limitations. The baseline is
`a2de305c8dbcaa81aac1477df7c9a0017c14eae3` in every cohort.

| Cohort | Candidate | Timing observations | Duration target | Native app and selected tests |
|---|---|---:|---|---|
| [macos](macos/) | `c127a92` | 156 | All at least 5 ms | Release build and all 36 selected tests pass |
| [macos-initial](macos-initial/) | `935a34f` | 156 | All at least 5 ms | Build passes; one audio-delay test fails because the workflow omitted its H.264/AAC fixture |
| [linux](linux/) | `935a34f` | 156 | Two candidate observations slightly below 5 ms | Helper-only tests; full native app is macOS-specific |

All three cohorts pass the 13,355-preparation metadata comparison and all ten
helper tests in both debug and release. All 78 timing pairs per cohort favor the
candidate. The native cohorts use the same macOS/Swift/FFmpeg versions and are
reported separately. The Linux cohort is supplementary; it was not rerun to
replace its two short observations.

Each cohort retains raw timing observations, summaries, calibration, build
receipts, source/binary/library hashes, test logs, and a qualification receipt.
The two native cohorts also retain the complete selected native test log and
host receipt. The workflow-only correction between their commits adds the
missing fixture; measured source and benchmark hashes are identical.

The baseline and candidate metadata traces are byte-identical across all three
cohorts. Their common contents are retained once in `metadata-trace.json.gz`;
`trace-receipt.json` records the uncompressed size and SHA-256. For inspection:

```sh
gzip -dc Benchmarks/AudioFormatMetadata/evidence/metadata-trace.json.gz \
  | python3 -m json.tool
```

The associated GitHub Actions artifacts retain source snapshots, compiled
harnesses, and generated media for 14 days. Raw timing data, the full parity
trace, qualification logs, and the source revisions remain committed here.
