# Packet-progress playback laboratory

Experimental, not enabled in the player. This directory evaluates a secondary-reader result that preserves every valid packet's timing while avoiding a Swift packet wrapper and retained payload for unselected streams. It does **not** discard streams, inject AVIO errors, reduce probing, change decoder threads or shrink buffers. Existing PR #5 queue/recovery/ownership fixes are the baseline, not new gains.

## Reproduce

Use a complete checkout based on PR #5 commit `3c7b84c425cf15cdbaccfd2b4829f3181130963f`, Linux/glibc, Swift 6, Clang, make, Python 3.10+, and FFmpeg CLI with libx264/AAC/ASS/mov_text encoders. The measured environment used Swift 6.2.1 and CLI 7.1.5; probes link a separately built FFmpeg 8.1.2. The minimized library disables network and external x86 assembly; it is not the macOS production dependency configuration.

All output paths must be NEW. Commands operate on disposable generated data, never installed player state or user media. Compile and generate fixtures before running measurements; run only one measurement driver at a time.

```sh
B=Benchmarks/PlaybackPacketProgress
bash "$B/build-ffmpeg.sh" "$PWD" /tmp/illiquid-progress-ffmpeg
python3 "$B/prepare.py" --repo "$PWD" \
  --prefix /tmp/illiquid-progress-ffmpeg/prefix --output /tmp/illiquid-progress-build
python3 "$B/generate.py" --output /tmp/illiquid-progress-fixtures
for variant in baseline candidate; do
  /tmp/illiquid-progress-build/$variant-regression /tmp/illiquid-progress-fixtures/sparse.mkv
  /tmp/illiquid-progress-build/$variant-regression-debug /tmp/illiquid-progress-fixtures/sparse.mkv
done
python3 "$B/run.py" --build /tmp/illiquid-progress-build \
  --fixtures /tmp/illiquid-progress-fixtures --output /tmp/illiquid-progress-results --repeats 7
python3 "$B/check.py" --evidence /tmp/illiquid-progress-results \
  --build /tmp/illiquid-progress-build --self-test
```

`prepare.py` rejects changed demux/packet baseline blobs. It applies `native-candidate.patch` **only inside the new build directory**, never to the checkout. The proposed MediaSession integration is included for native review, not compiled into a running player here. Do not apply that nested patch as a release-ready optimization.

The harness compiles the actual complete input executor, packet owner, retry policy, read-ahead gate and queue. Demux open/probe/read/seek are real FFmpeg calls. A narrow stream-index/start-time projection substitutes for UI media metadata, CoreMedia-only time helpers are omitted, and native subtitle acquisition is an uncalled trap. No audio/subtitle decoder, VideoToolbox, renderer, GUI or energy measurement is executed.

The main `readPacket` implementation is checked byte-for-byte unchanged. The experimental secondary loop duplicates its retry/EOF logic to avoid charging every main-reader call for a new enum; remove duplication safely before production adoption. Regression-only fault injection is absent from timed binaries. Timing omits packet hashing and allocation interposition; verification and allocation builds are separate.

## Evidence

`RESULTS.json` contains compact medians, controls, provenance and the existing native-CI summary. Complete new raw rows, verification packet/event receipts, commands, build hashes, negative prototype results and additional ownership tests accompany the downloadable research bundle. `check.py` validates actual AB/BA executable order and rejects damaged receipts; it imposes no speedup threshold.

The malloc-family meter excludes aligned allocation APIs and cannot establish total FFmpeg allocations, live/peak heap or physical footprint. Logical AVIO byte counts include OS-cache hits. Progress yields at a completed packet boundary, not within an arbitrarily long read/parse; no strict byte or wall-time bound is promised.

Native format/sample results were retrieved from existing successful macOS CI run `38989970053`, artifact `12084653162`, not run on this Linux host. Its 70 timing rows and 85 checks cover CoreMedia construction only, not renderer enqueue, visible output or a physical Mac's energy behavior.

See `Documentation/PLAYBACK_PACKET_PROGRESS_RESEARCH.md` for decisions and qualification gates. Nothing in this directory changes production playback defaults.
