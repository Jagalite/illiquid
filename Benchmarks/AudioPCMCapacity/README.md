# Audio PCM allocation capacity

This focused benchmark compares the two PCM allocation blocks in `AudioDecoder.swift`
against main commit `af1c1add701e49b355448cf8983eaed1e7623108`. It extracts each block
verbatim, plus the unchanged production sanitizer, into debug and release programs.
No FFmpeg or presentation code is substituted into the shipping application.

```sh
python3 Benchmarks/AudioPCMCapacity/run.py \
  --output /tmp/audio-pcm-capacity --pairs 6 --target-ms 120
```

The primary metric is allocator live bytes with 48 retained buffers, after finite
PCM is written, the result is shortened, and the production sanitizer runs. Array
storage is reserved before the initial reading. A second reading after releasing
all buffers checks whether the measured storage is released. macOS uses
`malloc_zone_statistics(NULL).size_in_use`; Linux uses `mallinfo2` only as a portable
smoke check. Neither metric measures RSS or the whole player's footprint.

Every measurement starts a fresh process; six pairs alternate baseline/candidate
order. Equal iteration counts are calibrated per workload. CPU and wall time cover
allocation, a deterministic finite PCM write, shrink, sanitization and release.
They exclude decoding and resampling and must not be described as playback speed.

Both conversion and drain allocations are exercised with stereo, 5.1 and 7.1 PCM,
1,024/8,192 output samples, and zero or 32 excess capacity samples. Additional
controls cover inline storage, empty output, and an extreme 8,192-to-one sample
shrink. Debug and release checks inspect every initial zero byte and every output
sample after invalid-value sanitization, verify replacement counts, and verify
copy-on-write preservation. An independent full-byte check covers the unique-storage
finite PCM path used by measurements. Result hashes supplement explicit byte checks.

The output contains source snapshots and hashes, compiler commands, parity receipts,
calibration, all individual measurements, and paired summaries. Native macOS results
and the full application's native audio tests are required to qualify a change.
