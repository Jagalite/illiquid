#!/usr/bin/env python3
"""Run actual subtitle-pool ownership tests without Metal.

Only the two production declarations are extracted, without body rewrites.
Minimal MTLTexture/MTLBuffer protocols typecheck unused optional fields; this
check does not allocate, emulate, or qualify any GPU resource or rendering.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = "Sources/IlliquidNativePlayback/Subtitles/MetalASSSubtitleCompositor.swift"
TEST = "Tests/IlliquidNativePlaybackTests/SubtitleGPUResourcePoolTests.swift"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def extract(source, name):
    anchor = f"    final class {name}: @unchecked Sendable {{\n"
    if source.count(anchor) != 1:
        raise RuntimeError(f"Expected one exact declaration anchor for {name}")
    start = source.index(anchor)
    # Both declarations are nested one level in the renderer. Require their
    # exact closing indentation and balanced braces; never silently rewrite.
    closing = "\n    }\n"
    end = source.index(closing, start) + len(closing)
    block = source[start:end]
    if block.count("{") != block.count("}"):
        raise RuntimeError(f"Unbalanced extracted declaration: {name}")
    return block


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    package = out / "package"
    source_bytes = (ROOT / SOURCE).read_bytes()
    test_bytes = (ROOT / TEST).read_bytes()
    source = source_bytes.decode("utf-8")
    frame = extract(source, "FrameResources")
    pool = extract(source, "ResourcePool")
    wrapper = """import Foundation

// Portable type declarations only. Tests leave both optional fields nil.
protocol MTLTexture: AnyObject { var allocatedSize: Int { get } }
protocol MTLBuffer: AnyObject { var allocatedSize: Int { get } }

@MainActor
final class MetalASSSubtitleRenderer {
""" + frame + "\n" + pool + "}\n"
    manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SubtitleGPUResourcePoolPortableCheck",
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidNativePlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
"""
    files = {
        "inputs/FrameResources.swift": frame.encode("utf-8"),
        "inputs/ResourcePool.swift": pool.encode("utf-8"),
        "package/Sources/IlliquidNativePlayback/Pool.swift": wrapper.encode("utf-8"),
        "package/Tests/IlliquidNativePlaybackTests/SubtitleGPUResourcePoolTests.swift": test_bytes,
        "package/Package.swift": manifest.encode("utf-8"),
    }
    for relative, data in files.items():
        destination = out / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    compiler = subprocess.check_output(["swift", "--version"], text=True).strip()
    (out / "head.txt").write_text(head + "\n")
    (out / "swift-version.txt").write_text(compiler + "\n")
    receipt = {
        "scope": "Portable production pool ownership only; no Metal or rendering qualification",
        "head": head,
        "swift_version": compiler,
        "original_source_sha256": {SOURCE: sha256(source_bytes), TEST: sha256(test_bytes)},
        "staged_source_sha256": {name: sha256(data) for name, data in files.items()},
        "commands": [],
        "passed": False,
    }
    try:
        for configuration in ("debug", "release"):
            command = [
                "swift", "test", "--package-path", str(package),
                "--configuration", configuration, "--jobs", "2", "--no-parallel",
                "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-strict-concurrency=complete",
            ]
            log = out / f"{configuration}-tests.log"
            print(f"Running {configuration} pool ownership tests", flush=True)
            with log.open("w") as output:
                result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
            receipt["commands"].append({
                "configuration": configuration, "argv": command,
                "exit_code": result.returncode, "log_sha256": sha256(log.read_bytes()),
            })
            print(log.read_text(), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
        receipt["passed"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
