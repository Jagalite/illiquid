#!/usr/bin/env python3
"""Generate small frame-step fixtures and an independent FFmpeg PTS oracle.

No ffprobe is required: the pinned native SDK supplies ffmpeg and showinfo.
Every command and oracle log is retained beside the generated media. Media is
synthetic; this helper never reads a user's library or installed app state.
"""

from __future__ import annotations

import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default=os.environ.get("FFMPEG", "ffmpeg"))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be absent or empty; existing evidence is not overwritten")
    output.mkdir(parents=True, exist_ok=True)
    commands: list[dict] = []

    def run(name: str, command: list[str]) -> str:
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        (output / f"{name}.log").write_text(completed.stdout + completed.stderr)
        commands.append({"name": name, "command": command, "returncode": completed.returncode})
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if completed.returncode:
            raise RuntimeError(f"{name} failed; see {output / (name + '.log')}")
        return completed.stdout + completed.stderr

    version = run("ffmpeg-version", [args.ffmpeg, "-version"]).splitlines()[0]
    common = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
              "-threads", "2", "-filter_threads", "2"]
    h264 = ["-an", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
            "-x264-params", "keyint=48:min-keyint=48:scenecut=0:bframes=3:b-adapt=0:threads=2"]
    source24 = ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=2"]
    specs = [
        ("timestamp-cfr-bframes.mkv", source24 + h264, 48, None, True),
        ("timestamp-vfr.mkv",
         ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=2",
          "-vf", "select='not(eq(mod(n,5),1))'", "-fps_mode", "vfr"] + h264,
         48, None, True),
        ("timestamp-nonzero.mkv",
         source24 + ["-vf", "setpts=PTS+2/TB", "-copyts"] + h264,
         48, None, True),
        ("timestamp-single.mp4",
         source24 + ["-frames:v", "1"] + h264,
         1, None, False),
    ]
    for field, top in [("tff", 1), ("bff", 0)]:
        mode = "interleave_top" if top else "interleave_bottom"
        # MPEG program streams exercise the real demuxer's coarse seek behavior;
        # indexed Matroska equivalents support absolute reader-boundary checks.
        for extension in ["mpg", "mkv"]:
            specs.append((
                f"timestamp-{field}.{extension}",
                ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=50:duration=2",
                 "-vf", f"tinterlace={mode},setfield={field}", "-r", "25",
                 "-an", "-c:v", "mpeg2video", "-threads", "2", "-g", "12", "-bf", "2",
                 "-q:v", "2", "-flags", "+ildct+ilme", "-top", str(top)],
                50, field, True,
            ))

    def oracle(name: str, *, deinterlace: bool) -> dict:
        path = output / name
        filters = "bwdif=mode=send_field:parity=auto:deint=interlaced,showinfo" if deinterlace else "showinfo"
        label = name + ("-fields" if deinterlace else "-source")
        log = run(label, [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "info",
                          "-threads", "2", "-filter_threads", "2", "-copyts", "-i", str(path),
                          "-map", "0:v:0", "-an", "-vf", filters, "-fps_mode", "passthrough",
                          "-f", "null", "-"])
        start = re.search(r"Duration:.*?start:\s*(-?[0-9.]+)", log)
        time_base = re.search(r"config in time_base:\s*(\d+)/(\d+)", log)
        frames = re.findall(r"\bn:\s*(\d+)\s+pts:\s*(-?\d+)\s+pts_time:.*?\bi:([PTB])\s+iskey:\s*\d+\s+type:([IPB?])", log)
        if not start or not time_base or not frames:
            raise RuntimeError(f"Cannot parse FFmpeg showinfo oracle for {name}; inspect {label}.log")
        base = Fraction(int(time_base[1]), int(time_base[2]))
        origin = Fraction(start[1])
        if [int(frame[0]) for frame in frames] != list(range(len(frames))):
            raise RuntimeError(f"Incomplete/nonsequential showinfo output for {name}")
        return {
            "streamStartSeconds": float(origin),
            "timeBase": [base.numerator, base.denominator],
            "normalizedPTS": [float(int(frame[1]) * base - origin) for frame in frames],
            "interlaceFlags": sorted({frame[2] for frame in frames}),
            "containsBFrames": any(frame[3] == "B" for frame in frames),
        }

    fixtures = []
    for name, arguments, source_count, field_order, require_b_frames in specs:
        path = output / name
        run(name + "-generate", common + arguments + [str(path)])
        source = oracle(name, deinterlace=False)
        presented = oracle(name, deinterlace=True) if field_order else source
        assert len(source["normalizedPTS"]) == source_count, (name, source)
        assert len(presented["normalizedPTS"]) == source_count * (2 if field_order else 1), name
        assert source["containsBFrames"] or not require_b_frames, name
        if field_order:
            assert source["interlaceFlags"] == ["T" if field_order == "tff" else "B"], name
            assert presented["interlaceFlags"] == ["P"], name
            assert all(abs((b - a) - 0.02) < 1e-9 for a, b in
                       zip(presented["normalizedPTS"], presented["normalizedPTS"][1:])), name
        if "nonzero" in name:
            assert source["streamStartSeconds"] >= 1.5, name
            assert abs(source["normalizedPTS"][0]) < 1e-9, name
        if "vfr" in name:
            deltas = {round(b - a, 3) for a, b in
                      zip(source["normalizedPTS"], source["normalizedPTS"][1:])}
            assert max(deltas) - min(deltas) > 0.02, (name, deltas)
        fixtures.append({
            "filename": name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "sourceFrameCount": source_count,
            "fieldOrder": field_order,
            **presented,
            "sourceContainsBFrames": source["containsBFrames"],
            "sourceNormalizedPTS": source["normalizedPTS"],
        })

    manifest = {"schemaVersion": 1, "ffmpegVersion": version, "fixtures": fixtures}
    (output / "fixture-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"output": str(output), "fixtures": len(fixtures),
                      "presentedFrames": sum(len(f["normalizedPTS"]) for f in fixtures)}))


if __name__ == "__main__":
    main()
