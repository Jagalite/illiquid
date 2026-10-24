#!/usr/bin/env python3
"""Generate bounded Matroska fixtures for auxiliary font-payload ownership.

The font-labeled attachments contain deterministic arbitrary bytes, not valid
fonts. They exercise metadata admission and copying, not subtitle rendering.
Every container copies the same short video, audio, subtitle, and chapter data.
Container identifiers can differ between runs; exact hashes are recorded.
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

    def payload(name: str, count: int, offset: int) -> Path:
        path = payloads / name
        block = bytes((value + offset) % 256 for value in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = count
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    subtitle = output / "fixture.ass"
    subtitle.write_text(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 160\nPlayResY: 90\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, "
        "Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,12,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,"
        "0,0,0,0,100,100,0,0,1,1,0,2,2,2,2,1\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:00.10,0:00:01.10,Default,,0,0,0,,First ownership cue\n"
        "Dialogue: 0,0:00:01.20,0:00:01.90,Default,,0,0,0,,Second ownership cue\n",
        encoding="utf-8",
    )
    metadata = output / "fixture.ffmetadata"
    metadata.write_text(
        ";FFMETADATA1\ntitle=Auxiliary attachment ownership fixture\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=First half\n"
        "[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Second half\n",
        encoding="utf-8",
    )
    source = output / "source.mkv"
    run([
        "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
        "-f", "ass", "-i", subtitle, "-f", "ffmetadata", "-i", metadata,
        "-t", "2", "-map", "0:v:0", "-map", "1:a:0", "-map", "2:s:0",
        "-map_metadata", "3", "-map_chapters", "3",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "24", "-g", "24",
        "-bf", "2", "-pix_fmt", "yuv420p", "-threads:v", "1",
        "-c:a", "flac", "-ac", "2", "-threads:a", "1", "-c:s", "ass",
        "-metadata:s:v:0", "title=Fixture video", "-metadata:s:v:0", "language=und",
        "-metadata:s:a:0", "title=Fixture stereo", "-metadata:s:a:0", "language=eng",
        "-metadata:s:s:0", "title=Fixture ASS", "-metadata:s:s:0", "language=eng",
        "-disposition:a:0", "default", "-disposition:s:0", "default", source,
    ])

    small = payload("font-2mib.bin", 2 * MIB, 17)
    medium = [payload(f"font-4mib-{index}.bin", 4 * MIB, 31 + index)
              for index in range(4)]
    large = [payload(f"font-16mib-{index}.bin", 16 * MIB, 47 + index)
             for index in range(4)]
    # Reuse a generated payload for rejected metadata. Total source payloads
    # are 82 MiB; the six final containers total approximately 116 MiB.
    rejected = large[0]
    accepted_names = [
        ("embedded.TTF", "application/octet-stream"),
        ("glyphs.bin", "font/otf"),
        ("collection.TtC", "application/octet-stream"),
        ("alternate.bin", "application/vnd.ms-opentype"),
    ]
    small_attachment = (small, "small.TTF", "application/x-truetype-font", True)
    rejected_attachment = (rejected, "extras.bin", "application/octet-stream", False)
    cases = [
        ("none", "No attachments; common-stream control", []),
        ("fonts-2mib", "One 2 MiB synthetic accepted font", [small_attachment]),
        ("fonts-16mib", "Four 4 MiB synthetic accepted fonts; 16 MiB total",
         [(path, name, mime, True) for path, (name, mime) in zip(medium, accepted_names)]),
        ("fonts-64mib", "Four 16 MiB synthetic accepted fonts; 64 MiB total stress case",
         [(path, name, mime, True) for path, (name, mime) in zip(large, accepted_names)]),
        ("unsupported-only", "16 MiB unsupported attachment; no copied-font control",
         [rejected_attachment]),
        ("mixed", "16 MiB unsupported attachment plus one 2 MiB accepted font",
         [rejected_attachment, small_attachment]),
    ]
    manifest = []
    for name, description, attachments in cases:
        filename = name + ".mkv"
        arguments = ["-i", source, "-map", "0", "-c", "copy",
                     "-map_metadata", "0", "-map_chapters", "0"]
        inventory = []
        for index, (path, attachment_name, mime, accepted) in enumerate(attachments):
            arguments += ["-attach", path,
                          f"-metadata:s:t:{index}", f"filename={attachment_name}",
                          f"-metadata:s:t:{index}", f"mimetype={mime}"]
            inventory.append({"filename": attachment_name, "mime_type": mime,
                              "size_bytes": path.stat().st_size,
                              "sha256": file_sha(path), "accepted": accepted})
        destination = output / filename
        run([*arguments, destination])
        if not destination.is_file() or destination.stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture: {filename}")
        fonts = [entry for entry in inventory if entry["accepted"]]
        manifest.append({
            "name": name, "filename": filename, "description": description,
            "accepted_payload_bytes": sum(entry["size_bytes"] for entry in fonts),
            "font_count": len(fonts),
            "rejected_payload_bytes": sum(entry["size_bytes"] for entry in inventory
                                          if not entry["accepted"]),
            "sha256": file_sha(destination), "size_bytes": destination.stat().st_size,
            "attachments": inventory,
        })
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"fixtures": len(manifest), "output": str(output),
                      "container_bytes": sum(case["size_bytes"] for case in manifest)}, sort_keys=True))


if __name__ == "__main__":
    main()
