#!/usr/bin/env python3
"""Generate bounded font fixtures; synthetic payloads test ownership, not font validity."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MIB = 1024 * 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    commands = []

    def run(arguments):
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", *map(str, arguments)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(result.stderr)

    captions = output / "captions.ass"
    captions.write_text("""[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans,30,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.20,0:00:01.80,Default,,0,0,0,,Auxiliary input font ownership
""")
    base = output / "base.mkv"
    run(["-f", "lavfi", "-i", "color=c=navy:s=640x360:r=10",
         "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo", "-i", captions,
         "-t", "2", "-map", "0:v", "-map", "1:a", "-map", "2:s",
         "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
         "-c:a", "flac", "-c:s", "ass", "-threads", "1", base])
    real = ROOT / "TestFixtures/Fonts/NotoSans-Regular.ttf"
    if not real.is_file():
        raise RuntimeError("Missing licensed Noto Sans fixture font")
    payloads = {}
    for size in [2, 16]:
        path = output / f"synthetic-{size}.ttf"
        with path.open("wb") as stream:
            for _ in range(size):
                stream.write(bytes(range(256)) * 4096)
        payloads[size] = path
    cases = [("none", []), ("real-font", [(real, "NotoSans-Regular.ttf")]),
             ("font-2mib", [(payloads[2], "synthetic.ttf")]),
             ("font-16mib", [(payloads[16], "synthetic.ttf")]),
             ("fonts-64mib", [(payloads[16], f"synthetic-{i}.ttf") for i in range(4)])]
    manifest = []
    for name, attachments in cases:
        filename = name + ".mkv"
        command = ["-i", base, "-map", "0", "-c", "copy"]
        for index, (path, label) in enumerate(attachments):
            command += ["-attach", path, f"-metadata:s:t:{index}", f"filename={label}",
                        f"-metadata:s:t:{index}", "mimetype=application/x-truetype-font"]
        command.append(output / filename)
        run(command)
        manifest.append({"name": name, "filename": filename,
                         "font_bytes": sum(path.stat().st_size for path, _ in attachments),
                         "font_count": len(attachments),
                         "sha256": hashlib.sha256((output / filename).read_bytes()).hexdigest()})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"output": str(output), "fixtures": len(manifest)}))


if __name__ == "__main__":
    main()
