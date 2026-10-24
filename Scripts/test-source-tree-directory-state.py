#!/usr/bin/env python3
"""Test the sidebar's actual directory consumer without SwiftUI/native playback.

Reuses the guarded browser support extraction, copies the complete consumer and
planner, and runs the repository's consumer and browser-search tests. No timing
campaign or filesystem enumeration is performed. All builds use at most 2 jobs.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--output", type=Path, required=True, help="New directory for source receipt and test log")
    parser.add_argument("--legacy-root-control", action="store_true",
                        help="Restore the former root + '/' predicate in the disposable package; tests should fail")
    args = parser.parse_args()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Output directory must be new or empty")
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift 6.1+ with its bundled Testing module is required")
    args.output.mkdir(parents=True, exist_ok=True)
    support_path = ROOT / "Scripts/test-source-browser-search.py"
    spec = importlib.util.spec_from_file_location("browser_support", support_path)
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    version = subprocess.check_output([swift, "--version"], text=True).strip()

    with tempfile.TemporaryDirectory(prefix="illiquid-directory-state-") as temporary:
        package = support.prepare_package(Path(temporary) / "package")
        receipt = json.loads((package / "source-receipt.json").read_text())

        def stage(path: str, destination: str, data: bytes | None = None) -> None:
            original = (ROOT / path).read_bytes()
            staged = original if data is None else data
            target = package / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(staged)
            receipt["inputs"].append({"path": path, "source_sha256": support.digest(original),
                "compiled_path": destination, "compiled_sha256": support.digest(staged)})

        for name in ["SourceTreeDirectoryState", "SourceFilesystemInvalidation"]:
            stage(f"Sources/IlliquidApp/UI/{name}.swift", f"Sources/IlliquidApp/{name}.swift")
        stage("Tests/IlliquidAppTests/SourceTreeDirectoryStateTests.swift",
              "Tests/IlliquidAppTests/SourceTreeDirectoryStateTests.swift")
        sidebar = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
        listing, first, last = support.declaration((ROOT / sidebar).read_text(), "SourceDirectoryListing")
        stage(sidebar, "Sources/IlliquidApp/SourceDirectoryListing.swift",
              ("import Foundation\n\n" + listing + "\n").encode())
        receipt["inputs"][-1]["declarations"] = [{"name": "SourceDirectoryListing", "first_line": first,
            "last_line": last, "slice_sha256": support.digest(listing.encode())}]

        if args.legacy_root_control:
            extracted = package / "Sources/IlliquidApp/SourceBrowserPortableSupport.swift"
            text = extracted.read_text()
            old = 'path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")'
            if text.count(old) != 1:
                raise ValueError("Expected exactly one shared root-containment predicate")
            modified = text.replace(old, 'path.hasPrefix(rootPath + "/")')
            extracted.write_text(modified)
            receipt["legacy_root_control"] = {"original_support_sha256": support.digest(text.encode()),
                "compiled_support_sha256": support.digest(modified.encode()),
                "mutation": "Restore the former double-slash containment predicate only"}

        environment = os.environ.copy()
        environment["CLANG_MODULE_CACHE_PATH"] = str(Path(temporary) / "clang-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(Path(temporary) / "swift-cache")
        command = [swift, "test", "--package-path", str(package), "--scratch-path", str(Path(temporary) / "build"),
            "--configuration", args.configuration, "--jobs", "2", "-Xswiftc", "-warnings-as-errors"]
        print(version, flush=True)
        print("Actual-source sidebar consumer tests; SwiftUI/native playback and live FSEvents are outside this harness.", flush=True)
        result = subprocess.run(command, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, end="", flush=True)
        counts = re.findall(r"Test run with (\d+) tests?\b", result.stdout)
        test_count = int(counts[-1]) if counts else 0
        exit_code = result.returncode or (0 if test_count > 0 else 1)
        receipt.update({"toolchain": version, "configuration": args.configuration, "command": command,
            "test_count": test_count, "swift_exit_code": result.returncode, "exit_code": exit_code,
            "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
        (args.output / "test.log").write_text(result.stdout)
        (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
