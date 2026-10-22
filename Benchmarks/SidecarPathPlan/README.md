# Sidecar ancestor path-plan research

This study compares the actual `MediaSidecarReader` at baseline
`7f9ba073394b77a908e0589447c6edc8d10b832c` with the working-tree reader. Both
variants use identical, current filename recognition, metadata, NFO and
PlexMatch sources, tests and benchmark driver. The source manifests identify
every compiled input. Only `MediaSidecarReader.swift` may differ.

## Reproduce

Requires Swift 6.1 or newer and Python 3.10 or newer. Run from a checkout that
contains the baseline commit:

```sh
python3 Benchmarks/SidecarPathPlan/runner.py --output /tmp/sidecar-plan-study
```

Use `--tests-only` for both implementations' debug/release component tests and
complete-output comparison without timing. The output directory must be new
or empty. Native macOS uses unchanged source bytes. Linux substitutes the
reader's Darwin import with Glibc and imports FoundationXML for the NFO parser;
original and compiled hashes record these two adaptations. Test sources remain
unchanged, including the platform guard on the existing macOS-only PlexMatch
filesystem suite.

The standalone Swift package runs the actual sidecar, NFO precedence, PlexMatch
and new ancestor-plan regression tests in debug and release for both readers.
This does not build the application or exercise playback. The repository's
separate full native PR workflow remains the app/test-graph gate.

## Measurement protocol

- The unit is a complete scan of 128 files (one file for the small-scan control).
  Each scan constructs and destroys a new reader, so both its sidecar-content
  cache and ancestor plan start empty on every timed iteration.
- Fixture creation is outside timing. An untimed scan in each process warms
  filesystem caches and shared filename-recognition initialization. These are
  warm-filesystem measurements, not cold-disk measurements.
- Timed work includes every production `recognize` call, actual sidecar probes
  and parsing, result collection, reader lifecycle, and the same small checksum
  consumer. JSON serialization and full output comparisons are outside timing.
- The driver covers sibling files at depths 1, 4, 12 and 63, shared show NFO,
  nested PlexMatch mappings, per-file movie NFOs, Unicode paths, unique parents,
  alternating parents, extra-file early returns and one-file scans. Depth counts
  the source root. Separate output checks cover accepted depth 64 and rejected
  depth 65, plus decomposed Unicode folder names.
- Both variants calibrate once per scenario. A shared iteration count targets
  100 ms for the faster calibration sample. Eight alternating AB/BA pairs use
  fresh processes. Every wall/CPU sample and every calibration is retained;
  no outlier removal or selective reruns occur within a campaign.
- Complete recognized fields and derived display values, plus `filesRead`, must
  match for every fixture. Each timed process also checks its final outputs and
  read count against that complete differential result.
- Reports give medians of each variant's scan times and medians of paired
  percentage changes separately. These two percentage calculations need not
  agree. Raw rows retain minimum sample durations and adverse controls.

## Evidence and interpretation

No performance result is claimed by this initial harness commit. Preserve
completed `evidence/` directories and add the observed results before presenting
the optimization as successful. The native workflow uploads source hashes,
compiler/host details, four test logs, complete outputs, calibration, all timing
rows and summary statistics.

These component measurements do not establish whole-player responsiveness,
frame rate, energy use, cold-disk latency or worst-case latency. The bounded plan
trades a small amount of per-reader memory for less repeated URL/path work;
allocation/RSS effects are not measured by this timing harness.
