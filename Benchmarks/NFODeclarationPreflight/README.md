# NFO declaration preflight

This study measures complete `NFOMetadataHints.parse` calls. The parser currently
searches every accepted UTF-8 document twice using locale-aware substring matching
to reject DOCTYPE and ENTITY declarations. The candidate first checks whether an
ASCII document contains an exclamation mark. Documents containing either a
non-ASCII byte or `!` retain the exact original localized searches.

The byte limit, UTF-8 validation, XML parser configuration, field selection,
nesting limit, and per-field text limit are unchanged. No filesystem or playback
performance claim is implied by an in-memory parser benchmark.

## Reproduce

Use Swift 6.1+ and Python 3.10+:

```sh
python3 Benchmarks/NFODeclarationPreflight/run.py \
  --pairs 8 --target-ms 100 --output /tmp/illiquid-nfo-preflight
```

Use a fresh output directory for every run. Follow root `AGENTS.md`: submit the
whole command through Kyoto on a workstation where it is available, then inspect
the job, logs, and completion. The isolated GitHub runners have no shared Kyoto
queue; the harness explains that limitation and serializes all of its builds.

## Method

- Frozen baseline: `NFOMetadataHints.swift` at
  `ea2ff568237e2667f7b1aeee67b11a44ebe95b72`, Git blob
  `051c475fd33bcd16ec33f6b4b93ee98fffdb21d3`.
- Both variants use the same current support sources and tests, captured once.
  Only the parser differs. Native macOS copies are unmodified. Linux adaptations
  match the existing NFO regression harness: FoundationXML/Glibc imports and a
  directory hint for legacy test fixture URLs. Every adaptation and hash is recorded.
- Both parsers run six regression suites in debug and release. A separate
  differential corpus compares every metadata field or rejection result.
- Optimized production modules are compiled as dynamic libraries separately from
  the benchmark driver, without cross-module optimization.
- Fixtures are prepared outside timing. Each fresh process performs three
  untimed warmups and consumes every result inside the timed loop.
- Baseline calibration selects one shared iteration count per workload. Eight
  pairs alternate baseline-first and candidate-first order. All calibration and
  measurement observations are retained.
- Ordinary movie, episode, show, and ASCII plot workloads are accompanied by
  Unicode, exclamation, CDATA, comment, rejection, and late-fallback controls.

The workflow runs measurements on branch pushes and tests plus differential
checks for pull requests. Raw evidence is emitted in job logs and uploaded as an
artifact. Final results will be added after successful execution; the change is
not yet qualified.
