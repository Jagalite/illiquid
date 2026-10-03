#!/usr/bin/env python3
"""Author the small missing planar qualification fixtures with local FFmpeg."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def encode(path, size, options, duration=3):
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
        "-i", f"testsrc2=size={size}:rate=24:duration={duration}", "-an",
        *options, str(path),
    ], check=True, timeout=60)


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    av1 = ["-c:v", "libsvtav1", "-preset", "12", "-svtav1-params", "lp=2",
           "-crf", "35", "-color_primaries", "bt709", "-color_trc", "bt709",
           "-colorspace", "bt709", "-chroma_sample_location", "left"]
    for name, pixel_format, full in [
        ("av1-8bit-1080p.mkv", "yuv420p", False),
        ("av1-10bit.mkv", "yuv420p10le", False),
        ("av1-10bit-full-range.mkv", "yuv420p10le", True),
    ]:
        encode(output / name, "1920x1080", av1 + [
            "-pix_fmt", pixel_format, "-color_range", "pc" if full else "tv"])
    encode(output / "full-range-anamorphic.mkv", "640x360", [
        "-c:v", "ffv1", "-vf", "scale=in_range=tv:out_range=pc,setsar=4/3",
        "-pix_fmt", "yuv420p", "-color_range", "pc", "-chroma_sample_location", "center"])
    encode(output / "unsupported-444.mkv", "640x360", [
        "-c:v", "ffv1", "-pix_fmt", "yuv444p", "-color_range", "tv"])
    with tempfile.TemporaryDirectory(prefix="platinum-planar-") as work:
        parts = []
        for index, size in enumerate(["640x360", "960x540"]):
            part = Path(work) / f"part-{index}.ts"
            encode(part, size, ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                                "-output_ts_offset", str(index * 2)], duration=2)
            parts.append(part.read_bytes())
        (output / "resolution-transition.ts").write_bytes(b"".join(parts))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
