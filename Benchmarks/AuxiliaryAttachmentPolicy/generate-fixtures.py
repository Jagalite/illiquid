#!/usr/bin/env python3
"""Create A/V/ASS Matroska fixtures for auxiliary attachment ownership research."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

MIB = 1024 * 1024
ROOT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(MIB):
            checksum.update(chunk)
    return checksum.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory; fixtures are never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    payloads = output / "payloads"
    payloads.mkdir()
    commands: list[dict] = []

    def run(arguments: list) -> None:
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", *map(str, arguments)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=180)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "fixture-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")

    def payload(name: str, size: int, seed: int) -> Path:
        path = payloads / name
        # Distinct deterministic payloads expose missing, duplicated and swapped
        # copies. Synthetic font labels test ownership, not font validity/rendering.
        block = bytes((byte + seed) % 256 for byte in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    subtitles = payloads / "captions.ass"
    subtitles.write_text(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n"
        "WrapStyle: 0\nScaledBorderAndShadow: yes\n\n[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        "Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Noto Sans,22,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"
        "0,0,0,0,100,100,0,0,1,1,0,2,10,10,12,1\n\n[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Auxiliary font ownership fixture\n",
        encoding="utf-8",
    )
    chapters = payloads / "chapters.ffmeta"
    chapters.write_text(
        ";FFMETADATA1\ntitle=Auxiliary attachment ownership\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Fixture chapter\n",
        encoding="utf-8",
    )

    def mux(name: str, description: str, attachments: list[tuple], *, synthetic: bool) -> dict:
        filename = name + ".mkv"
        arguments = ["-f", "lavfi", "-i", "testsrc2=size=64x48:rate=12",
                     "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                     "-i", subtitles, "-f", "ffmetadata", "-i", chapters,
                     "-t", "1", "-map", "0:v", "-map", "1:a", "-map", "2:s",
                     "-map_metadata", "3", "-map_chapters", "3",
                     "-c:v", "mpeg4", "-q:v", "5", "-g", "6", "-bf", "0",
                     "-pix_fmt", "yuv420p", "-c:a", "flac", "-c:s", "ass", "-threads", "1",
                     "-metadata:s:v:0", "title=Fixture video", "-metadata:s:a:0", "title=Fixture audio",
                     "-metadata:s:a:0", "language=eng", "-metadata:s:s:0", "title=Fixture captions",
                     "-metadata:s:s:0", "language=eng", "-disposition:s:0", "default"]
        inventory = []
        accepted_bytes = rejected_bytes = 0
        for index, (path, filename_tag, mime, accepted) in enumerate(attachments):
            arguments += ["-attach", path, f"-metadata:s:t:{index}", f"filename={filename_tag}",
                          f"-metadata:s:t:{index}", f"mimetype={mime}"]
            byte_count = path.stat().st_size
            if accepted:
                accepted_bytes += byte_count
            else:
                rejected_bytes += byte_count
            inventory.append({"filename": filename_tag, "mime_type": mime,
                              "size_bytes": byte_count, "sha256": digest(path), "supported_font": accepted})
        arguments.append(output / filename)
        run(arguments)
        path = output / filename
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture {filename}")
        return {"name": name, "filename": filename, "description": description,
                "synthetic_font_payloads": synthetic,
                "accepted_payload_bytes": accepted_bytes, "rejected_payload_bytes": rejected_bytes,
                "accepted_attachment_count": sum(entry[3] for entry in attachments),
                "attachments": inventory, "sha256": digest(path), "size_bytes": path.stat().st_size,
                "media": {"video": "mpeg4", "audio": "flac", "subtitle": "ass", "duration_seconds": 1}}

    fonts = {size: payload(f"font-{size}.TTF", size, 11) for size in (128 * 1024, 2 * MIB, 16 * MIB)}
    stress_fonts = [payload(f"stress-{index}.TTF", 16 * MIB, 31 + index) for index in range(4)]
    unsupported = payload("report.bin", 2 * MIB, 71)

    def font(path: Path, name: str | None = None) -> tuple:
        return path, name or path.name, "application/x-truetype-font", True

    cases = [
        ("none", "No attachments; normal-open control", []),
        ("fonts-128kib", "128 KiB font-labeled payload", [font(fonts[128 * 1024])]),
        ("fonts-2mib", "2 MiB font-labeled payload", [font(fonts[2 * MIB])]),
        ("fonts-16mib", "16 MiB font-labeled payload; per-font bound", [font(fonts[16 * MIB])]),
        ("fonts-64mib", "Four 16 MiB font-labeled payloads; total-budget stress case",
         [font(path) for path in stress_fonts]),
        ("mixed", "2 MiB font-labeled payload and 2 MiB unsupported embedded extra",
         [font(fonts[2 * MIB]), (unsupported, "report.bin", "application/octet-stream", False)]),
    ]
    manifest = [mux(name, description, attachments, synthetic=bool(attachments))
                for name, description, attachments in cases]
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    embedded = payloads / "embedded.TTF"
    embedded.write_bytes(bytes([0, 1, 2, 254, 255]))
    glyphs = payloads / "glyphs.bin"
    glyphs.write_bytes(bytes([70, 79, 78, 84, 0, 128]))
    integration = mux("auxiliary-attachments", "Exact-byte native attachment-policy regression fixture", [
        (unsupported, "report.bin", "application/octet-stream", False),
        font(embedded), (glyphs, "glyphs.bin", "font/otf", True),
    ], synthetic=True)

    real_font = ROOT / "TestFixtures/Fonts/NotoSans-Regular.ttf"
    if not real_font.is_file():
        raise RuntimeError(f"Bundled real-font fixture is missing: {real_font}")
    real = mux("auxiliary-real-font", "Bundled Noto Sans font with ASS rendering text", [
        font(real_font),
    ], synthetic=False)
    (output / "auxiliary-fixture-manifest.json").write_text(
        json.dumps({"integration": integration, "real_font": real}, indent=2) + "\n")
    print(json.dumps({"fixtures": len(manifest), "integration_fixture": integration["filename"],
                      "real_font_fixture": real["filename"], "output": str(output)}, sort_keys=True))


if __name__ == "__main__":
    main()
