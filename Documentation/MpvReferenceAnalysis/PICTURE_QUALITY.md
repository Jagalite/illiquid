# Picture quality

## Verdict

Keep Apple's direct-display route for the initial native architecture. The
highest-value work is correct metadata, software fallback, dynamic
reconfiguration, and physical HDR/EDR validation—not advanced shader parity.
Consider a Direct Metal/libplacebo presenter only if pinned tests demonstrate a
material, common failure in Apple scaling, HDR-to-SDR/gamut mapping, deinterlace,
or HDR subtitle composition that cannot be fixed through metadata or a focused
stage.

## Where visible differences come from

| Cause | Examples | Owner |
| --- | --- | --- |
| Decode samples differ | hardware decoder bug, corrupt concealment, unsupported profile | FFmpeg + VideoToolbox, selected by Superplayr |
| Metadata differs | wrong range, matrix, primaries, transfer, chroma location, SAR, rotation, mastering/CLL | FFmpeg extraction + Superplayr propagation + Apple interpretation |
| Presentation differs | scaling, chroma reconstruction, tone/gamut mapping, EDR, dithering | Apple route or libplacebo/Metal route |
| Feature absent | deinterlace, screenshot transform, bitmap/HDR subtitle composition | Superplayr architecture |
| Enhancement differs | deband, grain, high-end scaler, user shader | libplacebo/mpv optional processing |

Correct decoders should normally produce equivalent decoded samples. “mpv looks
better” most often means a metadata/presentation/enhancement difference, not
that mpv owns a better H.264 decoder.

## Baseline Apple direct-display route (`fbdc699`)

```text
FFmpeg AVFrame
  |-- VideoToolbox frame -> retained native CVPixelBuffer
  `-- software frame -> swscale -> 8-bit BGRA IOSurface CVPixelBuffer
       -> CV/format attachments
       -> CMSampleBuffer
       -> AVSampleBufferVideoRenderer / AVSampleBufferDisplayLayer
       -> Core Animation / display pipeline
