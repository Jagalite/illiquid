#!/usr/bin/env python3
"""Generate short A/V/subtitle files with bounded synthetic font attachments."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

MIB = 1024 * 1024


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(MIB):
            result.update(block)
    return result.hexdigest()


def main():
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

    def run(arguments):
        command = [args.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", *map(str, arguments)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=180)
        commands.append({"argv": command, "returncode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        (output / "fixture-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"Fixture generation failed: {result.stderr}")

    def payload(name, byte_count, seed):
        path = payloads / name
        block = bytes((value + seed) % 256 for value in range(256)) * 4096
        with path.open("wb") as stream:
            remaining = byte_count
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        return path

    # These deterministic bytes test supported-font admission and ownership.
    # They are deliberately not renderable fonts and do not qualify libass.
    small = payload("font-small.TTF", 2 * MIB, 0)
    large = [payload(f"font-{index}.TTF", 16 * MIB, index + 1) for index in range(4)]
    subtitles = payloads / "captions.ass"
    subtitles.write_text("""[Script Info]
ScriptType: v4.00+
PlayResX: 64
PlayResY: 36
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,10,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,1,1,1,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.10,0:00:00.90,Default,,0,0,0,,First cue
Dialogue: 0,0:00:01.00,0:00:01.80,Default,,0,0,0,,Second cue
""")
    metadata = payloads / "chapters.ffmeta"
    metadata.write_text(""";FFMETADATA1
title=Auxiliary font attachment study
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=First chapter
[CHAPTER]
TIMEBASE=1/1000
START=1000
END=2000
title=Second chapter
""")

    def mux(path, files, subtitle_file=subtitles):
        arguments = ["-f", "lavfi", "-i", "testsrc2=s=64x36:r=12:d=2",
                     "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                     "-i", subtitle_file, "-f", "ffmetadata", "-i", metadata,
                     "-t", "2", "-map", "0:v", "-map", "1:a", "-map", "2:s",
                     "-map_metadata", "3", "-map_chapters", "3", "-c:v", "mpeg4",
                     "-q:v", "7", "-c:a", "flac", "-c:s", "copy", "-threads", "1",
                     "-metadata:s:v:0", "title=Small test video",
                     "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Silent audio",
                     "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=Test captions"]
        attachments = []
        for index, (font, filename, mime) in enumerate(files):
            arguments += ["-attach", font, f"-metadata:s:t:{index}", f"filename={filename}",
                          f"-metadata:s:t:{index}", f"mimetype={mime}"]
            attachments.append({"filename": filename, "mime_type": mime,
                                "bytes": font.stat().st_size, "sha256": digest(font),
                                "supported_font": True})
        run([*arguments, path])
        return attachments

    manifest = []
    for name, files in [("none", []), ("fonts-2mib", [small]),
                        ("fonts-16mib", large[:1]), ("fonts-64mib", large)]:
        path = output / (name + ".mkv")
        attachments = mux(path, [(font, font.name, "application/x-truetype-font") for font in files])
        manifest.append({"name": name, "filename": path.name,
                         "description": "Two-second video/audio/ASS/chapters with synthetic font-labeled payloads",
                         "accepted_payload_bytes": sum(item["bytes"] for item in attachments),
                         "attachments": attachments,
                         "sha256": digest(path), "size_bytes": path.stat().st_size})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    # Additional native-regression fixtures are deliberately excluded from the
    # measured matrix. The mixed case retains the earlier test's exact bytes.
    rejected = payload("report.bin", MIB, 0)
    embedded = payloads / "embedded.TTF"
    embedded.write_bytes(bytes([0, 1, 2, 254, 255]))
    glyphs = payloads / "glyphs.bin"
    glyphs.write_bytes(bytes([70, 79, 78, 84, 0, 128]))
    # Preserve the earlier admission test's audio-only packet ordering.
    mixed = output / "attachment-admission.mkv"
    arguments = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                 "-t", "0.25", "-map", "0:a", "-c:a", "flac", "-threads", "1"]
    for index, (payload_file, filename, mime) in enumerate([
        (rejected, "report.bin", "application/octet-stream"),
        (embedded, "embedded.TTF", "application/x-truetype-font"),
        (glyphs, "glyphs.bin", "font/otf"),
    ]):
        arguments += ["-attach", payload_file, f"-metadata:s:t:{index}", f"filename={filename}",
                      f"-metadata:s:t:{index}", f"mimetype={mime}"]
    run([*arguments, mixed])
    real_subtitles = payloads / "embedded-font.ass"
    real_subtitles.write_text(subtitles.read_text().replace("Style: Default,Arial,", "Style: Default,Noto Sans,"))
    font = Path(__file__).resolve().parents[2] / "TestFixtures/Fonts/NotoSans-Regular.ttf"
    if not font.is_file():
        raise FileNotFoundError(f"Missing bundled integration font: {font}")
    rendered = output / "embedded-ass-font.mkv"
    mux(rendered, [(font, font.name, "application/x-truetype-font")], real_subtitles)
    (output / "integration-manifest.json").write_text(json.dumps([
        {"filename": path.name, "sha256": digest(path), "size_bytes": path.stat().st_size}
        for path in (mixed, rendered)
    ], indent=2) + "\n")
    (output / "generator-receipt.json").write_text(json.dumps({
        "generator_sha256": digest(Path(__file__).resolve()),
        "bundled_font_sha256": digest(font),
        "font_source": "TestFixtures/Fonts/NotoSans-Regular.ttf",
    }, indent=2) + "\n")
    print(json.dumps({"fixtures": len(manifest), "integration_fixtures": [
        "attachment-admission.mkv", "embedded-ass-font.mkv"], "output": str(output)}))


if __name__ == "__main__":
    main()
