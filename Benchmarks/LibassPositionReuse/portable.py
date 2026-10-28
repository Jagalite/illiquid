#!/usr/bin/env python3
"""Exploratory Linux validation of real-libass position-only mask reuse.

This does not qualify macOS/CoreGraphics/CryptoKit, Metal, playback, or energy.
Run inside an official Swift Linux image with Python 3.10+, a C toolchain,
pkg-config, FreeType, HarfBuzz, FriBidi, Fontconfig, NASM, and installed fonts.
Only imports are adapted; production Swift bodies and the native Driver/tests
remain unchanged. The libass archive and Swift package resolutions are pinned.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LIBASS_VERSION = "0.17.5"
LIBASS_ARCHIVE = "DependencySources/archives/libass-0.17.5.tar.xz"
LIBASS_SHA256 = "2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"
CRYPTO_VERSION = "3.12.3"
CRYPTO_REVISION = "e8d6eba1fef23ae5b359c46b03f7d94be2f41fed"
ASN1_VERSION = "1.3.1"
ASN1_REVISION = "ae33e5941bb88d88538d0a6b19ca0b01e6c76dcf"

spec = importlib.util.spec_from_file_location("libass_native_runner", HERE / "run.py")
if spec is None or spec.loader is None:
    raise RuntimeError("Cannot load the native benchmark helpers")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def run(command: list[str], output: Path, *, timeout: int = 300,
        cwd: Path = ROOT, env: dict[str, str] | None = None) -> str:
    """Retain exact commands and complete logs, including failed commands."""
    logs = output / "logs"
    logs.mkdir(exist_ok=True)
    number = len(list(logs.glob("*.txt")))
    log = logs / f"{number:04d}.txt"
    start = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                            text=True, timeout=timeout)
    log.write_text(result.stdout + result.stderr)
    native.append(output / "commands.jsonl", {
        "command": command, "cwd": str(cwd), "returncode": result.returncode,
        "elapsed_seconds": time.monotonic() - start,
        "log": str(log.relative_to(output)),
    })
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command!r}\n{log.read_text()}")
    return result.stdout


# Reuse the exact source extraction, receipt validation, parity checks and
# statistical summary used by run.py. Its subprocess helper now also supports
# the out-of-source C build; the measured driver itself is unchanged.
native.run = run


def adapt(content: bytes, module: str) -> tuple[bytes, list[dict]]:
    edits = []
    text = content.decode()
    for before, after in [
        ("import CoreGraphics\n", "import Foundation\n"),
        ("import CryptoKit\n", "import Crypto\n"),
        ("@testable import IlliquidNativePlayback\n", f"@testable import {module}\n"),
    ]:
        count = text.count(before)
        if count > 1:
            raise RuntimeError(f"Import adapter is ambiguous: {before!r}")
        if count:
            text = text.replace(before, after)
            edits.append({"from": before.rstrip(), "to": after.rstrip()})
    # Fail closed if a future edit ever changes anything except import lines.
    def body(value: str) -> str:
        return "".join(line for line in value.splitlines(keepends=True)
                       if not line.startswith(("import ", "@testable import ")))
    if body(content.decode()) != body(text):
        raise RuntimeError("Portable adapter changed a Swift body")
    return text.encode(), edits


def build_libass(output: Path, jobs: int) -> tuple[Path, dict]:
    manifest_path = ROOT / "DependencySources/source-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    records = [record for record in manifest["records"] if record["component"] == "libass"]
    if len(records) != 1:
        raise RuntimeError("Expected one pinned libass source record")
    record = records[0]
    archive = ROOT / LIBASS_ARCHIVE
    if (record["installed_version"] != LIBASS_VERSION
            or "DependencySources/" + record["archive"] != LIBASS_ARCHIVE
            or record["sha256"] != LIBASS_SHA256
            or record["expected_sha256"] != LIBASS_SHA256
            or native.sha(archive.read_bytes()) != LIBASS_SHA256):
        raise RuntimeError("Pinned libass source/archive verification failed")
    work = output / "build" / "native"
    work.mkdir(parents=True)
    run(["tar", "-xJf", str(archive), "-C", str(work)], output)
    source = work / f"libass-{LIBASS_VERSION}"
    prefix = output / "build" / "libass"
    build = work / "objects"
    build.mkdir()
    environment = dict(os.environ, CFLAGS="-O2")
    run([str(source / "configure"), f"--prefix={prefix}",
         "--enable-shared", "--disable-static"], output, timeout=300,
        cwd=build, env=environment)
    run(["make", f"-j{jobs}"], output, timeout=600, cwd=build)
    run(["make", "install"], output, timeout=120, cwd=build)
    # Both executable variants use this one real shared C library/font stack.
    for name, directory in [
        ("PKG_CONFIG_PATH", prefix / "lib/pkgconfig"),
        ("LD_LIBRARY_PATH", prefix / "lib"),
    ]:
        previous = os.environ.get(name)
        os.environ[name] = str(directory) + (os.pathsep + previous if previous else "")
    version = run(["pkg-config", "--modversion", "libass"], output).strip()
    if version != LIBASS_VERSION:
        raise RuntimeError(f"Wrong libass version selected: {version!r}")
    library = prefix / "lib/libass.so"
    if not library.is_file():
        raise RuntimeError("Expected the built Linux shared libass")
    shutil.copyfile(build / "config.log", output / "libass-config.log")
    return prefix, {
        "version": version, "archive": LIBASS_ARCHIVE,
        "archive_sha256": LIBASS_SHA256,
        "source_manifest_sha256": native.sha(manifest_path.read_bytes()),
        "library_sha256": native.sha(library.read_bytes()),
        "header_sha256": native.sha((prefix / "include/ass/ass.h").read_bytes()),
        "compiler": run(["cc", "--version"], output).strip(),
        "cflags": "-O2", "configuration": ["--enable-shared", "--disable-static"],
        "dependencies": {
            name: run(["pkg-config", "--modversion", name], output).strip()
            for name in ("freetype2", "harfbuzz", "fribidi", "fontconfig")
        },
    }


def package(output: Path) -> tuple[Path, dict]:
    destination = output / "build" / "package"
    source_records = {}
    targets = ['.systemLibrary(name: "CLibass", pkgConfig: "libass")']
    for variant, suffix in (("baseline", "Baseline"), ("candidate", "Candidate")):
        module = "IlliquidNativePlayback" + suffix
        source_directory = destination / "Sources" / module
        files, hashes = native.prepare(variant, source_directory, output)
        support_files, support_hashes = native.prepare_test_dependencies(
            variant, source_directory, output)
        files.extend(support_files)
        hashes.update(support_hashes)
        adapted = {}
        for path in files:
            original = path.read_bytes()
            changed, edits = adapt(original, module)
            path.write_bytes(changed)
            adapted[path.name] = {
                "source_sha256": native.sha(original),
                "adapted_sha256": native.sha(changed),
                "import_edits": edits,
            }
        driver_name = "Libass" + suffix
        driver_directory = destination / "Sources" / driver_name
        driver_directory.mkdir(parents=True)
        original_driver = (HERE / "Driver.swift").read_bytes()
        driver, edits = adapt(original_driver, module)
        (driver_directory / "Driver.swift").write_bytes(driver)
        tests_name = module + "Tests"
        tests_directory = destination / "Tests" / tests_name
        tests_directory.mkdir(parents=True)
        test_records = {}
        names = native.EXISTING_TESTS + ([native.NEW_TEST] if variant == "candidate" else [])
        for name in names:
            original = (ROOT / "Tests/IlliquidNativePlaybackTests" / name).read_bytes()
            changed, test_edits = adapt(original, module)
            (tests_directory / name).write_bytes(changed)
            test_records[name] = {
                "source_sha256": native.sha(original),
                "adapted_sha256": native.sha(changed),
                "import_edits": test_edits,
            }
        source_records[variant] = {
            "module": module, "source_sha256": hashes, "adapted_sources": adapted,
            "driver_source_sha256": native.sha(original_driver),
            "driver_adapted_sha256": native.sha(driver),
            "driver_import_edits": edits, "tests": test_records,
        }
        crypto = '.product(name: "Crypto", package: "swift-crypto")'
        targets.append(
            f'.target(name: "{module}", dependencies: ["CLibass", {crypto}], '
            'swiftSettings: [.unsafeFlags(["-enable-testing", "-warnings-as-errors"])])')
        define = ', .define("POSITION_REUSE")' if variant == "candidate" else ""
        targets.append(
            f'.executableTarget(name: "{driver_name}", dependencies: ["{module}", {crypto}], '
            f'swiftSettings: [.unsafeFlags(["-warnings-as-errors"]){define}])')
        targets.append(
            f'.testTarget(name: "{tests_name}", dependencies: ["{module}", {crypto}], '
            'swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])')
    for path in native.HEADER_PATHS:
        content = (ROOT / path).read_bytes()
        if native.source("baseline", path, output) != content:
            raise RuntimeError("Baseline/candidate libass shim changed")
    shutil.copytree(ROOT / "Sources/CLibass", destination / "Sources/CLibass")
    swift_manifest = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "LibassPositionReuseLinuxExploration",
    products: [
        .executable(name: "LibassBaseline", targets: ["LibassBaseline"]),
        .executable(name: "LibassCandidate", targets: ["LibassCandidate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "@@CRYPTO_VERSION@@"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "@@ASN1_VERSION@@"),
    ],
    targets: [
        @@TARGETS@@
    ],
    swiftLanguageModes: [.v6]
)
"""
    swift_manifest = swift_manifest.replace("@@CRYPTO_VERSION@@", CRYPTO_VERSION)
    swift_manifest = swift_manifest.replace("@@ASN1_VERSION@@", ASN1_VERSION)
    swift_manifest = swift_manifest.replace("@@TARGETS@@", ",\n        ".join(targets))
    (destination / "Package.swift").write_text(swift_manifest)
    shutil.copyfile(destination / "Package.swift", output / "portable-Package.swift")
    return destination, source_records


