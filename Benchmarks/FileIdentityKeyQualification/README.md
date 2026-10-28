# Independent qualification of ASCII file identity keys

This study independently qualifies the implementation in
[PR #144](https://github.com/Jagalite/illiquid/pull/144), based on its exact
commit `630530f27be150823d4dd4737b15cec947bfd8c9`. The qualification PR is
stacked on that branch and **does not change production code**.

At the frozen main baseline, `NormalizedFileURL.persistenceKey(for:)` validates
and standardizes the input, normalizes Unicode, constructs another file URL,
then reads its path. #144 returns ordinary ASCII paths directly and retains
Foundation reconstruction for Unicode and unusual representations. This suite
checks exact output bytes and measures actual key, item-ID, comparison and
folder-lookup APIs, including fallback/control costs.

Three alternative PRs appeared while the initial independent prototype was
being studied. The final comparison uses #144's exact helper, not that prototype.
The selected helper's Git blob is `4e6867e927aaef29d9746244570e338f17884182`.
#144's existing workflow, tests, documentation and evidence are preserved.

## Reproduce

```sh
python3 Benchmarks/FileIdentityKeyQualification/run.py --mode all --pairs 10 \
  --output /tmp/illiquid-file-identity-qualification
```

Use a new output directory. Submit the entire command through Kyoto when the
repository's shared queue is available, as required by `AGENTS.md`. Hosted
qualification runners have no Kyoto queue; their builds run serially in isolated
directories. `--mode tests` and `--mode benchmark` select individual phases.

The baseline helper is frozen at main commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72` and verified against Git blob
`d90e4fc199eabfa4e554c3c8d01a1ed48277ae20`. Both variants use the same
remaining production files and tests copied from the candidate checkout,
including #144's additions to `LocalMediaSourceValidationTests.swift`.

## Method

- Run local-source, exact-key-byte, folder-playlist and folder-lookup tests on
  both variants in debug and release with warnings treated as errors.
- Compile the real production types into separate optimized libraries. Compile
  the driver separately. Both invocations explicitly use
  `-Xfrontend -disable-cmo`; separate compilation alone is not the guarantee.
- Construct and sort fixtures, verify exact results, compute signatures and
  perform warmup outside the timed region. Timed loops consume returned lengths
  or indices. Their overhead is included, with no subtraction.
- Calibrate both variants to choose one shared iteration count per workload,
  targeting approximately 100 ms or more per process.
- Retain ten fresh-process pairs in alternating AB/BA order, with all calibration
  trials, raw samples, hashes, compiler/environment details and result receipts.
- Include short/root/long ASCII paths, escaped and raw localhost paths, NFC/NFD
  Unicode fallback, unsupported sources, valid/invalid item IDs, and empty,
  singleton, early-hit, last-hit and miss playlist lookups.
- Require byte/behavior parity. The initial portable investigation threshold
  is at least 15% median reduction and 8/10 faster pairs for ordinary ASCII
  keys and the 512-item last-hit/miss cases. Investigate repeatable control
  regressions above 10%; timings are reported, not used as flaky CI assertions.

The new regression suite compares optional UTF-8 arrays against the unchanged
`normalize(url)?.path` oracle and independently specified ASCII keys. Ordinary
Swift String equality can hide differences in Unicode representation.
Foundation's Darwin file-path constructor performs filesystem Unicode conversion;
Linux parity does not qualify Darwin's bytes. Native qualification remains a
separate gate.

These are warmed component wall times. They do not measure filesystem discovery,
folder-open latency, playback, UI responsiveness, CPU utilization, or energy.

## Results

The exact-code comparison is running. Only that follow-up cohort will be used
for the qualification claims. Native macOS results will be distinguished from
portable results and may remain queued.
