# Playback core Stage 0 baseline

Captured: 2026-07-19

Superplayr revision: `fbdc699627bebf4298a630004ca31a31b0ec5df4`

## Toolchain and native dependencies

- macOS target: arm64, macOS 26
- Xcode: 26.6 (`17F113`)
- Swift: 6.3.3 (`swiftlang-6.3.3.1.3`)
- FFmpeg: 8.1.2 (`libavformat` 62.12.102)
- libass: 0.17.5
- mpv: 0.42.0 (`libmpv` 2.5.0), legacy comparison path only

## Development qualification run

Command:

```sh
SUPERPLAYR_POC_LONG_RUN_SECONDS=20 \
SUPERPLAYR_POC_QUALIFICATION_DURATION=30 \
Scripts/run-native-poc-qualification.sh
```

Results:

- generated the complete local fixture corpus;
- existing suite passed: 79 tests in 16 suites;
- real H.264, HEVC, VP9, AV1, AAC, FLAC, Opus, Vorbis, MP3, PCM, HDR/P010,
  rotation, multichannel, subtitle, seek, replacement, and teardown fixtures passed;
- three 20-second A/V runs passed;
- ASan playback/reopen run passed;
- TSan playback/reopen run passed;
- production `Superplayr` build passed;
- `SuperplayrArchitectureCheck` passed.

Observed long-run summaries:

| Fixture | Presented | Steady drift | Memory growth | Submitted |
| --- | ---: | ---: | ---: | ---: |
| `long-h264-av-sync.mkv` | 19.94 s | -0.038 s | 16 KiB | 482 |
| `long-hevc-p010-av-sync.mkv` | 19.96 s | -0.016 s | 48 KiB | 482 |
| `long-vfr-av-sync.mkv` | 20.05 s | +0.082 s | 496 KiB | 252 |

The harness repeats the selected long gate after the full suite. The repeated run also
passed. These are submission-horizon diagnostics, not proof of visible/audible A/V sync.

`leaks` reported 14,400 bytes in 288 allocations rooted in
`com.apple.linkd.autoShortcut`/AppIntents XPC objects. This matches the existing documented
system-framework baseline and did not identify a playback-owned allocation root.

## Gate interpretation

This is the Stage 0 development baseline used for the pure-core extraction. The repository's
default 60-second long-run duration remains the cumulative qualification gate before a
behavior-authority stage is enabled. Fixture-required mode is now explicit in the
qualification script so a future CI run cannot silently pass by skipping missing media.
