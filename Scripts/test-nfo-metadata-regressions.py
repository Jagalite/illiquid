#!/usr/bin/env python3
"""Run real NFO/sidecar sources without the macOS playback dependency graph.

macOS uses byte-for-byte source and test copies. Linux changes the FoundationXML
and POSIX imports and adds explicit directory hints to legacy test fixture URLs
in disposable copies; all adaptations are recorded. This is a component test,
not an app build or native playback qualification. Swift 6.1+ is required.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "MediaNameRecognition.swift",
    "MediaMetadataHints.swift",
    "NFOMetadataHints.swift",
    "PlexMatchHints.swift",
    "MediaSidecarReader.swift",
]
TESTS = ["MediaSidecarTests.swift", "NFOMetadataFieldSelectionTests.swift"]
MANIFEST = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "IlliquidNFOMetadataRegression",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--output", type=Path, help="Directory for test.log and receipt.json")
    parser.add_argument("--nfo-source", type=Path, help="Override only the NFO source for a baseline comparison")
    parser.add_argument("--filter", help="Optional Swift test filter")
    args = parser.parse_args()
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift 6.1 or newer must be installed")
    if platform.system() not in {"Darwin", "Linux"}:
        parser.error("This component harness supports macOS and Linux")
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)

    version = subprocess.check_output([swift, "--version"], text=True).strip()
    receipt: dict = {"toolchain": version, "platform": platform.platform(),
                     "configuration": args.configuration,
                     "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                     "manifest_sha256": hashlib.sha256(MANIFEST.encode()).hexdigest(), "inputs": []}
    with tempfile.TemporaryDirectory(prefix="illiquid-nfo-tests-") as temporary:
        package = Path(temporary)
        (package / "Package.swift").write_text(MANIFEST, encoding="utf-8")
        for category, filenames in [("Sources", SOURCES), ("Tests", TESTS)]:
            target = "IlliquidCore" if category == "Sources" else "IlliquidCoreTests"
            destination = package / category / target
            destination.mkdir(parents=True)
            for name in filenames:
                source = ROOT / category / target
                if category == "Sources":
                    source /= "MediaLibrary"
                source /= name
                if name == "NFOMetadataHints.swift" and args.nfo_source:
                    source = args.nfo_source.resolve()
                original = source.read_bytes()
                copied = original
                adaptation = None
                if platform.system() == "Linux":
                    if name == "NFOMetadataHints.swift":
                        copied = copied.replace(b"import Foundation\n", b"import Foundation\nimport FoundationXML\n", 1)
                        adaptation = "add FoundationXML import"
                    elif name == "MediaSidecarReader.swift":
                        copied = copied.replace(b"import Darwin\n", b"import Glibc\n", 1)
                        adaptation = "Darwin import -> Glibc"
                    elif name == "MediaSidecarTests.swift":
                        # These fixtures construct the root before creating it.
                        # Corelibs preserves its missing directory hint, so URL
                        # equality differs from the explicit parent directory.
                        copied = copied.replace(
                            b'appendingPathComponent("sidecar-" + UUID().uuidString)',
                            b'appendingPathComponent("sidecar-" + UUID().uuidString, isDirectory: true)',
                        )
                        adaptation = "explicit directory hint on legacy fixture roots"
                (destination / name).write_bytes(copied)
                receipt["inputs"].append({
                    "path": str(source), "source_sha256": hashlib.sha256(original).hexdigest(),
                    "compiled_sha256": hashlib.sha256(copied).hexdigest(), "adaptation": adaptation,
                })
        command = [swift, "test", "--package-path", str(package),
                   "--configuration", args.configuration, "--no-parallel"]
        if args.filter:
            command += ["--filter", args.filter]
        receipt["filter"] = args.filter
        print(version, flush=True)
        print("Component tests; macOS copies are unmodified, Linux import/fixture adaptations are recorded.", flush=True)
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, end="", flush=True)
        receipt["exit_code"] = result.returncode
        if args.output:
            (args.output / "test.log").write_text(result.stdout, encoding="utf-8")
            (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"NFO component test failed: {error}", file=sys.stderr)
        sys.exit(1)
