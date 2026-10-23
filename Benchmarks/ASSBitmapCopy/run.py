#!/usr/bin/env python3
"""Qualify exact production mask copying and compare owned Data payloads/time."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
CONTEXT = "Sources/IlliquidNativePlayback/Subtitles/LibassContext.swift"
HELPER = "Sources/IlliquidNativePlayback/Subtitles/ASSBitmapCopy.swift"
TESTS = "Tests/IlliquidNativePlaybackTests/ASSBitmapCopyTests.swift"
DEFAULT_CASES = [
    {"name": "tight-control", "width": 256, "height": 48, "stride": 256},
    {"name": "narrow-mask", "width": 13, "height": 17, "stride": 64},
    {"name": "subtitle-line", "width": 211, "height": 42, "stride": 256},
    {"name": "wide-shadow", "width": 365, "height": 48, "stride": 384},
    {"name": "two-line-mask", "width": 211, "height": 96, "stride": 256},
    {"name": "near-aligned-wide", "width": 1915, "height": 80, "stride": 1920},
]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=50)
    parser.add_argument("--cases", type=Path, help="JSON list of {name,width,height,stride}; synthetic pixels")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--tests-only", action="store_true")
    modes.add_argument("--benchmarks-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 6 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("Use an even --pairs >= 6 and a positive --target-ms")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Output directory must be empty or nonexistent")
    for name in ("logs", "sources", "build", "module-cache", "cache", "config", "security"):
        (out / name).mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    for name in ("SWIFT_MODULECACHE_PATH", "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"):
        environment[name] = str(out / "module-cache")
    swift = shutil.which(args.swift) or args.swift
    swiftc = str(Path(swift).resolve().with_name("swiftc"))
    manifest = {"schema_version": 1, "baseline_commit": BASELINE,
                "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "platform": platform.platform(), "machine": platform.machine(),
                "commands": [], "sources": {}, "tests": [], "status": "running",
                "protocol": {"pairs": args.pairs, "target_ms": args.target_ms,
                             "fresh_process_per_observation": True,
                             "timed_operation": "validate geometry, copy one bitmap, consume one visible byte, release copy",
                             "memory_metric": "sum of retained Data.count payload bytes, not allocation capacity or RSS",
                             "fixture_pixels": "deterministic synthetic alpha bytes; fully initialized source padding",
                             "maximum_iterations": 5_000_000}}

    def command(argv, name, cwd=ROOT):
        argv = [str(x) for x in argv]
        started = time.monotonic()
        result = subprocess.run(argv, cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = out / "logs" / (name + ".log")
        log.write_bytes(result.stdout)
        manifest["commands"].append({"argv": argv, "cwd": str(cwd), "exit_code": result.returncode,
                                     "seconds": time.monotonic() - started,
                                     "log": str(log.relative_to(out)), "sha256": sha(result.stdout)})
        write_json(out / "manifest.json", manifest)
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {log}\n" + result.stdout.decode(errors="replace")[-5000:])
        return result.stdout

    def stage(name, data):
        path = out / "sources" / name
        path.write_bytes(data)
        manifest["sources"][str(path.relative_to(out))] = sha(data)
        return path

    try:
        manifest["candidate_head"] = command(["git", "rev-parse", "HEAD"], "head").decode().strip()
        manifest["worktree_status"] = command(["git", "status", "--short"], "status").decode()
        manifest["swift_version"] = command([swift, "--version"], "swift-version").decode().strip()
        if platform.system() == "Darwin":
            manifest["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").decode().strip()
            manifest["macos"] = command(["sw_vers"], "macos").decode().strip()
        else:
            manifest["cpu"] = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                                    if line.startswith("model name")), "unknown")
        input_paths = [ROOT / HELPER, ROOT / TESTS, ROOT / CONTEXT, HERE / "Driver.swift", Path(__file__)]
        input_hashes = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in input_paths}
        manifest["input_sha256"] = input_hashes
        helper = stage("ASSBitmapCopy.swift", (ROOT / HELPER).read_bytes())
        test_source = stage("ASSBitmapCopyTests.swift", (ROOT / TESTS).read_bytes())
        stage("candidate-LibassContext.swift", (ROOT / CONTEXT).read_bytes())
        driver = stage("Driver.swift", (HERE / "Driver.swift").read_bytes())
        stage("run.py", Path(__file__).read_bytes())
        if not args.benchmarks_only:
            package = out / "package"
            production = package / "Sources/IlliquidNativePlayback"
            tests = package / "Tests/IlliquidNativePlaybackTests"
            production.mkdir(parents=True)
            tests.mkdir(parents=True)
            shutil.copyfile(helper, production / helper.name)
            shutil.copyfile(test_source, tests / test_source.name)
            package_source = b'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ASSBitmapCopyQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
])
'''
            (package / "Package.swift").write_bytes(package_source)
            stage("Package.swift", package_source)
            for configuration in ("debug", "release"):
                argv = [swift, "test"]
                if platform.system() == "Linux":
                    argv += ["--use-integrated-swift-driver"]
                argv += ["--package-path", package, "--scratch-path", out / "build" / configuration,
                         "--cache-path", out / "cache", "--config-path", out / "config",
                         "--security-path", out / "security", "-c", configuration,
                         "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"]
                log = command(argv, "tests-" + configuration).decode(errors="replace")
                counts = re.findall(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log)
                if not counts or int(counts[-1]) < 5:
                    raise RuntimeError("Expected at least five successful Swift Testing tests")
                manifest["tests"].append({"configuration": configuration, "passed": int(counts[-1]),
                                          "native_libass_integration": False})
                print(f"{configuration}: {counts[-1]} helper tests passed", flush=True)
        if not args.tests_only:
            baseline_context = command(["git", "show", BASELINE + ":" + CONTEXT], "baseline-context")
            stage("baseline-LibassContext.swift", baseline_context)
            original = baseline_context.decode()
            statements = ["let byteCount = stride * height", "let bytes = Data(bytes: bitmap, count: byteCount)"]
            if any(original.count(statement) != 1 for statement in statements):
                raise RuntimeError("Frozen baseline copy statement provenance changed")
            baseline_adapter = ("import Foundation\n@inline(never)\n"
                "func copyBitmap(from bitmap: UnsafeRawPointer, width: Int, height: Int, sourceStride stride: Int) -> Data {\n"
                + "\n".join("    " + x for x in statements) + "\n    return bytes\n}\n"
                "func copiedBitmapStride(width: Int, sourceStride: Int) -> Int { sourceStride }\n").encode()
            candidate_adapter = b'''import Foundation
@inline(never)
func copyBitmap(from bitmap: UnsafeRawPointer, width: Int, height: Int, sourceStride: Int) -> Data {
    ASSBitmapCopyLayout(width: width, height: height, sourceStride: sourceStride)!.copy(from: bitmap)
}
func copiedBitmapStride(width: Int, sourceStride: Int) -> Int { width }
'''
            adapters = {"baseline": stage("baseline-Adapter.swift", baseline_adapter),
                        "candidate": stage("candidate-Adapter.swift", candidate_adapter)}
            cases = json.loads(args.cases.read_text()) if args.cases else DEFAULT_CASES
            if not isinstance(cases, list) or not cases:
                raise ValueError("Cases must be a nonempty list")
            names = set()
            for case in cases:
                if not re.fullmatch(r"[A-Za-z0-9_-]+", case["name"]) or case["name"] in names:
                    raise ValueError("Case names must be unique path-safe identifiers")
                names.add(case["name"])
                if any(type(case[k]) is not int for k in ("width", "height", "stride")):
                    raise ValueError("Case dimensions must be integers")
                if not (0 < case["width"] <= case["stride"] <= 1_048_576 and 0 < case["height"] <= 1_048_576
                        and case["stride"] * case["height"] <= 128 * 1_024 * 1_024):
                    raise ValueError("Case dimensions exceed safe fixture limits")
            write_json(out / "cases.json", cases)
            manifest["cases_sha256"] = sha((out / "cases.json").read_bytes())
            executables = {}
            flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors",
                     "-module-cache-path", out / "module-cache"]
            if platform.system() == "Darwin":
                sdk = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").decode().strip()
                flags += ["-target", platform.machine() + "-apple-macosx26.0", "-sdk", sdk]
            for variant, adapter in adapters.items():
                build = out / "build" / variant
                build.mkdir()
                library = build / ("libIlliquidNativePlayback" + (".dylib" if platform.system() == "Darwin" else ".so"))
                sources = [adapter] + ([helper] if variant == "candidate" else [])
                command([swiftc, *flags, "-parse-as-library", "-enable-testing", "-module-name", "IlliquidNativePlayback",
                         "-emit-library", "-emit-module", "-emit-module-path", build / "IlliquidNativePlayback.swiftmodule",
                         *sources, "-o", library], variant + "-module")
                executable = build / "bitmap-copy"
                command([swiftc, *flags, "-parse-as-library", driver, "-I", build, "-L", build,
                         "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", build,
                         "-o", executable], variant + "-driver")
                executables[variant] = executable
                manifest.setdefault("binary_sha256", {}).update({str(p.relative_to(out)): sha(p.read_bytes())
                                                                  for p in (library, executable)})
            observations, calibrations, receipts, summaries = [], [], [], []
            for case in cases:
                name = case["name"]
                dimensions = [name, case["width"], case["height"], case["stride"]]
                variants = {}
                for variant, executable in executables.items():
                    row = json.loads(command([executable, "verify", *dimensions, 1], name + "-" + variant + "-verify"))
                    row["variant"] = variant
                    variants[variant] = row
                    receipts.append(row)
                for field in ("visible_checksum", "visible_bytes", "all_visible_pixels_equal", "independent_ownership"):
                    if variants["baseline"][field] != variants["candidate"][field]:
                        raise RuntimeError(f"Parity failed: {name} {field}")
                probes = {}
                for variant, executable in executables.items():
                    probe = json.loads(command([executable, "bench", *dimensions, 2048], name + "-" + variant + "-calibration"))
                    probe["variant"] = variant
                    calibrations.append(probe)
                    probes[variant] = probe["elapsed_ns"] / probe["iterations"]
                count = max(1, min(5_000_000, int(args.target_ms * 1e6 / min(probes.values()))))
                pairs = []
                for pair in range(args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    rows = {}
                    for position, variant in enumerate(order):
                        row = json.loads(command([executables[variant], "bench", *dimensions, count],
                                                 f"{name}-pair-{pair}-{variant}"))
                        row.update(variant=variant, pair=pair, order=position)
                        observations.append(row)
                        rows[variant] = row
                    if rows["baseline"]["checksum"] != rows["candidate"]["checksum"]:
                        raise RuntimeError("Timed pixel checksum mismatch: " + name)
                    pairs.append(rows)
                    write_json(out / "observations.json", observations)
                item = {"name": name, "width": case["width"], "height": case["height"], "stride": case["stride"],
                        "pairs": args.pairs, "iterations": count,
                        "baseline_owned_data_count": variants["baseline"]["owned_data_count"],
                        "candidate_owned_data_count": variants["candidate"]["owned_data_count"],
                        "payload_reduction_percent": 100 * (1 - case["width"] / case["stride"])}
                for metric in ("elapsed_ns", "cpu_ns"):
                    changes = [100 * (p["candidate"][metric] / p["baseline"][metric] - 1) for p in pairs]
                    item[metric] = {"baseline_median_per_copy": statistics.median(p["baseline"][metric] / count for p in pairs),
                                    "candidate_median_per_copy": statistics.median(p["candidate"][metric] / count for p in pairs),
                                    "median_paired_change_percent": statistics.median(changes),
                                    "faster_pairs": sum(x < 0 for x in changes), "paired_changes_percent": changes}
                summaries.append(item)
                print(json.dumps(item, sort_keys=True), flush=True)
            for name, data in (("receipts", receipts), ("calibrations", calibrations), ("summary", summaries)):
                write_json(out / (name + ".json"), data)
            manifest["output_parity"] = {"cases": len(cases), "matched": True}
        for path, expected in input_hashes.items():
            if sha((ROOT / path).read_bytes()) != expected:
                raise RuntimeError("Input source changed during qualification: " + path)
        manifest["status"] = "passed"
    except Exception as exc:
        manifest["status"] = "failed"
        manifest["error"] = str(exc)
        raise
    finally:
        write_json(out / "manifest.json", manifest)


if __name__ == "__main__":
    main()
