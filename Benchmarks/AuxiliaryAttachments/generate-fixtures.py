#!/usr/bin/env python3
"""Create small Matroska media with controlled embedded-font payloads.

The large font-labeled payloads measure copying/retention only. They are not
valid fonts and must not be used as evidence about libass font rendering. The
real-font control uses the project's bundled, licensed Noto Sans font.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
MIB = 1024 * 1024
FONT_MIME = "application/x-truetype-font"
ASS = """[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans,24,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:00.20,Default,,0,0,0,,Embedded font check
"""


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(MIB):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    payloads = output / "payloads"
    payloads.mkdir()
    commands = []

    def run(arguments: list) -> str:
        command = [args.ffmpeg, *map(str, arguments)]
        started = time.monotonic()
        result = subprocess.run(command, text=True, capture_output=True, timeout=120)
        record = {"argv": command, "returncode": result.returncode,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout": result.stdout, "stderr": result.stderr}
        commands.append(record)
        with (output / "fixture-commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True, allow_nan=False) + "\n")
        write_json(output / "fixture-commands.json", commands)
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")
        return result.stdout

    version = run(["-version"])

    def payload(name: str, size: int, seed: int = 0) -> Path:
        path = payloads / name
        block = bytes((value + seed) % 256 for value in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    real_font = payloads / "NotoSans-Regular.ttf"
    shutil.copyfile(ROOT / "TestFixtures/Fonts/NotoSans-Regular.ttf", real_font)
    shutil.copyfile(ROOT / "TestFixtures/Fonts/OFL.txt", payloads / "OFL.txt")
    synthetic_fonts = [payload(f"synthetic-{index}.ttf", 8 * MIB, index)
                       for index in range(4)]
    subtitles = payloads / "embedded.ass"
    subtitles.write_text(ASS, encoding="utf-8")

    def attachment(path: Path, filename: str, mime: str, supported: bool = True) -> dict:
        return {"filename": filename, "mime_type": mime,
                "payload_path": str(path.relative_to(output)),
                "size_bytes": path.stat().st_size, "sha256": file_sha(path),
                "supported_font": supported}

    def mux(name: str, description: str, attachments: list[dict],
            *, include_subtitles: bool = True) -> dict:
        arguments = ["-hide_banner", "-nostdin", "-loglevel", "error",
                     "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        if include_subtitles:
            arguments += ["-i", subtitles]
        arguments += ["-t", "0.25", "-map", "0:a", "-c:a", "flac", "-threads", "1"]
        if include_subtitles:
            arguments += ["-map", "1:s:0", "-c:s", "ass",
                          "-metadata:s:s:0", "language=eng",
                          "-metadata:s:s:0", "title=Embedded font check"]
        for index, entry in enumerate(attachments):
            arguments += ["-attach", output / entry["payload_path"],
                          f"-metadata:s:t:{index}", f"filename={entry['filename']}",
                          f"-metadata:s:t:{index}", f"mimetype={entry['mime_type']}"]
        filename = name + ".mkv"
        path = output / filename
        run([*arguments, path])
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture {filename}")
        return {"name": name, "filename": filename, "description": description,
                "font_payload_bytes": sum(x["size_bytes"] for x in attachments if x["supported_font"]),
                "font_payload_count": sum(x["supported_font"] for x in attachments),
                "attachments": attachments, "has_embedded_ass": include_subtitles,
                "sha256": file_sha(path), "size_bytes": path.stat().st_size}

    real_attachment = attachment(real_font, real_font.name, FONT_MIME)
    synthetic_attachments = [attachment(path, path.name, FONT_MIME) for path in synthetic_fonts]
    manifest = [
        mux("none", "FLAC and ASS without attachments; normal-open control", []),
        mux("real-font", "Bundled Noto Sans font and an ASS event using that font",
            [real_attachment]),
        mux("fonts-8mib", "One 8 MiB deterministic font-labeled payload; copying/retention only",
            synthetic_attachments[:1]),
        mux("fonts-32mib", "Four 8 MiB deterministic font-labeled payloads; copying/retention only",
            synthetic_attachments),
    ]
    write_json(output / "manifest.json", manifest)

    # Preserve the existing native admission test's exact accepted byte sequence
    # and order. No ASS stream is included, so its first packet remains audio.
    report = payloads / "report.bin"
    report.write_bytes(b"unsupported embedded report\n")
    embedded = payloads / "embedded.TTF"
    embedded.write_bytes(bytes([0x00, 0x01, 0x02, 0xFE, 0xFF]))
    glyphs = payloads / "glyphs.bin"
    glyphs.write_bytes(bytes([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]))
    integration = mux("attachment-admission", "Mixed tiny payloads for native admission/ownership tests", [
        attachment(report, report.name, "application/octet-stream", False),
        attachment(embedded, embedded.name, FONT_MIME),
        attachment(glyphs, glyphs.name, "font/otf"),
    ], include_subtitles=False)
    write_json(output / "integration-manifest.json", integration)
    write_json(output / "generation.json", {
        "completed_utc": datetime.now(timezone.utc).isoformat(),
        "generator_sha256": file_sha(Path(__file__)), "ffmpeg_version": version,
        "real_font_source": "TestFixtures/Fonts/NotoSans-Regular.ttf",
        "real_font_sha256": file_sha(real_font), "license": "payloads/OFL.txt",
        "large_payloads_are_valid_fonts": False,
        "manifest_sha256": file_sha(output / "manifest.json"),
        "integration_manifest_sha256": file_sha(output / "integration-manifest.json"),
    })
    print(json.dumps({"fixtures": len(manifest), "integration_fixture": "attachment-admission.mkv",
                      "output": str(output)}, sort_keys=True))


if __name__ == "__main__":
    main()
