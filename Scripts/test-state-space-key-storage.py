#!/usr/bin/env python3
"""Run the complete playback-core and state-space suites from exact source files.

The disposable package contains both complete production modules and their full
test directories. Its IlliquidCore dependency is the actual, self-contained
MediaTrack.swift file; no source excerpts, model stubs, or platform shims are
used. Swift's bundled Testing module avoids fetching the app's native package
dependencies. This checks the model explorer, not media decoding or the UI.

Use --baseline REV to stage production sources and tests from a Git revision.
Otherwise this tests the current worktree, including new regression tests.
Builds have isolated caches and run at most two compiler jobs. Submit this script
through the repository's shared Kyoto queue when that queue is available.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRECTORIES = (
    "Sources/IlliquidPlaybackCore",
    "Sources/IlliquidPlaybackStateSpace",
    "Tests/IlliquidPlaybackCoreTests",
    "Tests/IlliquidPlaybackStateSpaceTests",
)
MANIFEST = """// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "StateSpaceKeyStorageTests",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidPlaybackCore", dependencies: ["IlliquidCore"]),
        .target(name: "IlliquidPlaybackStateSpace", dependencies: ["IlliquidPlaybackCore"]),
        .testTarget(name: "IlliquidPlaybackCoreTests", dependencies: ["IlliquidPlaybackCore"]),
        .testTarget(name: "IlliquidPlaybackStateSpaceTests", dependencies: ["IlliquidPlaybackStateSpace"]),
    ],
    swiftLanguageModes: [.v6]
)
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments])


def stage(package: Path, revision: str | None) -> list[dict[str, str]]:
    paths = ["Sources/IlliquidCore/Player/MediaTrack.swift"]
    for directory in SOURCE_DIRECTORIES:
        entries = (
            git("ls-tree", "-r", "--name-only", revision, "--", directory).decode().splitlines()
            if revision
            else [path.relative_to(ROOT).as_posix() for path in sorted((ROOT / directory).rglob("*.swift"))]
        )
        swift_paths = sorted(path for path in entries if path.endswith(".swift"))
        if not swift_paths:
            raise ValueError(f"No Swift sources found in {directory}")
        paths.extend(swift_paths)

    receipts = []
    for relative in paths:
        original = git("show", f"{revision}:{relative}") if revision else (ROOT / relative).read_bytes()
        destination = package / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(original)
        compiled = destination.read_bytes()
        if compiled != original:
            raise ValueError(f"Staged source differs: {relative}")
        receipts.append({
            "path": relative,
            "source_sha256": sha256(original),
            "compiled_path": relative,
            "compiled_sha256": sha256(compiled),
            "transformation": "none",
        })
    (package / "Package.swift").write_text(MANIFEST)
    return receipts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="New or empty directory for source receipt and test log")
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--baseline", help="Read both source modules and tests from this Git revision")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("Output directory must be new or empty")
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift 6.1+ with its bundled Testing module is required")
    revision = git("rev-parse", "--verify", f"{args.baseline}^{{commit}}").decode().strip() if args.baseline else None
    version = subprocess.check_output([swift, "--version"], text=True).strip()
    output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="illiquid-state-space-tests-") as temporary:
        temporary_root = Path(temporary)
        package = temporary_root / "package"
        inputs = stage(package, revision)
        environment = os.environ.copy()
        environment.update(
            CLANG_MODULE_CACHE_PATH=str(temporary_root / "clang-cache"),
            SWIFT_MODULECACHE_PATH=str(temporary_root / "swift-cache"),
            SWIFTPM_MODULECACHE_OVERRIDE=str(temporary_root / "swift-cache"),
            TERM="dumb",
            NO_COLOR="1",
        )
        command = [
            swift, "test", "--package-path", str(package),
            "--scratch-path", str(temporary_root / "build"),
            "--cache-path", str(temporary_root / "cache"),
            "--config-path", str(temporary_root / "config"),
            "--security-path", str(temporary_root / "security"),
            "--configuration", args.configuration, "--jobs", "2", "--no-parallel",
            "-Xswiftc", "-warnings-as-errors",
        ]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        receipt = {
            "scope": "Exact playback-core and state-space modules and full test suites; no native playback or UI",
            "illiquid_core_dependency": "Actual MediaTrack.swift only; no stubs or source transformations",
            "source_revision": revision,
            "source_mode": "git revision" if revision else "current worktree",
            "worktree_head": git("rev-parse", "HEAD").decode().strip(),
            "inputs": inputs,
            "manifest": MANIFEST,
            "manifest_sha256": sha256(MANIFEST.encode()),
            "harness_sha256": sha256(Path(__file__).read_bytes()),
            "toolchain": version,
            "platform": platform.platform(),
            "configuration": args.configuration,
            "command": command,
        }
        receipt_path = output / "receipt.json"
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        print(version, flush=True)
        print(receipt["scope"], flush=True)
        print(f"Staged {len(inputs)} byte-identical Swift files; {args.configuration} tests.", flush=True)
        with (output / "test.log").open("w") as log:
            process = subprocess.Popen(command, env=environment, text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            lines = []
            assert process.stdout is not None
            for line in process.stdout:
                log.write(line)
                log.flush()
                print(line, end="", flush=True)
                lines.append(line)
            swift_exit_code = process.wait()
        counts = re.findall(r"Test run with (\d+) tests?\b", "".join(lines))
        test_count = int(counts[-1]) if counts else 0
        exit_code = swift_exit_code or (0 if test_count > 0 else 1)
        receipt.update(test_count=test_count, swift_exit_code=swift_exit_code, exit_code=exit_code)
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        if swift_exit_code == 0 and test_count == 0:
            print("ERROR: Swift exited successfully but reported no executed Swift Testing tests.", flush=True)
        return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
