#!/usr/bin/env python3
"""Test actual source-browser search and projection sources on macOS or Linux.

The disposable package uses complete Filter/Input files and verbatim portable
declarations from AppModel/SourcesSidebar, with source and slice hashes. It
requires Swift 6.1+ with its bundled Testing module and has no network packages.
This component harness does not build SwiftUI or the native playback targets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE_REF = "68274d1b09dcc866296321a5a8858efc297c4f19"
FILTER_PATH = "Sources/IlliquidApp/UI/SourceBrowserFilter.swift"
MANIFEST = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SourceBrowserSearchRegression",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),
    ]
)
'''
DECLARATIONS = {
    "Sources/IlliquidApp/App/AppModel.swift": [
        "SourceTabItem", "SourceVisibilityViewMode", "SourceVisibilityRegexRule",
        "SourceVisibilityConfiguration", "SourceVisibilityPath",
    ],
    "Sources/IlliquidApp/UI/SourcesSidebar.swift": [
        "SourceTreeEntry", "SourceVisibilityRegexMatch", "SourceVisibilityHideMatch",
        "SourceVisibilityEvaluation", "SourceRowVisibility", "SourceVisibilityMatcher",
        "SourceVisibilityProjection", "SourceTreeSortCriterion", "SourceTreeSortDirection",
        "SourceTreeSortConfiguration", "SourceTreeSorting", "SourceTreeDisplayRow",
        "SourceTreeIdentity",
    ],
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def declaration(text: str, name: str) -> tuple[str, int, int]:
    """Extract one exact top-level declaration, failing if its boundary drifts."""
    starts = list(re.finditer(rf"(?m)^(?:struct|enum) {re.escape(name)}(?=[: {{])", text))
    if len(starts) != 1:
        raise ValueError(f"Expected exactly one portable declaration of {name}")
    start = starts[0].start()
    closing = re.search(r"(?m)^}$", text[start:])
    if closing is None:
        raise ValueError(f"No top-level closing brace for {name}")
    end = start + closing.end()
    return text[start:end], text.count("\n", 0, start) + 1, text.count("\n", 0, end) + 1


def prepare_package(
    output: Path, source_ref: str | None = None, *,
    filter_source: Path | None = None, include_tests: bool = True,
) -> Path:
    """Create portable targets and source-receipt.json; return the package root.

    Benchmarks can reuse this function and add their own executable target.
    source_ref overrides only SourceBrowserFilter via git show; shared support
    declarations and the new regression tests always come from the working tree.
    filter_source alternatively supplies an exact Filter file, for local probes.
    """
    if source_ref is not None and filter_source is not None:
        raise ValueError("Choose source_ref or filter_source, not both")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "Package.swift").exists() or (output / "Sources").exists():
        raise ValueError(f"Package output already contains sources: {output}")
    manifest = MANIFEST
    if not include_tests:
        manifest = manifest.replace(
            '        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"]),\n', ""
        )
    (output / "Package.swift").write_text(manifest, encoding="utf-8")
    inputs: list[dict] = []

    def copy_source(path: str, target: str, data: bytes | None = None, origin: str = "working-tree") -> None:
        original = (ROOT / path).read_bytes() if data is None else data
        destination = output / target / Path(path).name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(original)
        inputs.append({"path": path, "origin": origin, "source_sha256": digest(original),
                       "compiled_path": str(destination.relative_to(output)),
                       "compiled_sha256": digest(original)})

    for path in ["Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
                 "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift"]:
        copy_source(path, "Sources/IlliquidCore")
    copy_source("Sources/IlliquidApp/UI/SourceTreeProjectionInput.swift", "Sources/IlliquidApp")
    if source_ref is not None:
        resolved_ref = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--verify", source_ref + "^{commit}"], text=True
        ).strip()
        original = subprocess.check_output(["git", "-C", str(ROOT), "show", resolved_ref + ":" + FILTER_PATH])
        copy_source(FILTER_PATH, "Sources/IlliquidApp", original, resolved_ref)
    elif filter_source is not None:
        resolved_ref = None
        copy_source(FILTER_PATH, "Sources/IlliquidApp", Path(filter_source).read_bytes(), str(Path(filter_source).resolve()))
    else:
        resolved_ref = None
        copy_source(FILTER_PATH, "Sources/IlliquidApp")

    support = "import Foundation\nimport IlliquidCore\n\n"
    for path, names in DECLARATIONS.items():
        original = (ROOT / path).read_bytes()
        text = original.decode("utf-8")
        slices = []
        for name in names:
            extracted, first_line, last_line = declaration(text, name)
            support += extracted + "\n\n"
            slices.append({"name": name, "first_line": first_line, "last_line": last_line,
                           "slice_sha256": digest(extracted.encode("utf-8"))})
        inputs.append({"path": path, "origin": "working-tree", "source_sha256": digest(original),
                       "declarations": slices})
    support_path = output / "Sources/IlliquidApp/SourceBrowserPortableSupport.swift"
    support_path.write_text(support, encoding="utf-8")
    if include_tests:
        copy_source("Tests/IlliquidAppTests/SourceBrowserSearchTests.swift", "Tests/IlliquidAppTests")
    receipt = {"source_ref": resolved_ref, "inputs": inputs,
               "support_sha256": digest(support.encode("utf-8")),
               "manifest_sha256": digest(manifest.encode("utf-8")),
               "harness_sha256": digest(Path(__file__).read_bytes())}
    (output / "source-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--baseline-ref", nargs="?", const=BASELINE_REF,
                        help="Compile the old Filter from this git ref; bare flag uses the pinned main revision")
    parser.add_argument("--output", type=Path, help="Save full test.log and source/test receipt.json")
    parser.add_argument("--swift", default=shutil.which("swift"), help="Swift 6.1+ executable")
    args = parser.parse_args()
    if args.swift is None:
        parser.error("Swift 6.1+ with its bundled Testing module must be installed")
    if platform.system() not in {"Darwin", "Linux"}:
        parser.error("This component harness supports macOS and Linux")
    # Preserve the swift symlink name: the driver selects behavior from argv[0].
    swift = str(Path(args.swift).absolute()) if Path(args.swift).exists() else shutil.which(args.swift)
    if swift is None:
        parser.error(f"Swift executable not found: {args.swift}")
    if args.output:
        if args.output.exists() and any(args.output.iterdir()):
            parser.error(f"Output directory must be new or empty: {args.output}")
        args.output.mkdir(parents=True, exist_ok=True)
    version = subprocess.check_output([swift, "--version"], text=True).strip()
    print(version, flush=True)
    print("Actual-source browser component tests; SwiftUI/native playback targets are outside this harness.", flush=True)
    with tempfile.TemporaryDirectory(prefix="illiquid-browser-search-") as temporary:
        package = prepare_package(Path(temporary) / "package", args.baseline_ref)
        receipt = json.loads((package / "source-receipt.json").read_text())
        environment = os.environ.copy()
        # Keep compiler/module caches independent of simultaneous repo work.
        environment["CLANG_MODULE_CACHE_PATH"] = str(Path(temporary) / "clang-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(Path(temporary) / "swift-cache")
        command = [swift, "test", "--package-path", str(package),
                   "--scratch-path", str(Path(temporary) / "build"),
                   "--cache-path", str(Path(temporary) / "package-cache"),
                   "--config-path", str(Path(temporary) / "package-config"),
                   "--security-path", str(Path(temporary) / "package-security"),
                   "--configuration", args.configuration, "--no-parallel"]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, env=environment)
        print(result.stdout, end="", flush=True)
        counts = re.findall(r"Test run with (\d+) tests?\b", result.stdout)
        test_count = int(counts[-1]) if counts else 0
        exit_code = result.returncode
        if exit_code == 0 and test_count == 0:
            print("Refusing success: no completed Swift Testing tests were reported.", file=sys.stderr)
            exit_code = 1
        receipt.update({"toolchain": version, "platform": platform.platform(),
                        "configuration": args.configuration, "command": command,
                        "test_count": test_count, "swift_exit_code": result.returncode,
                        "exit_code": exit_code})
        if args.output:
            (args.output / "test.log").write_text(result.stdout, encoding="utf-8")
            (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Source browser component test failed: {error}", file=sys.stderr)
        sys.exit(1)
