#!/usr/bin/env python3
"""Inventory real libass mask dimensions without reading native bitmap padding.

Uses the existing compositor feature-matrix ASS fixture. This records payload
byte counts across sampled frames, not whole-player RSS or simultaneous storage.
"""

from __future__ import annotations

import argparse
import ctypes as C
import ctypes.util
import hashlib
import json
from pathlib import Path
import platform
import textwrap


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = "Tests/IlliquidNativePlaybackTests/MetalASSSubtitleCompositorTests.swift"


class Image(C.Structure):
    pass


Image._fields_ = [
    ("w", C.c_int), ("h", C.c_int), ("stride", C.c_int),
    ("bitmap", C.POINTER(C.c_ubyte)), ("color", C.c_uint32),
    ("dst_x", C.c_int), ("dst_y", C.c_int),
    ("next", C.POINTER(Image)), ("type", C.c_int),
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", help="libass shared library; defaults to platform lookup")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    library_path = args.library or ctypes.util.find_library("ass")
    if not library_path:
        raise SystemExit("libass was not found; pass --library /path/to/libass")
    lib = C.CDLL(library_path)

    def bind(name, result, *arguments):
        function = getattr(lib, name)
        function.restype = result
        function.argtypes = list(arguments)
        return function

    version = bind("ass_library_version", C.c_int)()
    library_init = bind("ass_library_init", C.c_void_p)
    library_done = bind("ass_library_done", None, C.c_void_p)
    renderer_init = bind("ass_renderer_init", C.c_void_p, C.c_void_p)
    renderer_done = bind("ass_renderer_done", None, C.c_void_p)
    free_track = bind("ass_free_track", None, C.c_void_p)
    read_memory = bind("ass_read_memory", C.c_void_p, C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p)
    set_frame_size = bind("ass_set_frame_size", None, C.c_void_p, C.c_int, C.c_int)
    set_storage_size = bind("ass_set_storage_size", None, C.c_void_p, C.c_int, C.c_int)
    set_fonts = bind("ass_set_fonts", None, C.c_void_p, C.c_char_p, C.c_char_p, C.c_int, C.c_char_p, C.c_int)
    render = bind("ass_render_frame", C.POINTER(Image), C.c_void_p, C.c_void_p, C.c_longlong, C.POINTER(C.c_int))

    source = (ROOT / FIXTURE).read_text()
    start = '    private static let featureMatrix = #"""\n'
    if source.count(start) != 1:
        raise SystemExit("Feature-matrix source boundary changed")
    fixture = textwrap.dedent(source.split(start, 1)[1].split('    """#', 1)[0]).encode()
    library = library_init()
    if not library:
        raise RuntimeError("ass_library_init failed")
    renderer = track = None
    frames = []
    shapes = set()
    try:
        renderer = renderer_init(library)
        if not renderer:
            raise RuntimeError("ass_renderer_init failed")
        # ASS_FONTPROVIDER_AUTODETECT is 1 in the public libass ABI.
        set_fonts(renderer, None, b"sans-serif", 1, None, 1)
        storage = C.create_string_buffer(fixture)
        track = read_memory(library, storage, len(fixture), None)
        if not track:
            raise RuntimeError("ass_read_memory failed")
        for width, height in [(640, 360), (1280, 720), (1920, 1080), (3840, 2160)]:
            set_frame_size(renderer, width, height)
            set_storage_size(renderer, width, height)
            for milliseconds in [250, 750, 1250, 1750, 2500]:
                changed = C.c_int()
                image = render(renderer, track, milliseconds, C.byref(changed))
                masks = []
                while image:
                    value = image.contents
                    if value.w > 0 and value.h > 0 and value.bitmap:
                        if value.stride < value.w:
                            raise RuntimeError("Invalid native image stride")
                        masks.append({"width": value.w, "height": value.h, "stride": value.stride})
                        shapes.add((value.w, value.h, value.stride))
                    image = value.next
                if not masks:
                    raise RuntimeError("Feature matrix produced no masks; check font availability")
                padded = sum(m["stride"] * m["height"] for m in masks)
                compact = sum(m["width"] * m["height"] for m in masks)
                frames.append({"canvas": [width, height], "milliseconds": milliseconds,
                               "images": len(masks), "baseline_payload_bytes": padded,
                               "compact_payload_bytes": compact,
                               "reduction_percent": 100 * (padded - compact) / padded,
                               "masks": masks})
    finally:
        if track:
            free_track(track)
        if renderer:
            renderer_done(renderer)
        library_done(library)

    padded = sum(f["baseline_payload_bytes"] for f in frames)
    compact = sum(f["compact_payload_bytes"] for f in frames)
    report = {
        "platform": platform.platform(), "library": library_path,
        "libass_version_hex": hex(version), "fixture_source": FIXTURE,
        "fixture_source_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "ass_fixture_sha256": hashlib.sha256(fixture).hexdigest(),
        "frame_count": len(frames), "region_count": sum(f["images"] for f in frames),
        "baseline_payload_bytes_sum": padded, "compact_payload_bytes_sum": compact,
        "reduction_percent": 100 * (padded - compact) / padded, "frames": frames,
        "scope": "Summed copied mask payloads over sampled frames, not simultaneous retained memory or RSS.",
    }
    (args.output / "libass-inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    ordered = sorted(shapes, key=lambda shape: (shape[0] * shape[1], shape))
    # Fixed quantiles of all observed shapes, avoiding selection by improvement.
    selected = sorted({ordered[(len(ordered) - 1) * q // 4] for q in range(5)})
    cases = [{"name": f"libass_{w}x{h}_stride{s}", "width": w, "height": h, "stride": s}
             for w, h, s in selected]
    (args.output / "libass-cases.json").write_text(json.dumps(cases, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "frames"}, indent=2))


if __name__ == "__main__":
    main()
