# Checkpoint source identity: independent qualification

## Relationship to PR #124

This is a companion to [PR #124](https://github.com/Jagalite/illiquid/pull/124).
That PR appeared while this independent experiment was running and implements
the same source-identity optimization plus a shortcut for playlists without a
collection folder. This branch now uses its production implementation verbatim
and adds a second benchmark, regression coverage, and audited evidence.

The initial experiment below measured prototype
e6fa79251396c920b085ce2f59402dd9b57c9e63. That prototype hoisted source identity
normalization but did not include the no-folder shortcut. Its numbers must not
be attributed to PR #124's exact implementation. A follow-up run is qualifying
the adopted implementation; its results will be recorded separately.

## Initial Linux result

For a 10,000-item playlist with the current file last, the median complete
PlaybackCheckpoint.record() call fell from 119.860366 ms to 80.265477 ms
(33.034% less elapsed time). The 1,000-item case fell from 11.828512 ms to
7.970306 ms (32.618%). All seven multi-item middle/end/missing workloads were
faster in every paired comparison.

The complete operation includes playlist deduplication and Date() creation.
This is persistence-writer work; serialization, disk writes, decoding, UI
latency, frame rate, and total player memory are outside the experiment.

[Initial Actions run](https://github.com/Jagalite/illiquid/actions/runs/40634726321):
Swift 6.3.2 on Linux x86_64, AMD EPYC 9V45, four logical CPUs available.

- Baseline: ea2ff568237e2667f7b1aeee67b11a44ebe95b72.
- Initial candidate: e6fa79251396c920b085ce2f59402dd9b57c9e63.
- 43 tests in seven suites passed in each of baseline/candidate debug/release.
  The additional checkpoint suite has nine methods exercising 27 cases.
- Complete canonical traces for 15 workloads were byte-identical across all
  four binaries; only updatedAt was normalized outside the timed operation.
- Six balanced AB/BA pairs per workload produced 180 observations.
- An independent audit verified all 14 production source copies, copied
  tests/drivers and 12 binaries, and recomputed statistics and duration flags.
- All 144 observations for 32-or-more-item playlists met the 150 ms batch
  target. All 36 empty/singleton observations were shorter (21.8–138.7 ms);
  these short controls do not support a speedup claim.
- First-match and remote-stream controls fluctuated across pairs; this is a
  scoped improvement, not a claim that every checkpoint is faster.

macOS component and full-app qualification have not completed. No native
performance result is claimed. Pull-request jobs run correctness and integration
checks; full timing runs on this research branch and on manual dispatch.

## Reproduce

Run builds through Kyoto when available:

    python3 /Volumes/seed1/Projects/kyoto/kyoto.py submit -- \
      python3 Benchmarks/CheckpointSourceIdentity/run.py \
      --output /path/to/new-results --kyoto-queued

Inspect Kyoto show, logs and wait for the job. Without Kyoto, the harness reports
that limitation and performs serialized isolated builds:

    git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
    python3 Benchmarks/CheckpointSourceIdentity/run.py \
      --output /path/to/new-results --pairs 6 --target-ms 150

Use --tests-only for debug/release regressions and complete-record comparisons
without timing. The benchmark uses the checkout's complete checkpoint writer
and requires all six core dependencies to match the pinned baseline. The full
PlaybackSessionRecord and PlaybackSessionStoring definitions are copied
verbatim, excluding only the unrelated atomic disk store.

The production Core and Player modules are compiled separately from the
driver. Fixture creation and warm-up precede timing. JSON serialization and
full-output fingerprinting follow the timed loop. Calibration uses the faster
pilot with a 50% margin; all observations, including short samples, are retained.
The timed checksum consumes count, position, folder membership and pause state;
complete semantic equality is checked in a separate verification phase.

## Retained initial evidence

[evidence/linux-prototype/receipts.json.gz](evidence/linux-prototype/receipts.json.gz)
is a gzip-compressed JSON object mapping artifact-relative names to their
original text. It includes all observations, summaries, calibrations, commands,
complete test logs, source/binary hashes, completion and audit reports, and one
full canonical record trace shared by all four verified configurations.

SHA-256: 4b2311989daa2ef5b910a6660b4f98669008ad634e1cbcbfab15dea1621b247f.

Read a receipt without extracting arbitrary paths:

    import gzip, json
    with gzip.open("Benchmarks/CheckpointSourceIdentity/evidence/linux-prototype/receipts.json.gz", "rt") as stream:
        receipts = json.load(stream)
    print(receipts["audit.json"])
    observations = [json.loads(line) for line in receipts["observations.jsonl"].splitlines()]

The original Actions artifact additionally contains binaries and build trees
and has 14-day retention. The compact receipts remain in the repository.
