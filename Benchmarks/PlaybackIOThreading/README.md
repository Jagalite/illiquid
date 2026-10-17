# Playback input and decoder-mode laboratory

No production stream discard, AVIO size, decoder threading policy, or renderer change is enabled by these files. The retained queue fixes are in the production queue and regression target on PR #5. See `Documentation/PLAYBACK_IO_AND_THREADING_RESEARCH.md` for the experiment decisions, negative controls, and native qualification boundaries.

## Reproduce

Requires Linux, Clang, make, Python 3.10+, and an FFmpeg CLI with libx264/AAC/subtitle support for fixture generation. The measured CLI was 7.1.5; the probes link **8.1.2** built from the repository archive. External x86 assembly and unused components are disabled in this laboratory build. This is not a production dependency configuration or an Apple hardware benchmark.

Run from a complete checkout, substituting NEW disposable paths:

```sh
B=Benchmarks/PlaybackIOThreading
bash "$B/build-ffmpeg.sh" "$PWD" /tmp/illiquid-io-ffmpeg-new
python3 "$B/prepare.py" --prefix /tmp/illiquid-io-ffmpeg-new/prefix \
  --output /tmp/illiquid-io-lab-new
python3 "$B/generate_media.py" --work /tmp/illiquid-io-lab-new
python3 /tmp/illiquid-io-lab-new/new-experiments/run_io.py \
  --work /tmp/illiquid-io-lab-new --output /tmp/illiquid-io-lab-new/evidence/io-final
python3 /tmp/illiquid-io-lab-new/new-experiments/run_decode_modes.py \
  --work /tmp/illiquid-io-lab-new --output /tmp/illiquid-io-lab-new/evidence/decode-modes-final
python3 /tmp/illiquid-io-lab-new/new-experiments/run_audio_verify.py \
  --work /tmp/illiquid-io-lab-new --output /tmp/illiquid-io-lab-new/evidence/audio-new
cp /tmp/illiquid-io-lab-new/evidence/audio-new/audio-seek-verification.json \
  /tmp/illiquid-io-lab-new/evidence/audio-seek-verification.json
python3 /tmp/illiquid-io-lab-new/new-experiments/check_receipts.py \
  --work /tmp/illiquid-io-lab-new --output /tmp/illiquid-io-lab-new/evidence/check.json
```

Compilation and fixture creation must finish before measurements. Run the drivers serially, with no other benchmark in progress. Every output directory must be new; generation refuses an existing fixtures directory. These scripts do not launch Illiquid, alter installed preferences, modify system settings, or use network inputs. They read only the generated fixtures.

`check_receipts.py` validates this fixed fixture/protocol cohort. It intentionally preserves 18 packet/seek/frontier differences and 10 early AAC hash differences; passing that checker does NOT accept stream filtering for production. Different encoders, library builds or platforms may change these diagnostics: investigate and report those changes rather than deleting failing rows or rewriting expected values merely to pass. Min/max and individual observations remain authoritative; the scripts do not gate success on being faster.

The generator's only packaging change is accepting the workspace path and refusing existing fixture data. `executed-fixture-generator.py.txt` and the recorded command list preserve the original execution. Probe C/header sources and timing drivers are byte-identical to the measured versions. `run_audio_verify.py` was factored from the original invocation and all 36 outputs were reproduced exactly.

## Evidence and limitations

`RESULTS.json` is the compact summary. The downloadable research bundle additionally contains full rows, individual commands, manifests, the 640-check receipt result and prior queue-suite rerun logs. Sources, summaries, and run order are separate from UI or energy claims.

I/O native-mode `AVIOContext.bytes_read` counts logical input bytes including cache hits. Native read-callback fields are uninstrumented zeros, NOT zero I/O. Custom-AVIO modes count actual userspace `read`/`lseek` callbacks, still not physical device traffic. The optional 500-microsecond delay is injected before each callback, including EOF attempts. It is not a NAS benchmark.

Decode pacing delays video-packet submission to a synthetic 60 fps availability schedule relative to each phase; it is not visible presentation, live network delivery, or an Illiquid clock. Peak RSS is the whole Linux probe's `/proc/self/status` high-water estimate through decoding and seeks, not a live video-buffer ledger or macOS physical footprint. Pixel hashing and AAC verification are separate from timing. AAC sample-hash differences are not an audibility assessment.

Native acceptance requires the locked-SDK app graph, the playback regression suites, real source replacement/seek/audio/subtitle behavior, and matched visible playback/energy measurements. The fixture-gated packet-ownership test requires `ILLIQUID_PACKET_OWNERSHIP_FIXTURE`; an unset variable is an explicit skip, not a passing real-demux test.
