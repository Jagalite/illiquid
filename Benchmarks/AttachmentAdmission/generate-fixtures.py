#!/usr/bin/env python3
"""Create controlled Matroska fixtures with deterministic attachment payloads."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

MIB = 1024 * 1024


def main():
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

    def run(arguments):
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", *map(str, arguments)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=120)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "fixture-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")

    def payload(name, size):
        path = payloads / name
        block = bytes(range(256)) * 4096
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    # These deterministic font-labeled bytes exercise admission/copying, not
    # font parsing or libass rendering. The native test verifies exact bytes.
    font = payload("example.TTF", 2 * MIB)
    small_font = payload("attached.TTF", 128 * 1024)
    rejected = {size: payload(f"extras-{size}.bin", size * MIB) for size in (1, 16, 64)}
    cover = payloads / "cover.png"
    run(["-f", "lavfi", "-i", "color=c=red:s=32x32", "-frames:v", "1",
         "-threads", "1", "-update", "1", cover])

    def mux(filename, attachments):
        arguments = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                     "-t", "0.25", "-map", "0:a", "-c:a", "flac", "-threads", "1"]
        for index, (path, name, mime) in enumerate(attachments):
            arguments += ["-attach", path, f"-metadata:s:t:{index}", f"filename={name}",
                          f"-metadata:s:t:{index}", f"mimetype={mime}"]
        arguments += [output / filename]
        run(arguments)
        if not (output / filename).is_file() or (output / filename).stat().st_size == 0:
            raise RuntimeError(f"Missing generated fixture {filename}")

    cases = [
        ("none", "No attachments; normal-open control", [], 0, 0),
        ("fonts-2mib", "2 MiB font-labeled payload; supported-copy control",
         [(font, "example.TTF", "application/x-truetype-font")], 0, 2 * MIB),
        ("unsupported-1mib", "1 MiB generic embedded extra",
         [(rejected[1], "extras.bin", "application/octet-stream")], MIB, 0),
        ("unsupported-16mib", "16 MiB generic embedded extra",
         [(rejected[16], "extras.bin", "application/octet-stream")], 16 * MIB, 0),
        ("unsupported-64mib", "64 MiB generic embedded extra; stress case",
         [(rejected[64], "extras.bin", "application/octet-stream")], 64 * MIB, 0),
        ("mixed-16mib", "16 MiB PDF-labeled extra plus 128 KiB font-labeled payload",
         [(rejected[16], "booklet.pdf", "application/pdf"),
          (small_font, "attached.TTF", "application/x-truetype-font")], 16 * MIB, 128 * 1024),
        ("cover-png", "Real PNG cover promoted by FFmpeg to an attached-picture stream",
         [(cover, "cover.png", "image/png")], 0, 0),
    ]
    manifest = []
    for name, description, attachments, rejected_bytes, accepted_bytes in cases:
        filename = name + ".mkv"
        mux(filename, attachments)
        path = output / filename
        manifest.append({"name": name, "filename": filename, "description": description,
                         "rejected_payload_bytes": rejected_bytes,
                         "accepted_payload_bytes": accepted_bytes,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                         "size_bytes": path.stat().st_size})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    embedded = payloads / "embedded.TTF"
    embedded.write_bytes(bytes([0x00, 0x01, 0x02, 0xFE, 0xFF]))
    glyphs = payloads / "glyphs.bin"
    glyphs.write_bytes(bytes([0x46, 0x4F, 0x4E, 0x54, 0x00, 0x80]))
    mux("attachment-admission.mkv", [
        (rejected[1], "report.bin", "application/octet-stream"),
        (embedded, "embedded.TTF", "application/x-truetype-font"),
        (glyphs, "glyphs.bin", "font/otf"),
    ])
    print(json.dumps({"fixtures": len(manifest), "integration_fixture": "attachment-admission.mkv",
                      "output": str(output)}, sort_keys=True))


if __name__ == "__main__":
    main()
