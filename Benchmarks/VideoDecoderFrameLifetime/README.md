# Video decoder scratch-frame lifetime

`VideoDecoder.receiveFrames` reused an FFmpeg `AVFrame`, clearing it at the
start of the next loop iteration. Cancellation is checked before that cleanup.
A cancellation after output delivery, an exception from the output callback,
or an exception while constructing display output therefore left the current
native frame referenced until another receive operation or decoder teardown.
The existing `flush()` reset the codec and output pools without clearing this
scratch frame.

The change moves the existing cleanup into a loop-scoped `defer`. Every
received frame is released when that iteration finishes, including on a
throw, `continue`, or `break`. The normal loop still makes one explicit
`av_frame_unref` call per iteration. FFmpeg's `avcodec_receive_frame` also
clears the destination frame on entry, so moving the explicit call does not
change its initial state.

Only the scratch reference is retired. Software display output owns a
CoreVideo buffer with copied pixels, hardware output explicitly retains its
CoreVideo buffer, the deinterlacing graph references its input, and the seek
fallback clones the native frame. Those owners keep their existing lifetimes.

## What this experiment measures

The native test fixture supplies refcounted raw BGRA packets with a custom
FFmpeg buffer-free callback. A ledger records exactly when that allocation is
released. The test releases its own packet while keeping the decoder and any
delivered output alive. This distinguishes an actually freed allocation from
an empty-looking Swift container or an allocator's retained free pages.

The benchmark compares the original and revised decoder using the same
supporting production sources and test fixtures. The original decoder is
reconstructed by reversing the single cleanup change and verified against
the pinned revision `6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635`. The strict
regression tests remain candidate-only; a separate measurement suite observes
both lifetimes without weakening ordinary test expectations.

The affected cases are cancellation after delivery, a throwing frame
consumer, rejected output-capacity reservation, and a throwing timestamp
consumer. Normal frame delivery, normal timestamp delivery, and cancellation
before decoding are controls.
The ledger is inspected after packet release, a short idle interval, flush,
recovery decoding, and decoder destruction. Pixel content and frame metadata
are checked independently of the allocation counts.

This is a bounded ownership defect: the original implementation retains its
current scratch frame, not an ever-growing history of decoded frames. The
measurement isolates that native allocation. It does not measure whole-player
RSS, GPU residency, playback frame rate, or cancellation frequency in a media
corpus. Compressed codecs and hardware decoders may share a frame's buffers
with other legitimate owners; releasing the scratch reference does not imply
that every referenced byte immediately leaves physical memory.

## Reproduce

Use Apple Silicon macOS with the repository's pinned native SDK and Xcode
toolchain. The dedicated workflow installs and verifies those prerequisites
on an ephemeral runner.

```sh
python3 Benchmarks/VideoDecoderFrameLifetime/run.py \
  --output /tmp/video-frame-lifetime-results \
  --configuration release
```

The output directory must be new or empty. The runner preserves source hashes,
compiler and host information, executed commands, native test logs, and
per-case allocation and output receipts. It builds the native application
dependency graph; Linux parsing alone cannot qualify CoreVideo ownership.

## Evidence

The [native qualification run](https://github.com/Jagalite/illiquid/actions/runs/40101023090)
passed on an Apple M1 virtual machine running arm64 macOS 26.6.2 and Apple
Swift 6.3.3. Both decoder variants were built in release configuration against
the repository's pinned native SDK. The measured candidate source is commit
`45ff51c0d2f630f33c6c88b1838aee961005fd40`; the subsequent evidence commit
does not change the production fix, tests, or measurement runner.

The experiment produced **21 matched comparisons**: seven scenarios at each
of three frame sizes, with 42 individual allocation receipts. All four
interrupted-output scenarios showed the following result after the caller's
packet was released, while the decoder and any delivered output stayed alive:

| Raw BGRA frame | Original live allocation | Revised live allocation | Allocation released earlier |
| --- | ---: | ---: | ---: |
| 64 x 48 | 12,352 bytes | 0 bytes | 12.06 KiB |
| 1920 x 1080 | 8,294,464 bytes | 0 bytes | 7.91 MiB |
| 3840 x 2160 | 33,177,664 bytes | 0 bytes | 31.64 MiB |

These are observed allocation lifetimes from the custom FFmpeg free callback.
Each count includes 64 bytes of FFmpeg packet padding and excludes allocator
overhead, delivered CoreVideo buffers, and unrelated codec allocations.
The original decoder still held that allocation after a 25 ms idle interval
and after `flush()`. The recovery decode then released it.
The revised decoder released it before either idle or flush, with exactly
one free callback. The three control scenarios retained zero bytes in both
variants at every size.

All 21 comparisons matched full delivered pixel bytes and their SHA-256
hashes, captured frame metadata, timestamp output, and errors. Recovery
output also matched, and retained display pixels still matched the fixture
after flush, recovery, and decoder destruction.

The workflow also generates the existing eight-file timestamp corpus and
runs `VideoTimestampDiscoveryTests` and `VideoDeinterlacerTests` against the
candidate. These cover delayed B-frame output, temporal filtering, seek and
drain behavior, and throwing or cancelled consumers. The runner checks the
fixture hashes and required aliases before invoking the tests. All required
suites passed without skips:

| Candidate suite | Test declarations | Parameterized invocations |
| --- | ---: | ---: |
| Scratch-frame lifetime regression | 4 | 11 |
| Timestamp discovery | 7 | 25 |
| Decoder-owned BWDIF deinterlacing | 7 | 9 |
| Measurement probe | 1 | 1, containing 21 scenario/size cases |

Swift Testing reports **19 passed test declarations** for the candidate and
one for the baseline measurement probe. The regression suites account for
45 invocations, in addition to the measurement probe. These counts are not
additional independent repetitions of the 21 allocation comparisons.

The committed [summary](evidence/native/summary.json),
[run manifest](evidence/native/manifest.json),
[allocation receipts](evidence/native/receipts),
[native logs](evidence/native/logs), and
[measured source snapshots](evidence/native/sources) preserve the complete
results. The [bundle receipt](evidence/native/bundle-receipt.json) records the
workflow and job URLs and SHA-256 checksums of the verbatim evidence files.

The confirmed improvement is earlier release of one scratch-frame reference
and, in this controlled raw-video fixture, its underlying allocation. No
whole-player RSS, hardware-surface residency, throughput, or frame-rate
improvement is claimed. The temporal tests qualify output behavior; they do
not measure allocation savings for compressed or hardware decoding.

## Reference contracts

- [FFmpeg 8.1 AVFrame ownership and `av_frame_unref`](https://www.ffmpeg.org/doxygen/8.1/group__lavu__frame.html).
- [FFmpeg decoding API and `avcodec_receive_frame`](https://www.ffmpeg.org/doxygen/8.1/group__lavc__decoding.html).
- The unchanged output ownership paths are in `VideoDecoder.makeFrame`,
  `VideoDecoder.SeekPrerollFallback`, and `VideoDeinterlacer.process`.
