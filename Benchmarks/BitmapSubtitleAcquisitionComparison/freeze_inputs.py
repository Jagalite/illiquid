#!/usr/bin/env python3
"""Regenerate immutable study snapshots from the exact reviewed Git commits."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REVISIONS = {
    "copying": "ea2ff568237e2667f7b1aeee67b11a44ebe95b72",
    "raw_buffer": "aa71f1df6045ef35301fb0a95518b571f02f23b7",
    "data_nocopy": "6275059f54fc9ec52873fb7d223ad6f598fd0c47",
}
CORPUS_REVISION = "2441293b7d84de9b32ea807cbd3ed739bec9ce57"
CORPUS_PATH = "Benchmarks/BitmapSubtitleAcquisitionBorrow/Driver.swift"
PARSER = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
SHARED = [
    "Sources/IlliquidNativePlayback/Media/FFmpegPacket.swift",
    "Sources/IlliquidNativePlayback/Media/MediaTime.swift",
    "Sources/IlliquidNativePlayback/Media/FFmpegError.swift",
    "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift",
    "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift",
    "Sources/CFFmpeg/module.modulemap",
    "Sources/CFFmpeg/include/ffmpeg_shim.h",
]
TESTS = {
    "raw_buffer": "Tests/IlliquidNativePlaybackTests/SubtitleAcquisitionPacketBorrowTests.swift",
    "data_nocopy": "Tests/IlliquidNativePlaybackTests/BitmapSubtitleAcquisitionBorrowTests.swift",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    records, cache = {}, {}

    def source(revision, path):
        key = revision, path
        if key not in cache:
            cache[key] = subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT)
        return cache[key]

    def freeze(key, revision, path, destination, *, start=None, end=None, length=None):
        data = source(revision, path)
        if start is not None and data.count(start) != 1:
            raise ValueError(f"Start boundary is not unique: {key}")
        if end is not None and data.count(end) != 1:
            raise ValueError(f"End boundary is not unique: {key}")
        first = 0 if start is None else data.index(start)
        last = first + length if length is not None else (len(data) if end is None else data.index(end, first))
        selected = data[first:last]
        target = HERE / "frozen" / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_bytes() != selected:
            raise ValueError(f"Existing frozen bytes differ; review explicitly before replacing {target}")
        target.write_bytes(selected)
        records[key] = {
            "revision": revision, "path": path, "source_sha256": sha(data),
            "source_bytes": len(data), "snapshot": str(target.relative_to(HERE)),
            "start_byte": first, "end_byte_exclusive": last,
            "sha256": sha(selected), "bytes": len(selected),
        }

    for path in SHARED:
        reference = source(REVISIONS["copying"], path)
        for variant, revision in REVISIONS.items():
            if source(revision, path) != reference:
                raise ValueError(f"Shared production input differs in {variant}: {path}")
            freeze(f"shared/{variant}/{Path(path).name}", revision, path,
                   f"shared/{Path(path).name}")
    for variant, revision in REVISIONS.items():
        freeze(f"{variant}/classifiers", revision, PARSER,
               f"{variant}/BitmapSubtitleClassifiers.swift",
               end=b"\nstruct NativeBitmapSubtitleRegion:")
        freeze(f"{variant}/call-site", revision, DEMUXER,
               f"{variant}/call-site.swift.txt",
               start=b"                let acquisition =",
               end=b"\n                if acquisition {")
    raw_path = "Sources/IlliquidNativePlayback/Subtitles/SubtitleAcquisitionPacket.swift"
    freeze("raw_buffer/adapter", REVISIONS["raw_buffer"], raw_path,
           "raw_buffer/SubtitleAcquisitionPacket.swift")
    imports = b"import CFFmpeg\nimport Foundation\n"
    if not source(REVISIONS["data_nocopy"], DEMUXER).startswith(imports):
        raise ValueError("Unexpected no-copy demuxer imports")
    freeze("data_nocopy/imports", REVISIONS["data_nocopy"], DEMUXER,
           "data_nocopy/imports.swift.txt", length=len(imports))
    declaration = b"final class FFmpegDemuxer {\n"
    freeze("data_nocopy/type", REVISIONS["data_nocopy"], DEMUXER,
           "data_nocopy/type.swift.txt", start=declaration, length=len(declaration))
    freeze("data_nocopy/helper", REVISIONS["data_nocopy"], DEMUXER,
           "data_nocopy/helper.swift.txt", start=b"    static func isSubtitleAcquisition(",
           end=b"\n    /// AVIO retains AVERROR_EXIT")
    for variant, path in TESTS.items():
        freeze(f"{variant}/tests", REVISIONS[variant], path,
               f"{variant}/{Path(path).name}")
    original_driver = source(CORPUS_REVISION, CORPUS_PATH)
    marker = b"private let workloadNames ="
    corpus = original_driver[original_driver.index(marker):].rstrip(b"\n") + b"\n"
    current_driver = (HERE / "Driver.swift").read_bytes()
    current_corpus = current_driver[current_driver.index(marker):].rstrip(b"\n") + b"\n"
    if corpus != current_corpus:
        raise ValueError("The common corpus/timing code differs from the qualified two-arm driver")
    manifest = {
        "schema_version": 1, "variants": REVISIONS, "inputs": records,
        "shared_paths": SHARED, "test_counts": {"raw_buffer": 7, "data_nocopy": 8},
        "corpus": {"revision": CORPUS_REVISION, "path": CORPUS_PATH,
                   "source_sha256": sha(original_driver), "suffix_sha256": sha(corpus),
                   "boundary": marker.decode(), "normalization": "one terminal newline"},
    }
    (HERE / "frozen/manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    print(f"Frozen {len(records)} source records; shared bytes identical across all three revisions")


if __name__ == "__main__":
    main()

