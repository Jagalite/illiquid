#!/usr/bin/env python3
"""Create local Matroska fixtures for auxiliary-input font-copy measurements.

The deterministic, dense font-labeled payloads exercise metadata ownership,
not font parsing or subtitle rendering. No media or fonts are downloaded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

MIB = 1024 * 1024


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(MIB):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--only-integration", action="store_true",
                        help="Generate only the small native regression fixture")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    payloads = output / "payloads"
    payloads.mkdir()
    commands: list[dict] = []

    def run(arguments: list) -> None:
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
                   *map(str, arguments)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=120)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "fixture-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")

    def payload(name: str, size: int, seed: int = 0) -> Path:
        path = payloads / name
        # Every page contains nonzero values. Distinct seeds distinguish the
        # four 16 MiB attachments without allocating a 64 MiB generator buffer.
        block = bytes((index + seed) % 256 for index in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    subtitles = payloads / "captions.srt"
    subtitles.write_text(
        "1\n00:00:00,250 --> 00:00:00,750\nFirst caption\n\n"
        "2\n00:00:01,250 --> 00:00:01,750\nSecond caption\n",
        encoding="utf-8",
    )
    chapters = payloads / "chapters.ffmetadata"
    chapters.write_text(
        ";FFMETADATA1\ntitle=Auxiliary input ownership fixture\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Closing\n",
        encoding="utf-8",
    )
    base = output / "base-av-subtitle.mkv"
    run([
        "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=4:duration=2",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=2",
        "-i", subtitles, "-f", "ffmetadata", "-i", chapters,
        "-map", "0:v:0", "-map", "1:a:0", "-map", "2:s:0",
        "-map_metadata", "3", "-map_chapters", "3", "-t", "2",
        "-c:v", "ffv1", "-level", "3", "-g", "4", "-c:a", "flac", "-c:s", "srt",
        "-threads", "1", "-metadata:s:v:0", "title=Fixture video",
        "-metadata:s:a:0", "title=Fixture audio", "-metadata:s:a:0", "language=eng",
        "-metadata:s:s:0", "title=Fixture captions", "-metadata:s:s:0", "language=eng",
        "-disposition:v:0", "default", "-disposition:a:0", "default",
        "-disposition:s:0", "default", base,
    ])

    def mux(filename: str, attachments: list[tuple[Path, str, str]]) -> Path:
        arguments: list = ["-i", base, "-map", "0", "-map_metadata", "0",
                           "-map_chapters", "0", "-c", "copy"]
        for index, (path, name, mime) in enumerate(attachments):
            arguments += ["-attach", path, f"-metadata:s:t:{index}", f"filename={name}",
                          f"-metadata:s:t:{index}", f"mimetype={mime}"]
        path = output / filename
        run([*arguments, path])
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture {filename}")
        return path

    embedded = payloads / "embedded.TTF"
    embedded.write_bytes(bytes([0x00, 0x01, 0x02, 0xFE, 0xFF]))
    glyphs = payloads / "glyphs.bin"
    glyphs.write_bytes(bytes([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]))
    report = payload("report.bin", 4096, seed=19)
    integration = mux("auxiliary-font-attachments.mkv", [
        (report, "report.bin", "application/octet-stream"),
        (embedded, "embedded.TTF", "application/x-truetype-font"),
        (glyphs, "glyphs.bin", "font/otf"),
    ])
    integration_manifest = {
        "filename": integration.name, "sha256": file_sha(integration),
        "size_bytes": integration.stat().st_size,
        "duration_seconds": 2, "seek_seconds": 1,
        "stream_kinds": ["video", "audio", "subtitle", "attachment", "attachment", "attachment"],
        "selected_video_index": 0, "selected_audio_index": 1, "selected_subtitle_index": 2,
        "accepted_attachments": [
            {"filename": "embedded.TTF", "mime_type": "application/x-truetype-font",
             "bytes": embedded.stat().st_size, "sha256": file_sha(embedded),
             "hex": embedded.read_bytes().hex()},
            {"filename": "glyphs.bin", "mime_type": "font/otf",
             "bytes": glyphs.stat().st_size, "sha256": file_sha(glyphs),
             "hex": glyphs.read_bytes().hex()},
        ],
        "accepted_payload_bytes": 11, "rejected_payload_bytes": report.stat().st_size,
    }
    (output / "integration-manifest.json").write_text(json.dumps(integration_manifest, indent=2) + "\n")

    manifest = []
    if not args.only_integration:
        small_font = payload("font-128kib.TTF", 128 * 1024)
        medium_font = payload("font-2mib.TTF", 2 * MIB, seed=1)
        large_fonts = [payload(f"font-16mib-{index}.TTF", 16 * MIB, seed=index + 2)
                       for index in range(4)]
        rejected = payload("booklet.bin", 2 * MIB, seed=23)

        def font(path: Path) -> tuple[Path, str, str]:
            return (path, path.name, "application/x-truetype-font")

        cases = [
            ("none", "No-attachment control", [], 0, 0),
            ("fonts-128kib", "128 KiB accepted font payload", [font(small_font)], 128 * 1024, 0),
            ("fonts-2mib", "2 MiB accepted font payload", [font(medium_font)], 2 * MIB, 0),
            ("fonts-16mib", "16 MiB accepted font payload; per-font production limit",
             [font(large_fonts[0])], 16 * MIB, 0),
            ("fonts-64mib", "Four 16 MiB fonts; aggregate production-limit stress case",
             [font(path) for path in large_fonts], 64 * MIB, 0),
            ("mixed", "2 MiB unsupported extra, 128 KiB extension-admitted font, 6-byte MIME-admitted font",
             [(rejected, "booklet.bin", "application/octet-stream"), font(small_font),
              (glyphs, "glyphs.bin", "font/otf")], 128 * 1024 + 6, 2 * MIB),
        ]
        for name, description, attachments, accepted_bytes, rejected_bytes in cases:
            path = mux(name + ".mkv", attachments)
            manifest.append({
                "name": name, "filename": path.name, "description": description,
                "accepted_payload_bytes": accepted_bytes, "rejected_payload_bytes": rejected_bytes,
                "accepted_attachment_count": sum(
                    item[1].lower().endswith((".ttf", ".otf", ".ttc")) or "font" in item[2].lower()
                    for item in attachments
                ),
                "sha256": file_sha(path), "size_bytes": path.stat().st_size,
            })
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"fixtures": len(manifest), "integration_fixture": integration.name,
                      "output": str(output)}, sort_keys=True))


if __name__ == "__main__":
    main()
