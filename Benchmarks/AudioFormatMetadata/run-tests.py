#!/usr/bin/env python3
"""Run production AudioSourceFormatTests in a focused real-libavutil package."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time

spec = importlib.util.spec_from_file_location("metadata_runner", Path(__file__).with_name("run.py"))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
ROOT = shared.ROOT
TEST = "Tests/IlliquidNativePlaybackTests/AudioSourceFormatTests.swift"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--ffmpeg-prefix", type=Path, default=Path("/opt/homebrew/opt/ffmpeg"))
    parser.add_argument("--configuration", choices=["debug", "release", "both"], default="both")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError("Output directory must be new or empty")
    package = output / "package"
    module = package / "Sources/CFFmpeg"
    production = package / "Sources/IlliquidNativePlayback"
    tests = package / "Tests/IlliquidNativePlaybackTests"
    for directory in (module, production, tests):
        directory.mkdir(parents=True, exist_ok=True)
    shim = (ROOT / shared.SHIM).read_text()
    header = ("#include <libavutil/avutil.h>\n#include <libavutil/frame.h>\n"
              "#include <libavutil/channel_layout.h>\n#include <libavutil/samplefmt.h>\n"
              "#include <libavutil/mem.h>\n#include <libavutil/error.h>\n")
    header += shared.c_function(shim, "illiquid_audio_frame_channel_layout_name")
    (module / "metadata_shim.h").write_text(header)
    (module / "module.modulemap").write_text('module CFFmpeg [system] {\n  header "metadata_shim.h"\n  link "avutil"\n  export *\n}\n')
    raw_helper = (ROOT / shared.HELPER).read_text()
    (production / "AudioSourceFormat.swift").write_text(raw_helper)
    stream = (ROOT / shared.STREAM).read_text()
    string_function = shared.extract(stream, "func stringFromCStringBuffer(", "\nenum NativeStreamKind")
    (production / "CStringBuffer.swift").write_text("import Foundation\n\n" + string_function)
    raw_tests = (ROOT / TEST).read_text()
    (tests / "AudioSourceFormatTests.swift").write_text(raw_tests)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "AudioSourceFormatQualification", targets: [
    .systemLibrary(name: "CFFmpeg"),
    .target(name: "IlliquidNativePlayback", dependencies: ["CFFmpeg"]),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["CFFmpeg", "IlliquidNativePlayback"]),
])
''')
    prefix = args.ffmpeg_prefix.resolve()
    configs = ["debug", "release"] if args.configuration == "both" else [args.configuration]
    commands = []
    environment = os.environ.copy()
    environment["SWIFT_MODULECACHE_PATH"] = str(output / "module-cache")
    environment["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
    version = subprocess.run([args.swift, "--version"], check=True, capture_output=True, text=True, env=environment).stdout
    shared.write_json(output / "source-receipt.json", {
        "compiler": version, "platform": platform.platform(),
        "files": {shared.HELPER: shared.sha(raw_helper), TEST: shared.sha(raw_tests),
                  shared.SHIM: shared.sha(shim), shared.STREAM: shared.sha(stream)},
        "extracted_c_sha256": shared.sha(header), "extracted_string_function_sha256": shared.sha(string_function),
    })
    try:
        for config in configs:
            command = [args.swift, "test"]
            if platform.system() == "Linux":
                command += ["--use-integrated-swift-driver"]
            command += ["--package-path", str(package), "--scratch-path", str(output / ("build-" + config)),
                        "--cache-path", str(output / "cache"), "--config-path", str(output / "config"),
                        "--security-path", str(output / "security"), "-c", config, "--jobs", "2",
                        "-Xcc", "-I" + str(prefix / "include"),
                        "-Xlinker", "-L" + str(prefix / "lib"),
                        "-Xlinker", "-rpath", "-Xlinker", str(prefix / "lib"),
                        "--filter", "AudioSourceFormatTests"]
            started = time.monotonic()
            result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
            (output / (config + ".log")).write_text(result.stdout)
            commands.append({"argv": command, "elapsed_seconds": time.monotonic() - started,
                             "returncode": result.returncode, "log_sha256": shared.sha(result.stdout)})
            print(result.stdout, end="", flush=True)
            if result.returncode:
                raise RuntimeError(f"{config} tests failed: see {output / (config + '.log')}")
        shared.write_json(output / "completion.json", {"complete": True, "configurations": configs})
    finally:
        shared.write_json(output / "commands.json", commands)


if __name__ == "__main__":
    main()
