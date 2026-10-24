#!/usr/bin/env python3
"""Generate native Matroska inputs with controlled, synthetic font payloads.

The font-labeled bytes are deliberately not valid fonts: this benchmark tests
demuxer ownership, not font parsing or subtitle appearance. No downloads occur.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

MIB = 1024 * 1024


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    payloads = output / "payloads"
    payloads.mkdir()
    commands = []

    def write_json(name, value):
        (output / name).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")

    def run(arguments):
        argv = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", *map(str, arguments)]
        result = subprocess.run(argv, text=True, capture_output=True, timeout=120)
        commands.append({"argv": argv, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        write_json("fixture-commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")

    def payload(name: str, size: int, seed: int):
        path = payloads / name
        block = bytes((index + seed) % 256 for index in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                count = min(remaining, len(block))
                stream.write(block[:count])
                remaining -= count
        return path

    subtitles = payloads / "sample.ass"
    subtitles.write_text("""[Script Info]
ScriptType: v4.00+
PlayResX: 32
PlayResY: 24
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,10,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,1,1,1,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:00.50,Default,,0,0,0,,Memory fixture Ω
""", encoding="utf-8")
    metadata = payloads / "chapters.txt"
    metadata.write_text(";FFMETADATA1\ntitle=Auxiliary input fixture\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=250\ntitle=Opening Ω\n"
                        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=250\nEND=500\ntitle=Ending\n",
                        encoding="utf-8")

    def mux(name, attachments):
        argv = ["-f", "lavfi", "-i", "testsrc2=size=32x24:rate=4:duration=0.5",
                "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                "-i", subtitles, "-f", "ffmetadata", "-i", metadata,
                "-t", "0.5", "-map", "0:v", "-map", "1:a", "-map", "2:s",
                "-map_metadata", "3", "-map_chapters", "3",
                "-c:v", "ffv1", "-level:v", "3", "-c:a", "flac", "-c:s", "ass",
                "-threads", "1", "-metadata:s:v:0", "title=Video control",
                "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Audio control",
                "-metadata:s:s:0", "language=jpn", "-metadata:s:s:0", "title=Subtitle Ω"]
        for index, (path, filename, mime, _) in enumerate(attachments):
            argv += ["-attach", path, f"-metadata:s:t:{index}", f"filename={filename}",
                     f"-metadata:s:t:{index}", f"mimetype={mime}"]
        path = output / f"{name}.mkv"
        run([*argv, path])
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture: {path}")
        entries = [{"filename": filename, "mime_type": mime, "bytes": source.stat().st_size,
                    "sha256": digest(source), "supported_font": supported}
                   for source, filename, mime, supported in attachments]
        return {"name": name, "filename": path.name, "sha256": digest(path),
                "size_bytes": path.stat().st_size, "attachments": entries,
                "font_payload_bytes": sum(item["bytes"] for item in entries if item["supported_font"]),
                "unsupported_payload_bytes": sum(item["bytes"] for item in entries if not item["supported_font"])}

    small = payload("small.TTF", 128 * 1024, 7)
    medium = payload("medium.otf", 2 * MIB, 19)
    large = [payload(f"large-{i}.ttf", 4 * MIB, 31 + i) for i in range(4)]
    unsupported = payload("report.bin", 8 * MIB, 0)
    small_entry = (small, "small.TTF", "application/x-truetype-font", True)
    cases = [
        ("none", "No attachments; unchanged control", []),
        ("font-128kib", "One synthetic 128 KiB font", [small_entry]),
        ("font-2mib", "One synthetic 2 MiB font", [(medium, "medium.otf", "font/otf", True)]),
        ("fonts-16mib", "Four synthetic 4 MiB fonts; 16 MiB aggregate stress case",
         [(path, path.name, "application/x-truetype-font", True) for path in large]),
        ("unsupported-8mib", "8 MiB unsupported attachment; unchanged control",
         [(unsupported, "report.bin", "application/octet-stream", False)]),
        ("mixed", "128 KiB font plus 8 MiB unsupported attachment",
         [(unsupported, "report.bin", "application/octet-stream", False), small_entry]),
    ]
    manifest = []
    for name, description, attachments in cases:
        case = mux(name, attachments)
        case["description"] = description
        manifest.append(case)
    write_json("manifest.json", manifest)

    # Stable, small font payloads for the production integration tests. Keep
    # names/bytes in sync with AuxiliaryFontAttachmentTests.swift.
    first = payloads / "embedded.TTF"
    first.write_bytes(bytes([0x00, 0x01, 0x02, 0xFE, 0xFF]))
    second = payloads / "glyphs.bin"
    second.write_bytes(bytes([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]))
    rejected = payload("integration-report.bin", MIB, 0)
    integration = mux("auxiliary-font-integration", [
        (rejected, "report.bin", "application/octet-stream", False),
        (first, "embedded.TTF", "application/x-truetype-font", True),
        (second, "glyphs.bin", "font/otf", True),
    ])
    write_json("integration-manifest.json", integration)
    print(json.dumps({"fixtures": len(manifest), "output": str(output),
                      "integration_fixture": integration["filename"]}, sort_keys=True))


if __name__ == "__main__":
    main()
