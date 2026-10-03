#!/usr/bin/env python3
"""Generate original, tiny PGS/DVD/DVB test compositions; no downloaded media."""
import argparse
import json
from pathlib import Path
import struct
import subprocess


def segment(kind, data):
    return bytes([kind]) + struct.pack(">H", len(data)) + bytes(data)


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    result = bytearray()
    # A 2x2 white/half-transparent-grey checker at (10,20), then a clear.
    # The first cue lasts 14 seconds, deliberately exceeding a 5-second guess.
    palette = [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255, 2, 100, 128, 128, 128]
    image = [0, 1, 0, 192, 0, 0, 12, 0, 2, 0, 2, 1, 2, 0, 0, 2, 1, 0, 0]
    for index, (seconds, shown) in enumerate([(1, True), (15, False), (20, True), (25, False)]):
        pcs = [5, 0, 2, 208, 16, 0, index, 128 if shown else 0, 0, 0, int(shown)]
        if shown:
            pcs += [0, 1, 0, 64, 0, 10, 0, 20]
        segments = [segment(0x16, pcs)]
        if shown:
            segments += [segment(0x14, palette), segment(0x15, image)]
        segments += [segment(0x80, [])]
        for data in segments:
            result += b"PG" + struct.pack(">II", seconds * 90_000, seconds * 90_000) + data
    source = output / "generated.sup"
    source.write_bytes(result)
    for codec, name in [("copy", "generated-pgs.mkv"), ("dvdsub", "generated-dvd.mkv"),
                        ("dvbsub", "generated-dvb.mkv")]:
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "color=size=1280x720:rate=24:duration=30", "-fix_sub_duration",
            "-i", str(source), "-map", "0:v", "-map", "1:s", "-c:v", "mpeg4",
            "-q:v", "10", "-c:s", codec, "-y", str(output / name),
        ], check=True, timeout=60)

    # Two language tracks in an original VobSub pair. IDX owns cue timestamps;
    # the MPEG private-stream payload is produced from our authored DVD packets.
    binary = output / "generated-vobsub.sub"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", str(output / "generated-dvd.mkv"), "-map", "0:s", "-map", "0:s",
                    "-c", "copy", "-f", "vob", str(binary)], check=True, timeout=60)
    packets = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_entries", "packet=stream_index,pts_time,pos",
        "-of", "json", str(binary)]))["packets"]
    lines = ["# VobSub index file, v7 (do not modify this line!)", "size: 1280x720",
             "palette: 000000, 0000ff, 00ff00, ff0000, ffff00, ff00ff, 00ffff, ffffff, 808000, 8080ff, 800080, 80ff80, 008080, ff8080, 555555, aaaaaa"]
    for stream, language in enumerate(["en", "fr"]):
        lines.append(f"id: {language}, index: {stream}")
        for packet in packets:
            if packet["stream_index"] == stream:
                milliseconds = round((float(packet["pts_time"]) + 0.5) * 1000)
                hours, remainder = divmod(milliseconds, 3_600_000)
                minutes, remainder = divmod(remainder, 60_000)
                seconds, millis = divmod(remainder, 1000)
                position = int(packet["pos"]) // 2048 * 2048
                lines.append(f"timestamp: {hours:02}:{minutes:02}:{seconds:02}:{millis:03}, filepos: {position:09x}")
    (output / "generated-vobsub.idx").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
