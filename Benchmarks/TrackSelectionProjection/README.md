# Track selection during authority projection

This experiment measures `PlaybackState.applyAuthorityProjection` through the
production `PlaybackViewSnapshot` and `PlaybackViewStore.publish` callback.
The baseline is `a2de305c8dbcaa81aac1477df7c9a0017c14eae3`.

```sh
python3 Benchmarks/TrackSelectionProjection/run.py \
  --pairs 8 --output /tmp/illiquid-track-selection-projection
```

The output directory must be absent or empty. `--swiftc` selects a compiler;
`--tests-only` omits timing, and `--quick --pairs 4` runs a smaller preliminary
cohort. The macOS workflow uses Xcode 26.6 and the full cohort.

## Method

- Compile the actual selected production files into a separate static
  `IlliquidCore` module. Baseline files come from the pinned Git commit;
  candidate files come from the working tree. Source receipts require that
  only `PlaybackState.swift` differs. Both sides use identical tests and client
  code. Linux guards the `CoreGraphics` import because Foundation supplies the
  geometry types; no executable implementation is substituted.
- Run the existing state-publication and new track-projection scenarios in
  debug and release for both implementations. Compare 4,000 deterministic
  mixed-operation steps per configuration, including complete track metadata,
  catalogue order, positions, and publication counts. Each process also checks
  its complete published view against its state. This is a track-projection
  differential trace, not a comparison of every playback field across variants.
- Use optimized release code, 200 warmup calls, and fresh processes for timing.
  Alternate baseline/candidate then candidate/baseline with an even pair count.
  Construction, warmup, JSON encoding, and result checking are outside timing.
  Wall and process CPU times are recorded. No completed outlier is removed.
- Measure stable first/last selections, subtitles off, and missing selections
  at 1/0, 2/8, 8/32, 16/128, and 16/1,024 audio/subtitle tracks. The largest
  catalogue is a stress case, not a claim about typical files. Include changing
  selections and catalogue refreshes at three sizes, plus two disconnected
  callback controls. The full cohort contains 28 workloads and 448 observations
  with the default eight pairs.

`evidence/` contains environment and source hashes, compiler commands, behavior
test results, differential-trace digests, every timing row, and summaries.
Generated modules and executables stay outside the evidence directory.

## Scope

The measured operation is a synchronous model update and view-store publication.
It does not execute decoding, native rendering, SwiftUI layout, or presentation.
The harness advances synthetic positions by a quarter second but compresses
the updates into tight loops; it does not simulate paced live playback.
The runtime ordinarily emits position changes at approximately 4 Hz, with
additional projections for other events. Per-call savings are not whole-player
CPU, frame rate, energy, or visible-latency measurements.

An actual selection change conservatively invalidates its own cached result,
so the following projection resolves once more. Catalogue changes also resolve
again. These paths preserve synchronous callback semantics and appear in the
changing-selection/catalogue controls.

The native workflow additionally builds the full application graph and executes
the state/publication suites and selected coordinator restoration tests.
