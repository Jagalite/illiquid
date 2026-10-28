#!/usr/bin/env python3
"""Supplementary Linux validation of pinned Swift/FFmpeg acquisition code.

Uses real Foundation and FFmpeg; omits unused Apple-only declarations rather
than replacing their APIs. This does not qualify macOS playback or performance.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import platform
from pathlib import Path
import re
import shlex
import shutil
import subprocess

CANDIDATE = "2441293b7d84de9b32ea807cbd3ed739bec9ce57"
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BENCHMARK = "Benchmarks/BitmapSubtitleAcquisitionBorrow"
TEST = "Tests/IlliquidNativePlaybackTests/BitmapSubtitleAcquisitionBorrowTests.swift"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def between(data, start, end):
    if data.count(start) != 1 or data.count(end) != 1:
        raise ValueError(f"Production extraction boundaries changed: {start!r}, {end!r}")
    return data[data.index(start):data.index(end, data.index(start))]


def portable_runner(reference, repository, runner_source):
    save = reference["write_json"]

    class Runner(reference["Runner"]):
        def __init__(self, args):
            if platform.system() != "Linux":
                raise ValueError("This supplemental probe is Linux-only")
            self.args, self.commands = args, []
            self.output = args.output.resolve()
            if self.output.exists() and any(self.output.iterdir()):
                raise ValueError("Output directory must be new or empty")
            self.output.mkdir(parents=True, exist_ok=True)
            self.swiftc = shutil.which(args.swiftc) or args.swiftc
            self.receipt = {
                "started_utc": datetime.now(timezone.utc).isoformat(),
                "baseline_revision": BASELINE, "candidate_revision": CANDIDATE,
                "platform": platform.platform(), "machine": platform.machine(),
                "mode": "linux-real-ffmpeg-exact-selected-production-declarations",
                "qualification": "Supplement only; no macOS build, Apple Foundation, seek latency, or RSS qualification",
                "omissions": [
                    "Unused CoreGraphics import in classifier prefix",
                    "CoreMedia import and MediaTime.cmTime/timestamp methods; actual FFmpegRational and seconds method retained",
                    "Unrelated C shim declarations, including VideoToolbox/CoreVideo; exact error, packet-flag, and no-timestamp helpers retained",
                    "C module links only actual avcodec/avutil needed by complete FFmpegPacket; no native-platform API stubs",
                    "Driver imports real Glibc instead of Darwin; input, parser, checksum, and timing statements unchanged",
                ],
                "sources": {}, "extractions": {}, "binaries": {},
                "native_runner_sha256": digest(runner_source),
                "portable_runner_sha256": digest(Path(__file__).read_bytes()),
            }
            (self.output / "native-runner.snapshot.py").write_bytes(runner_source)
            shutil.copyfile(__file__, self.output / "portable-runner.snapshot.py")
            self.command(["git", "merge-base", "--is-ancestor", BASELINE, CANDIDATE])

        def source(self, path, variant):
            revision = BASELINE if variant == "baseline" else CANDIDATE
            data = self.command(["git", "show", f"{revision}:{path}"]).encode()
            self.receipt["sources"][f"{variant}:{path}"] = digest(data)
            return data

        def selected(self, name, original, result):
            self.receipt["extractions"][name] = {
                "original_sha256": digest(original), "compiled_sha256": digest(result),
                "compiled_bytes": len(result),
            }
            return result

        def prepare(self):
            manifest = json.loads(self.source(f"{BENCHMARK}/baseline/manifest.json", "candidate"))
            assert manifest["revision"] == BASELINE
            paths = [reference["PARSER"], reference["DEMUXER"], *reference["SHARED"]]
            sources = {v: {p: self.source(p, v) for p in paths} for v in reference["VARIANTS"]}
            for path in paths:
                assert digest(sources["baseline"][path]) == manifest["sha256"][path], path
                if path in reference["SHARED"]:
                    assert sources["baseline"][path] == sources["candidate"][path], path
            old_call = b"let acquisition = needsAcquisition && packet.data.map"
            assert old_call in sources["baseline"][reference["DEMUXER"]]
            assert old_call not in sources["candidate"][reference["DEMUXER"]]
            for call in [b"PGSSubtitlePacket.isAcquisition(packet)",
                         b"DVBSubtitlePacket.isAcquisition(packet, compositionPageID:"]:
                assert call in sources["candidate"][reference["DEMUXER"]]

            root = self.output / "sources"
            module = root / "CFFmpeg"
            module.mkdir(parents=True)
            shim = sources["candidate"]["Sources/CFFmpeg/include/ffmpeg_shim.h"]
            helpers = between(shim, b"static inline int illiquid_averror_eagain(",
                              b"// A container keyframe flag alone")
            self.selected("CFFmpeg/production-helpers", shim, helpers)
            nopts = between(shim, b"static inline int64_t illiquid_nopts_value(",
                            b"static inline unsigned int illiquid_chapter_count(")
            self.selected("CFFmpeg/no-timestamp-helper", shim, nopts)
            (module / "helpers.h").write_bytes(
                b"#pragma once\n#include <errno.h>\n#include <libavcodec/packet.h>\n"
                b"#include <libavutil/avutil.h>\n#include <libavutil/error.h>\n\n" + helpers + nopts)
            (module / "module.modulemap").write_text(
                'module CFFmpeg [system] {\n header "helpers.h"\n link "avcodec"\n link "avutil"\n export *\n}\n')
            self.receipt["bridge_sha256"] = {p.name: digest(p.read_bytes()) for p in module.iterdir()}

            shared_paths = []
            shared = root / "shared"
            shared.mkdir()
            for path in reference["SHARED"]:
                if not path.endswith(".swift"):
                    continue
                data = sources["candidate"][path]
                if path.endswith("/MediaTime.swift"):
                    rational = between(data, b"struct FFmpegRational:", b"\nenum MediaTime {")
                    start = data.index(b"    static func seconds(")
                    end = data.index(b"\n    }\n", start) + len(b"\n    }\n")
                    seconds = data[start:end]
                    self.selected("FFmpegRational", data, rational)
                    self.selected("MediaTime.seconds", data, seconds)
                    data = b"import CFFmpeg\nimport Foundation\n\n" + rational + b"\nenum MediaTime {\n" + seconds + b"}\n"
                destination = shared / Path(path).name
                destination.write_bytes(data)
                shared_paths.append(destination)

            driver = self.source(f"{BENCHMARK}/Driver.swift", "candidate")
            assert driver.count(b"import Darwin\n") == 1
            driver_path = root / "Driver.swift"
            driver_path.write_bytes(self.selected("Driver.swift", driver,
                driver.replace(b"import Darwin\n", b"import Glibc\n")))
            self.source_paths = {}
            for variant in reference["VARIANTS"]:
                directory = self.output / variant
                directory.mkdir()
                extracted = []
                for path, (_, name) in reference["BOUNDARIES"].items():
                    original = reference["prefix"](sources[variant][path], path)
                    if variant == "baseline":
                        assert original == self.source(f"{BENCHMARK}/baseline/{name}", "candidate")
                        assert digest(original) == manifest["prefix_sha256"][path]
                    elif path == reference["DEMUXER"]:
                        for marker in [b"extension PGSSubtitlePacket {", b"extension DVBSubtitlePacket {"]:
                            assert original.count(marker) == 1
                    data = original
                    if path == reference["PARSER"]:
                        assert data.count(b"import CoreGraphics\n") == 1
                        data = data.replace(b"import CoreGraphics\n", b"")
                    destination = directory / name
                    destination.write_bytes(self.selected(f"{variant}:{name}", original, data))
                    extracted.append(destination)
                self.source_paths[variant] = [*shared_paths, *extracted]
            self.test_source = self.source(TEST, "candidate")
            (root / Path(TEST).name).write_bytes(self.test_source)
            if self.args.prepare_only:
                return
            self.receipt["compiler"] = self.command([self.swiftc, "--version"]).strip()
            self.receipt["ffmpeg_packages"] = self.command([
                "dpkg-query", "-W", "libavcodec-dev", "libavutil-dev"])
            self.receipt["ffmpeg_versions"] = self.command(["pkg-config", "--modversion", "libavcodec", "libavutil"])
            cflags = shlex.split(self.command(["pkg-config", "--cflags", "libavcodec", "libavutil"]))
            flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
                     "-I", str(module), "-module-cache-path", str(self.output / "module-cache")]
            for flag in cflags:
                flags.extend(["-Xcc", flag])
            self.receipt["flags"] = flags
            for variant in reference["VARIANTS"]:
                binary = self.output / variant / "benchmark"
                define = ["-D", "BASELINE"] if variant == "baseline" else []
                self.command([self.swiftc, *flags, *define, *self.source_paths[variant],
                              driver_path, "-o", binary], log=binary.parent / "compile.log")
                self.receipt["binaries"][variant] = digest(binary.read_bytes())
            self.receipt["linked_dependencies"] = self.command(["ldd", self.output / "candidate/benchmark"])

        def test(self):
            package = self.output / "tests"
            destination = package / "Sources/IlliquidNativePlayback"
            destination.mkdir(parents=True)
            shutil.copytree(self.output / "sources/CFFmpeg", package / "Sources/CFFmpeg")
            for source in self.source_paths["candidate"]:
                shutil.copyfile(source, destination / source.name)
            tests = package / "Tests/IlliquidNativePlaybackTests"
            tests.mkdir(parents=True)
            (tests / Path(TEST).name).write_bytes(self.test_source)
            (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "AcquisitionPacketProbe", targets: [
    .systemLibrary(name: "CFFmpeg", pkgConfig: "libavcodec"),
    .target(name: "IlliquidNativePlayback", dependencies: ["CFFmpeg"]),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback", "CFFmpeg"]),
])
''')
            log = self.output / "packet-tests.log"
            self.command([str(Path(self.swiftc).with_name("swift")), "test", "--package-path", package,
                          "-c", "release", "--jobs", "2", "--no-parallel", "--filter",
                          "BitmapSubtitleAcquisitionBorrowTests"], log=log)
            if not re.search(r"Test run with 8 tests.*passed", log.read_text()):
                raise ValueError("Swift Testing did not report all eight production packet tests passing")
            save(self.output / "packet-tests.json", {"passed": True, "tests": 8, "source_sha256": digest(self.test_source)})

    return Runner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=240)
    parser.add_argument("--minimum-ms", type=float, default=60)
    parser.add_argument("--prepare-only", action="store_true", help="Audit sources without compiling or claiming execution")
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2 or args.minimum_ms < 60 or args.target_ms < args.minimum_ms:
        parser.error("Use at least six even process pairs, minimum >=60 ms, target >=minimum")
    repository = args.repository.resolve()
    source = subprocess.check_output(["git", "show", f"{CANDIDATE}:{BENCHMARK}/run.py"], cwd=repository)
    reference = {"__name__": "pinned_native_reference", "__file__": str(repository / BENCHMARK / "run.py")}
    exec(compile(source, reference["__file__"], "exec"), reference)
    assert reference["BASELINE"] == BASELINE
    args.cases = reference["CASES"]
    runner = portable_runner(reference, repository, source)(args)
    try:
        runner.prepare()
        if not args.prepare_only:
            runner.verify()
            runner.test()
            runner.measure()
        reference["write_json"](runner.output / "completion.json", {
            "complete": not args.prepare_only, "source_preparation_only": args.prepare_only,
            "native_macos_qualified": False, "supplementary_linux_only": True,
        })
    finally:
        reference["write_json"](runner.output / "commands.json", runner.commands)
        reference["write_json"](runner.output / "build-receipt.json", runner.receipt)


if __name__ == "__main__":
    main()
