# Scalar preference mutation performance

Volume and playback-speed controls call `PlaybackPersistenceStore` synchronously.
The baseline rebuilds and sanitizes the complete `PlaybackPreferences` value for
every scalar update. That includes language normalization, de-duplication of both
track-language lists, and audio-device identifier normalization, even though those
fields have not changed.

The candidate reuses the existing scalar validators. Store initialization,
decoding, whole-preference saves, track-preference saves, and audio-device updates
already establish the validated state. The candidate changes neither the writer,
its 100 ms coalescing delay, the persistence schema, nor the public API.

## Reproduce

Requires Python 3 and Swift 6.1 or newer with bundled Swift Testing. The isolated
package has no external dependencies and does not build the macOS application.
Run builds through Kyoto when available, as required by `AGENTS.md`. The runner
serializes its builds and uses separate scratch directories for each variant.

```sh
git fetch --no-tags --depth=1 origin ea2ff568237e2667f7b1aeee67b11a44ebe95b72
python3 Benchmarks/ScalarPreferenceMutation/run.py \
  --mode all --pairs 6 --output /tmp/scalar-preference-results
```

Use `--mode test` for the baseline/candidate debug/release regression matrix, or
`--mode benchmark` for measurements only. `--swift /path/to/swift` selects a
toolchain. `--smoke` is an exploratory check and is not formal performance evidence.
The output directory must be new or empty.

The baseline's two focal files are read from commit
`ea2ff568237e2667f7b1aeee67b11a44ebe95b72`. Both variants use identical current
supporting sources, whose hashes and origins are recorded. The two unrelated enum
dependencies are extracted verbatim from their production declarations rather
than importing the full player/geometry graph. Neither the persistence store nor
the preference, language, or writer implementations are mocked.

## Measurement boundaries

Each paired measurement uses fresh serial processes, alternating baseline-first
and candidate-first order. All fixture creation, preference decoding, warmup,
write-gate setup, and result serialization are outside timing. The executable
consumes every mutation through the real store, writer and Foundation defaults.

| Mode | Timed work and controls |
| --- | --- |
| `noop` | Repeatedly set the existing scalar; require zero preference callbacks. |
| `blocked` | Change the scalar while one real defaults callback is gated after encoding. Require exactly the initial and latest writes after releasing the gate. |
| `burst` | A short ordinary burst, with no injected gate. Require the burst to finish in less than 50 ms, before the unchanged 100 ms writer delay, and no callback during timing. |
| `flushed` | Flush after every changed scalar. Require one callback per update; retain full-operation timing as an end-to-end component control. |

The primary modes use one aggregate caller timer. The flush-every-change control
also records a caller subtotal with individual timers, which includes timer
overhead and should not be compared directly to aggregate per-call values.
Caller time and total time through the final flush are reported separately.
`UserDefaults.set`/flush completion is not a measurement of physical disk writes
or crash durability.

The normal matrix has 0, 1, 3, and 32 valid language codes **per list**, for both
volume and speed. The zero-language fixture uses automatic audio output; populated
lists use a valid `usb-dac` identifier. The 32-code lists exercise the supported
bound and are stress cases. Flush controls use 0 and 3 codes per list. These are
synthetic preferences, not observations of a particular user's settings.

Every observation must preserve all preference fields, equal the full canonical
persisted payload, survive store reload, and leave the history bytes unchanged.
The runner compares complete baseline/candidate receipts and rejects unexpected
callback counts or timing contamination. It retains every successful observation,
source/binary hashes, command logs, tests, and paired ratios.

## Qualification scope

These measurements cover synchronous preference mutation and its persistence
boundary. They do not measure SwiftUI layout, event-to-audio latency, dropped
frames, the native playback backend, energy use, or whole-player memory. Linux
Foundation language-normalization costs must not be presented as macOS timings.

The focused CI workflow runs the same test and benchmark matrix on macOS. The
checked-in evidence and research report identify which platforms completed.
