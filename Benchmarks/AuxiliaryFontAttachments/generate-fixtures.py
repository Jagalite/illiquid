#!/usr/bin/env python3
"""Generate bounded font-copy workloads and focused native integration fixtures.

Measured font-labeled payloads are dense deterministic arbitrary bytes: they
exercise ownership and copying, not font validity or rendering. The separate
video integration fixture uses the repository's licensed Noto Sans font.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

MIB = 1024 * 1024
ROOT = Path(__file__).resolve().parents[2]
FONT_MIME = "application/x-truetype-font"


def file_sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(MIB):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    font_path = ROOT / "TestFixtures/Fonts/NotoSans-Regular.ttf"
    font_license = ROOT / "TestFixtures/Fonts/OFL.txt"
    if not font_path.is_file() or not font_license.is_file():
        parser.error("The repository's licensed Noto Sans fixture font and OFL.txt are required")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    payloads = output / "payloads"
    payloads.mkdir()
    commands = []

    def run(arguments) -> None:
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error",
                   *map(str, arguments)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=120)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "fixture-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")

    def payload(name: str, size: int) -> Path:
        path = payloads / name
        # Distinct, reproducible non-sparse bytes avoid measuring filesystem
        # holes or identical-content deduplication between separate fonts.
        with path.open("wb") as target:
            for offset in range(0, size, MIB):
                seed = f"illiquid-auxiliary-font-fixture-v1:{name}:{offset}".encode()
                target.write(hashlib.shake_256(seed).digest(min(MIB, size - offset)))
        return path

    def add_attachments(arguments, attachments) -> None:
        for index, (path, name, mime) in enumerate(attachments):
            arguments += ["-attach", path, f"-metadata:s:t:{index}", f"filename={name}",
                          f"-metadata:s:t:{index}", f"mimetype={mime}"]

    def mux(filename: str, attachments) -> Path:
        arguments = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                     "-t", "0.25", "-map", "0:a", "-c:a", "flac", "-threads", "1"]
        add_attachments(arguments, attachments)
        path = output / filename
        run([*arguments, path])
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture {filename}")
        return path

    font_2mib = payload("font-2mib.ttf", 2 * MIB)
    fonts_16mib = [payload(f"font-16mib-{index}.ttf", 16 * MIB) for index in range(4)]
    unsupported = payload("unsupported-4mib.bin", 4 * MIB)
    cases = [
        ("none", "No attachment payloads; unchanged input control", [], [], 0),
        ("fonts-2mib", "One 2 MiB arbitrary font-labeled payload",
         [(font_2mib, "font-2mib.ttf", FONT_MIME)], [], 0),
        ("fonts-16mib", "One 16 MiB arbitrary font-labeled payload at the per-font limit",
         [(fonts_16mib[0], "font-16mib.ttf", FONT_MIME)], [], 0),
        ("fonts-64mib", "Four 16 MiB arbitrary font-labeled payloads at the aggregate limit; stress case",
         [(path, f"font-{index}.ttf", FONT_MIME) for index, path in enumerate(fonts_16mib)], [], 0),
        ("mixed-6mib", "2 MiB accepted font-labeled payload plus 4 MiB unsupported attachment",
         [(font_2mib, "font-2mib.ttf", FONT_MIME)],
         [(unsupported, "extras.bin", "application/octet-stream")], 4 * MIB),
    ]
    manifest = []
    for name, description, accepted, rejected, rejected_bytes in cases:
        filename = f"{name}.mkv"
        path = mux(filename, [*accepted, *rejected])
        accepted_attachments = [
            {"filename": attachment_name, "mime_type": mime,
             "bytes": payload_path.stat().st_size, "sha256": file_sha(payload_path),
             "supported_font": True}
            for payload_path, attachment_name, mime in accepted
        ]
        manifest.append({
            "name": name, "filename": filename, "description": description,
            "accepted_payload_bytes": sum(item["bytes"] for item in accepted_attachments),
            "rejected_payload_bytes": rejected_bytes,
            "accepted_attachments": accepted_attachments,
            "sha256": file_sha(path), "size_bytes": path.stat().st_size,
        })
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    # Preserve the original admission regression fixture's attachment order,
    # metadata, exact bytes, and 0.25-second FLAC input.
    old_rejected = payloads / "admission-report.bin"
    old_rejected.write_bytes(bytes(range(256)) * 4096)
    embedded = payloads / "embedded.TTF"
    embedded.write_bytes(bytes([0x00, 0x01, 0x02, 0xFE, 0xFF]))
    glyphs = payloads / "glyphs.bin"
    glyphs.write_bytes(bytes([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]))
    admission = mux("attachment-admission.mkv", [
        (old_rejected, "report.bin", "application/octet-stream"),
        (embedded, "embedded.TTF", FONT_MIME),
        (glyphs, "glyphs.bin", "font/otf"),
    ])

    # This fixture exercises real font registration/rendering, independent
    # subtitle and delayed-audio inputs, frame stepping, and thumbnail decode.
    # FFV1 avoids optional third-party encoder dependencies in the generator.
    ass = payloads / "auxiliary-font.ass"
    ass.write_text(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n\n"
        "[V4+ Styles]\n"
        "Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,"
        "Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,"
        "Alignment,MarginL,MarginR,MarginV,Encoding\n"
        "Style: Default,Noto Sans,24,&H00FFFFFF,&H0000FFFF,&H00101010,&H80000000,"
        "0,0,0,0,100,100,0,0,1,1,0,2,8,8,12,1\n\n"
        "[Events]\nFormat: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\n"
        "Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Embedded Noto font\n",
        encoding="utf-8",
    )
    video = output / "auxiliary-font-video.mkv"
    arguments = [
        "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-i", ass, "-t", "1.2", "-map", "0:v:0", "-map", "1:a:0", "-map", "2:s:0",
        "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv420p",
        "-c:a", "flac", "-ac", "2", "-c:s", "ass", "-threads", "1",
        "-metadata:s:s:0", "language=eng", "-disposition:s:0", "default",
    ]
    add_attachments(arguments, [(font_path, "NotoSans-Regular.ttf", FONT_MIME)])
    run([*arguments, video])
    shutil.copyfile(font_license, output / "auxiliary-font-video.OFL.txt")
    (output / "integration-fixtures.json").write_text(json.dumps({
        "attachment_admission": {"filename": admission.name, "sha256": file_sha(admission)},
        "auxiliary_video": {"filename": video.name, "sha256": file_sha(video),
                            "font_path": str(font_path.relative_to(ROOT)),
                            "font_sha256": file_sha(font_path),
                            "font_license_sha256": file_sha(font_license),
                            "subtitle_sha256": file_sha(ass)},
    }, indent=2) + "\n")
    print(json.dumps({"fixtures": len(manifest), "integration_fixture": admission.name,
                      "video_fixture": video.name, "output": str(output)}, sort_keys=True))


if __name__ == "__main__":
    main()