def verify_packages(directory: Path, output: Path) -> dict:
    run(["swift", "package", "--package-path", str(directory), "resolve"], output, timeout=600)
    resolved = json.loads((directory / "Package.resolved").read_text())
    pins = {pin["identity"]: pin for pin in resolved["pins"]}
    expected = {"swift-crypto": CRYPTO_REVISION, "swift-asn1": ASN1_REVISION}
    if set(pins) != set(expected):
        raise RuntimeError(f"Unexpected Swift dependency set: {sorted(pins)}")
    for identity, revision in expected.items():
        if pins[identity]["state"]["revision"] != revision:
            raise RuntimeError(f"Unexpected resolved revision for {identity}")
    shutil.copyfile(directory / "Package.resolved", output / "Package.resolved")
    return resolved


def verify_and_build(directory: Path, prefix: Path, output: Path, jobs: int) -> tuple[dict, dict]:
    configurations = {}
    # Each command runs both variant test targets. One generated package means
    # Crypto is compiled once per configuration, not four times.
    for configuration in ("debug", "release"):
        run(["swift", "test", "--package-path", str(directory), "--jobs", str(jobs),
             "--no-parallel", "-c", configuration], output, timeout=900)
        log = sorted((output / "logs").glob("*.txt"))[-1].read_text()
        counts = re.findall(r"Test run with ([1-9][0-9]*) tests? passed", log)
        if not counts or "libass position-only mask reuse" not in log:
            raise RuntimeError("Expected nonempty candidate/legacy Swift Testing suites")
        configurations[configuration] = {
            "status": "passed", "total_tests": int(counts[-1]),
            "targets": [
                "IlliquidNativePlaybackBaselineTests",
                "IlliquidNativePlaybackCandidateTests",
            ],
        }
        print(f"Linux exploratory baseline/candidate {configuration} tests passed", flush=True)
    executables = {}
    receipts = {}
    for variant, product in (("baseline", "LibassBaseline"), ("candidate", "LibassCandidate")):
        run(["swift", "build", "--package-path", str(directory), "--jobs", str(jobs),
             "-c", "release", "--product", product], output, timeout=600)
        binary_directory = Path(run(
            ["swift", "build", "--package-path", str(directory),
             "-c", "release", "--show-bin-path"], output).strip())
        executable = binary_directory / product
        linkage = run(["ldd", str(executable)], output)
        if str(prefix / "lib/libass.so") not in linkage:
            raise RuntimeError("Benchmark did not link the verified libass build")
        executables[variant] = executable
        receipts[variant] = {
            "executable_sha256": native.sha(executable.read_bytes()),
            "linkage": linkage,
            "optimization": "SwiftPM release (-O), separate variant module, -enable-testing",
        }
    return executables, {"configurations": configurations, "builds": receipts}