```

Strengths:

- application-level near-zero-copy for actual VT-backed frames;
- Apple owns device-specific display integration and platform tone mapping;
- PQ/HLG, BT.2020, mastering-display, and content-light values are partially
  propagated;
- direct sample-buffer presentation supports native PiP and a shared timebase;
- no new GPU renderer dependency or shader maintenance surface.

Limitations:

- Apple's exact scale/chroma/tone/gamut/dither algorithms are opaque and vary by
  OS/hardware/display;
- software fallback always becomes 8-bit BGRA with bilinear swscale;
- `sws_setColorspaceDetails` is not used, so software matrix/range correctness
  is not explicit;
- FFmpeg's VT output already carries frame pixel-aspect/chroma/colorspace
  attachments, but Superplayr does not inspect or validate them and its
  app-created software buffer has no equivalent aspect/chroma policy;
- clean aperture, interlace/field metadata, static Swift geometry, and
  midstream frame-level changes are not fully handled;
- Superplayr's manual `applyColorMetadata` mappings (and its software path)
  cover only common transfer/primaries/matrix enums; retained VT-backed buffers
  can already carry FFmpeg's broader attachment mapping;
- `unspecified` color enum values and full-range inference are handled
  ambiguously;
- BT.2020 primaries alone are currently treated as HDR by product status;
- separate AppKit subtitle composition has no declared EDR reference white;
- no screenshot path reproduces the media transform/composition.

Sources: `Superplayr:Media/VideoDecoder.swift::makeFrame,
applyColorMetadata`; `CFFmpeg/include/ffmpeg_shim.h::
superplayr_copy_frame_to_bgra_pixel_buffer`;
`Presentation/SampleBufferVideoPresenter.swift`;
`Presentation/NativePlayerView.swift`; `Media/MediaSession.swift::snapshot`;
`Production/NativeAppleBackend.swift::emitVideoStatus @
fbdc699627bebf4298a630004ca31a31b0ec5df4`.

## What FFmpeg and VideoToolbox already own

FFmpeg maps codec depth/subsampling to VideoToolbox-compatible pixel formats,
creates the decompression session, and returns retained CVPixelBuffer-backed
frames. Its VideoToolbox hardware-context helpers can set/remove pixel aspect,
chroma location, YCbCr matrix, primaries, transfer, CGColorSpace/gamma, and
range-associated pixel formats. Removal of unspecified attachments prevents
metadata leaking from an earlier frame.

Sources: `FFmpeg:libavcodec/videotoolbox.c::
videotoolbox_best_pixel_format,videotoolbox_buffer_create,
videotoolbox_postproc_frame`;
`FFmpeg:libavutil/hwcontext_videotoolbox.c::av_vt_pixbuf_set_attachments @
162c2784f90969ae53c1f4aa36d22ef93945a293` (LGPL-2.1-or-later).

Superplayr should prefer those mappings where suitable and layer its own
rotation/HDR side-data/sample-description policy deliberately. It must not
retain previous-frame metadata when a new frame is unspecified.

Historical [mpv issue #6546](https://github.com/mpv-player/mpv/issues/6546)
showed a full-range VideoToolbox result appearing limited. The fix landed in
FFmpeg integration, not mpv's player core. The lesson is to pin and test the
dependency path, not add compensating heuristics without sample evidence.

## What libplacebo adds

At the pinned revision, libplacebo's renderer performs an explicit pipeline:

1. per-plane deinterlace/deband/grain;
2. chroma-aware plane alignment, reconstruction, resampling, and merge;
3. bit-depth/range normalization and representation decode to RGB;
4. sigmoidized upscale where appropriate and linear-light downscale;
5. transfer/primaries/tone/gamut mapping, LUT/ICC, and HDR peak handling;
6. target encoding, rotation, output-plane sampling, and dithering;
7. color-managed overlay mapping and alpha composition.

Source: `libplacebo:src/renderer.c::pass_read_image,pass_scale_main,
pass_convert_colors,pass_output_target,draw_overlays @
a7a18af88ff0a17c04840dcb3246047bb6b46df3` (LGPL-2.1-or-later).

Its defaults use Lanczos upscale, Hermite downscale, oversample frame mixing,
sigmoid, blue-noise dither, and HDR peak detection; deband is disabled. The
high-quality preset uses costlier EWA LanczosSharp and deband and explicitly
targets stronger discrete GPUs. Those defaults are not a product mandate for a
Mac media player.

libplacebo explicitly infers missing metadata—HD 709, SD 601, YCbCr limited, RGB
full, missing primaries 709, missing transfer BT.1886—and records/falls back when
GPU capabilities are insufficient. Inference is useful as a diagnostic policy,
but it is never as reliable as correct metadata.

Sources: `libplacebo:src/colorspace.c::pl_color_system_guess_ycbcr,
pl_color_primaries_guess,pl_color_levels_guess,pl_color_space_infer,
pl_color_repr_decode`; `libplacebo:src/renderer.c::pl_render_default_params @`
the pinned libplacebo SHA (LGPL-2.1-or-later).

## Feature-by-feature comparison

| Area | Apple direct-display expectation | mpv/libplacebo behavior | Baseline Superplayr (`fbdc699`) | Product decision |
| --- | --- | --- | --- | --- |
| Native-size SDR | Usually direct, high-quality platform presentation | explicit range/color conversion; little scaler value at 1:1 | likely good on VT path, not formally color-patch tested | **P0 validate**, retain Apple |
| Upscaling | opaque platform scaler | selectable Lanczos/EWA, chroma scaler, sigmoid | Apple default; software preconvert bilinear only | **P1 compare** common 720p/1080p to 4K; Metal only if visibly/materially worse |
| Downscaling | opaque platform scaler | linear-light, anti-aliased downscale | Apple default | **P1 compare** 4K→1080p/window |
| Chroma reconstruction/location | platform uses CV metadata/pixel format | separate chroma scaler and explicit offsets; missing defaults left | FFmpeg attaches VT-frame chroma location; software parity and effective Apple interpretation are unverified | **P0 inspect/propagate/test** MPEG1/MPEG2/left/center clips |
| Limited/full range | pixel format + attachments/platform interpretation | explicit normalization for many representations | VT likely relies on fourcc; software path not explicit | **P0** BT.601/709/2020 limited/full patches |
| BT.601/709/2020 matrix | Apple attachments/format description | explicit matrices including constant-luminance and ICtCp | common mappings only; software conversion risk | **P0** metadata-stripped and tagged fixtures |
| PQ HDR10 | Apple EDR/tone-map path | explicit PQ linearization, metadata/peak/tone-map algorithms | PQ/BT.2020/HDR10 data partially attached | **P0 physical** EDR and SDR displays |
| HLG | Apple HLG/EDR path | explicit HLG nominal luminance/mapping | HLG transfer attached | **P0 physical** EDR and SDR displays |
| EDR presentation | Core Animation/display dependent | target display colorspace under renderer control | reports screen headroom, not proof layer uses it correctly | **P0 physical**, log display/layer state |
| HDR→SDR | platform automatic behavior | explicit tone/gamut mapper and knobs | no explicit policy or acceptance data | delegate to Apple first; **P1 gate** |
| Gamut mapping | platform automatic/opaque | explicit perceptual mapping | no direct control | same as HDR→SDR gate |
| Dithering | platform/display internal, opaque | blue-noise default; temporal off; error diffusion optional/expensive | no explicit dither | **P2 defer** unless gradient fixture shows banding |
| Debanding | no app control | optional; disabled default; can damage texture | absent | **P2 opt-in only** after evidence |
| Deinterlacing | platform behavior not explicit for this decoded-frame route | weave/bob/YADIF/BWDIF with temporal reference requirements | no field detection/policy | **P0 detect**, validate common interlace; focused stage or unsupported |
| Subtitle composition | separate Apple/UI composition possible | overlay color space and blend order explicit | separate SDR AppKit overlay | **P0 define HDR subtitle white**; test PiP/screenshot inclusion |
| Screenshots | layer capture not a stable decoded-color contract | rendered frame can be captured with same pipeline | unsupported | **P1/P2 separate capture path** if product needs it |
| Rotation | layer/geometry transform | renderer rotates output | static display-matrix rotation applied | **P0 test** all 90° steps/mirror/dynamic metadata |
| Pixel aspect ratio | format/pixel attachments required | explicit source/sample geometry | FFmpeg attaches emitted-frame PAR on VT; Swift UI geometry is static and software/sample-description parity is unverified | **P0 inspect/fix/test** anamorphic clips |
| Film grain | decoder/platform dependent | can export/apply codec grain on GPU | no explicit policy | defer unless decoded samples prove wrong |
| Dolby Vision | platform/FFmpeg complexity | libplacebo supports some representation mapping, not every enhancement layer | not defined | explicit unsupported/limited capability; no FEL target |

## Chroma, range, and color acceptance fixtures

Generate lossless or mathematically checkable clips with:

- BT.601, BT.709, BT.2020 non-constant and constant-luminance matrices;
- limited and full range, including 10-bit code-value ramps;
- 4:2:0 chroma siting variants and saturated one-pixel boundaries;
- RGB/full-range control clips;
- tagged, deliberately untagged, and incorrectly tagged variants;
- PQ with known mastering/MaxCLL values and over-target highlights;
- HLG ramps and reference gray;
- SDR wide-gamut BT.2020 to prevent “BT.2020 means HDR” logic;
- anamorphic SAR and clean-aperture crops;
- interlaced motion with top/bottom field order.

For software decode, inspect pixel hashes/code values before Apple presentation
and require explicit swscale matrix/range configuration. For VT/direct display,
capture objective renderer/display metrics where Apple exposes them and add a
physical visual grade against QuickTime and pinned mpv on the same display.

## HDR subtitle policy

libass outputs SDR-intended colors/masks and does not know video mastering,
display headroom, or tone-map path. A separate AppKit white can look dim,
overbright, or double-mapped over HDR.

The initial Apple presenter should define:

- an SDR subtitle reference-white target in nits/EDR units;
- whether overlay color is display-referred or media-referred;
- how SDR overlay is mapped on SDR, EDR, and externally tone-mapped output;
- alpha blending space;
- whether subtitles are included in PiP and screenshots.

If Apple layer composition cannot meet the acceptance matrix, that is a strong,
specific justification for a unified Metal compositor. It is not yet evidence
for replacing the entire player core.

## Value ranking

### P0: correctness before architecture exit

1. Propagate and diagnose range, matrix, primaries, transfer, bit depth, pixel
   format, chroma location, SAR, clean aperture, rotation, and interlace.
2. Make software fallback color-explicit and retain precision where possible.
3. Atomically reconfigure on midstream size/pixel/color changes.
4. Validate SDR, PQ, HLG, EDR, and HDR→SDR on physical internal/external displays.
5. Define HDR subtitle white/composition and validate rotation/viewport.

### P1: common visible value

6. Compare native-size, upscale, downscale, and chroma clips at real window sizes.
7. Evaluate Apple HDR→SDR/gamut behavior against pinned mpv under the same
   display settings.
8. Add a correct screenshot pipeline only if it is a real product feature.
9. Add a narrowly scoped deinterlacer if common interlaced fixtures fail.

### P2: optional polish

10. Opt-in deband after evidence.
11. Explicit dither only if objective gradients fail.
12. High-end scaler/tone-map controls only for demonstrated target-user value.

### Intentionally omit/defer

- arbitrary user shaders and shader chains;
- broad LUT/ICC user ecosystem in the first architecture;
- frame interpolation/motion smoothing;
- extensive tone-map knobs;
- Dolby Vision FEL;
- exotic output representations;
- libplacebo merely for feature-count parity.

## Direct Metal decision gate

Do not begin a Metal presenter until all are true:

1. the state/generation/EOF refactor is complete;
2. metadata propagation is correct on both VT and software paths;
3. a pinned differential fixture shows a repeatable Apple failure;
4. the failure is common and visibly meaningful to target users;
5. focused Apple configuration/preprocessing cannot meet the threshold;
6. Metal prototype demonstrates the fix without regressing A/V sync, power,
   PiP, accessibility, memory, or teardown;
7. libplacebo licensing/build/distribution impact is approved if used.

Until then, Apple direct display is the lower-risk and product-appropriate
presenter.
