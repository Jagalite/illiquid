# Historical alternative sample planners

Canonical implementation and automatic campaigns belong to PR149 at
`541cb2d4b0442ad141e25c0af9d07b818f04f9f9` before consolidation.
PR190 (`2be4a905d18d9b6008153ad6dd69852730befbfe`) is preserved byte-for-byte in
`Benchmarks/ThumbnailSamplePrefix`. PR206
(`bc87a6bf293327d29eab498c2d6a083d24b600b3`) is preserved byte-for-byte in
`PR206/ThumbnailSamplePlanning`. Historical workflows are archived here, not
installed as competing automatic jobs. Original README commands apply in an
isolated checkout of the corresponding original head at its original paths.
Do not execute the relocated PR206 original runner directly: its root discovery
assumes its original location. `PR206/run-canonical.py` adapts root discovery and
adds both imported test suites without modifying historical files. Its results
measure current canonical sources and must not be labelled original evidence.
PR190's original runner remains at its original path and exercises its independent
Driver.swift corpus against the canonical checkout and frozen baseline.

No comparison across these historical toolchains establishes performance superiority.
The canonical runner includes all five suites, leaving FrozenThumbnailSamples
unchanged. `--current-support --mode tests` captures current support and tests once for both
arms. Its baseline uses the exact pinned historical samples function in the current
policy scaffold; frozen test oracles remain unchanged. All ten workload corpora
compare every output bit pattern without timers. This mode prohibits measurement
and performance claims. Omission retains the historical strict equality guard. No baseline policy or historical evidence is rewritten.

Automatic pull-request campaigns run current regression qualification only. Manual
`workflow_dispatch` and default CLI invocations retain historical timing behavior
and the strict support equality guard; support drift intentionally rejects them.

Parent validation (submit each command serially through Kyoto; inspect show,
logs and wait for each returned job ID):

```sh
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/ThumbnailSamplePlanning/run.py --current-support --mode tests --output /tmp/pr149-canonical
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/ThumbnailSamplePrefix/run.py --kyoto-worker --pairs 12 --target-ms 80 --output /tmp/pr149-prefix
python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- python3 Benchmarks/Historical/PR206/run-canonical.py --pairs 10 --target-ms 250 --output /tmp/pr149-alternative
```

Use fresh output paths. Defaults retain every workload in each runner; these
commands include debug/release tests and differential corpora. Native validation
and live UI qualification remain the parent's responsibility.
