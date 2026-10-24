#!/usr/bin/env python3
"""Generate real Matroska inputs with controlled supported-font attachments."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
MIB = 1024 * 1024


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty fixture directory")
    output.mkdir(parents=True, exist_ok=True)
    payloads = output / "payloads"
    payloads.mkdir()
    commands = []

    def run(arguments: list) -> None:
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
                   *map(str, arguments)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(result.stderr)

    def synthetic(name: str, size: int, seed: int) -> Path:
        path = payloads / name
        block = bytes((i + seed) % 256 for i in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    # The actual OFL font is a normal-size control. Synthetic cases deliberately
    # exercise payload ownership, not valid font parsing or rendering.
    real_font = ROOT / "TestFixtures/Fonts/NotoSans-Regular.ttf"
    small = synthetic("synthetic-one.ttf", MIB, 17)
    large = synthetic("synthetic-large.ttf", 16 * MIB, 41)
    multiple = [synthetic(f"synthetic-{i}.ttf", 8 * MIB, 60 + i) for i in range(4)]
    subtitles = output / "subtitles.ass"
    subtitles.write_text("""[Script Info]
ScriptType: v4.00+
PlayResX: 160
PlayResY: 90
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans,14,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,5,5,5,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:00.40,Default,,0,0,0,,Attached font ownership
Dialogue: 0,0:00:00.40,0:00:00.80,Default,,0,0,0,,Second subtitle packet
""")
    base = output / "base.mkv"
    run(["-f", "lavfi", "-i", "testsrc2=s=160x90:r=10",
         "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
         "-i", subtitles, "-t", "0.8", "-map", "0:v", "-map", "1:a", "-map", "2:s",
         "-c:v", "ffv1", "-level", "3", "-c:a", "flac", "-c:s", "ass", "-threads", "1",
         "-metadata:s:v:0", "title=Ownership video", "-metadata:s:a:0", "language=eng",
         "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=Embedded text", base])
    cases = [
        ("none", "No-font control", []),
        ("real-font", "Unmodified bundled OFL Noto Sans font", [real_font]),
        ("synthetic-1mib", "Synthetic font-labeled 1 MiB ownership workload", [small]),
        ("synthetic-16mib", "Synthetic font-labeled 16 MiB ownership stress case", [large]),
        ("synthetic-32mib", "Four synthetic 8 MiB fonts, 32 MiB total", multiple),
    ]
    manifest = []
    for name, description, fonts in cases:
        target = output / f"{name}.mkv"
        command = ["-i", base, "-map", "0", "-c", "copy"]
        attachments = []
        for index, font in enumerate(fonts):
            command += ["-attach", font, f"-metadata:s:t:{index}", f"filename={font.name}",
                        f"-metadata:s:t:{index}", "mimetype=application/x-truetype-font"]
            data = font.read_bytes()
            attachments.append({"filename": font.name, "mime_type": "application/x-truetype-font",
                                "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        run([*command, target])
        manifest.append({"name": name, "description": description, "filename": target.name,
                         "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                         "size_bytes": target.stat().st_size, "attachments": attachments,
                         "font_payload_bytes": sum(item["bytes"] for item in attachments)})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"fixtures": len(manifest), "output": str(output)}))


if __name__ == "__main__":
    main()