def measurements(executables: dict, output: Path, args: argparse.Namespace) -> dict:
    rows = []
    for case in native.CASES:
        calibration = {}
        for variant, executable in executables.items():
            first = native.measure(executable, case, 1, 1000, output)
            cycles = max(1, min(1000, math.ceil(20_000_000 / first["elapsed_ns"])))
            probe = native.measure(executable, case, cycles, 1000, output)
            calibration[variant] = probe["elapsed_ns"] / cycles
            native.append(output / "calibration.jsonl", {"variant": variant, "stage": "single", **first})
            native.append(output / "calibration.jsonl", {"variant": variant, "stage": "probe", **probe})
        cycles = max(1, min(
            math.ceil(args.target_ms * 1e6 / min(calibration.values())),
            math.floor(args.max_sample_ms * 1e6 / max(calibration.values()))))
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            paired = {}
            for variant in order:
                row = native.measure(executables[variant], case, cycles, 2000 + pair, output)
                row.update(variant=variant, pair=pair, order=list(order),
                           qualification_scope="Linux exploratory")
                native.append(output / "measurements.jsonl", row)
                rows.append(row)
                paired[variant] = row
            native.parity(paired["baseline"], paired["candidate"])
        summary = native.summarize(rows)
        native.save(output / "summary.json", summary)
        print("LINUX_EXPLORATORY " + case + " " + json.dumps(summary[case], sort_keys=True), flush=True)
    return native.summarize(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--max-sample-ms", type=float, default=1500)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--image-receipt", type=Path)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This adapter is exclusively Linux exploratory validation")
    if (args.pairs < 2 or args.pairs % 2 or args.jobs < 1 or args.target_ms <= 0
            or args.max_sample_ms < args.target_ms):
        parser.error("Use even pairs >= 2, jobs >= 1, and valid timing bounds")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Output must be empty; preserve previous attempts separately")
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "qualification_scope": "Linux exploratory; not native macOS qualification",
        "collected_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "baseline_commit": native.BASELINE,
        "git_head": run(["git", "rev-parse", "HEAD"], output).strip(),
        "git_status": run(["git", "status", "--porcelain"], output).strip(),
        "platform": platform.platform(), "machine": platform.machine(),
        "hardware": run(["lscpu"], output).strip(),
        "swift": run(["swiftc", "--version"], output).strip(),
        "official_image": os.environ.get("SWIFT_IMAGE"),
        "driver_sha256": native.sha((HERE / "Driver.swift").read_bytes()),
        "native_runner_sha256": native.sha((HERE / "run.py").read_bytes()),
        "portable_runner_sha256": native.sha(Path(__file__).read_bytes()),
        "header_sha256": {path: native.sha((ROOT / path).read_bytes()) for path in native.HEADER_PATHS},
        "arguments": {**vars(args), "output": str(output),
                      "image_receipt": str(args.image_receipt) if args.image_receipt else None},
        "adapters": [
            "CoreGraphics import -> Foundation geometry",
            "CryptoKit import -> pinned official Swift Crypto",
            "Testable module import -> separately compiled baseline/candidate target",
        ],
        "method": "Exact production Swift bodies, same Driver/tests, real libass 0.17.5, "
                  "real C libass with full-copy reference, same Linux font stack, alternating "
                  "fresh-process optimized AB/BA pairs; all samples retained.",
        "limits": "Linux Foundation geometry, Swift Crypto, x86_64/arm64 Linux font/native "
                  "stack and compiler may differ from macOS. No Apple renderer, live "
                  "player, GPU, Instruments or energy qualification.",
    }
    native.save(output / "manifest.json", manifest)
    try:
        if args.image_receipt:
            shutil.copyfile(args.image_receipt, output / "container-image.json")
        font_paths = sorted(set(run(["fc-list", "-f", "%{file}\n"], output).splitlines()))
        manifest["fonts_sha256"] = {
            path: native.sha(Path(path).read_bytes()) for path in font_paths if path
        }
        manifest["arial_font_match"] = run(
            ["fc-match", "-f", "%{family}|%{style}|%{file}\n", "Arial"], output).strip()
        prefix, manifest["libass"] = build_libass(output, args.jobs)
        native.save(output / "manifest.json", manifest)
        directory, manifest["sources"] = package(output)
        native.save(output / "manifest.json", manifest)
        manifest["swift_packages"] = verify_packages(directory, output)
        native.save(output / "manifest.json", manifest)
        executables, validation = verify_and_build(directory, prefix, output, args.jobs)
        native.save(output / "tests.json", validation["configurations"])
        manifest["builds"] = validation["builds"]
        native.save(output / "manifest.json", manifest)
        measurements(executables, output, args)
        native.save(output / "qualification.json", {
            "status": "passed", "scope": "Linux exploratory only",
            "native_macos_qualified": False,
            "baseline_commit": native.BASELINE,
            "pairs_per_case": args.pairs, "cases": native.CASES,
            "source_body_parity": "import-only adapters verified",
            "visual_parity": "passed against real-libass full-copy oracle",
            "tests": validation["configurations"],
        })
    except Exception as error:
        native.save(output / "failure.json", {"error": str(error), "scope": "Linux exploratory"})
        raise


if __name__ == "__main__":
    main()
