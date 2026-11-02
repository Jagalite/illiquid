# Current regression and historical qualification

Automated push and PR component jobs use `--current-source-regression`. Both
variants compile identical current support sources; the baseline writer remains
verbatim from ea2ff568237e2667f7b1aeee67b11a44ebe95b72. All 15 complete-record
workloads and baseline/candidate debug/release tests remain mandatory. This is
regression evidence only. Timing is forbidden and duration qualification is null.

Default and manual workflow runs retain strict historical support-source equality.
They intentionally fail after unrelated support drift. To reproduce historical
performance, use the archived measured checkout
9670a9fd32e38c8e3f0a7129fb916601d4d12374 with the pinned baseline available, then:

```
python3 Benchmarks/CheckpointSourceIdentity/run.py --output /tmp/checkpoint-historical-new --pairs 6 --target-ms 150
```

On a Kyoto host submit the complete command through Kyoto and add `--kyoto-queued`.
Never use regression receipts as performance evidence or overwrite archived receipts.
Run noncompiling controls with `python3 Benchmarks/CheckpointSourceIdentity/test_policy.py`.
