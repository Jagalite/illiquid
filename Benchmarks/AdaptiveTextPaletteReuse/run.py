#!/usr/bin/env python3
"""Measure actual PlayerTextPalette.colors with balanced, isolated process pairs.

The native path uses SwiftUI/AppKit. Linux uses an explicitly identified numeric
Color stand-in, omitting only PlayerTheme's AppKit convenience color accessors.
Palette selection, regions, legibility, and cache implementations are extracted
unchanged from production sources. Every generated source and command is retained.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
THEME = Path("Sources/IlliquidApp/UI/PlayerTheme.swift")
SUPPORT = {
    "VideoColorSample.swift": Path("Sources/IlliquidCore/Player/VideoColorSample.swift"),
    "PlaybackVideoColorStore.swift": Path("Sources/IlliquidPlayer/Player/PlaybackVideoColorStore.swift"),
    "AdaptiveTextLegibility.swift": Path("Sources/IlliquidApp/UI/AdaptiveTextLegibility.swift"),
    "PlayerOverlayMaterial.swift": Path("Sources/IlliquidApp/UI/PlayerOverlayMaterial.swift"),
}
TEST = Path("Tests/IlliquidAppTests/AdaptiveTextPaletteReuseTests.swift")
KERNELS = ("uncached", "revision", "hit", "component_hit")
PALETTE_START = "@MainActor\nstruct PlayerTextPalette {"
PALETTE_END = "\n@MainActor\nprivate struct DynamicPlayerTextStyleModifier:"


def digest_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest(path: Path) -> str:
    return digest_bytes(path.read_bytes())


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def unique_index(source: str, marker: str) -> int:
    if source.count(marker) != 1:
        raise ValueError(f"Expected exactly one source boundary: {marker!r}")
    return source.index(marker)


def unchanged_theme_support(source: str) -> str:
    start = unique_index(source, PALETTE_START)
    end = unique_index(source, PALETTE_END)
    if end <= start:
        raise ValueError("PlayerTextPalette boundaries are out of order")
    return source[:start] + source[end:]


def extract_theme(source: str, overlay: str, *, linux: bool) -> str:
    prefix_start = unique_index(source, "enum PlayerTheme:")
    prefix_end = unique_index(source, PALETTE_END)
    prefix = source[prefix_start:prefix_end]
    if linux:
        # All NSColor-only conveniences are irrelevant to colors(). Keep the
        # surrounding enum and every executed declaration byte-for-byte.
        appkit_start = unique_index(prefix, "    var appKitPrimaryColor: NSColor {")
        appkit_end = unique_index(prefix, "\n}\n\nenum PlayerThemeSurfaceStyle")
        if appkit_end <= appkit_start:
            raise ValueError("AppKit accessor boundaries are out of order")
        prefix = prefix[:appkit_start] + prefix[appkit_end:]
    tail_start = unique_index(source, "struct PlayerTextSamplingGeometry:")
    tail_end = unique_index(source, "\n@MainActor\n@Observable\nfinal class PlayerThemeStore")
    tail = source[tail_start:tail_end]
    role_start = unique_index(overlay, "enum PlayerOverlaySurfaceRole:")
    role_end = unique_index(overlay, "\n\nenum PlayerGlassGroupID:")
    role = overlay[role_start:role_end]
    imports = "import Foundation\nimport Observation\nimport IlliquidCore\nimport IlliquidPlayer\n"
    if not linux:
        imports += "import AppKit\nimport SwiftUI\n"
    return imports + "\n" + role + "\n\n" + prefix + "\n\n" + tail + "\n"


def test_imports(source: str, *, linux: bool) -> str:
    if not linux:
        return source
    # Numeric tests do not exercise framework rendering. Do not rewrite any
    # assertion or implementation; only unavailable import lines are omitted.
    return "".join(line for line in source.splitlines(keepends=True)
                   if line.strip() not in {"import SwiftUI", "import AppKit"})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--cpu", type=int, help="pin timed Linux child processes to an allowed CPU")
    parser.add_argument("--cases", default="all", help="all, or comma-separated driver case names")
    parser.add_argument("--kernels", default=",".join(KERNELS))
    parser.add_argument("--rounds", type=int, default=6, help="positive even number of fresh-process pairs")
    parser.add_argument("--target-ms", type=float, default=100, help="baseline calibration target per operation batch")
    parser.add_argument("--receipts-only", action="store_true")
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    kernels = args.kernels.split(",")
    if args.rounds <= 0 or args.rounds % 2 or not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("rounds must be positive and even; target-ms must be finite and positive")
    if any(kernel not in KERNELS for kernel in kernels) or len(set(kernels)) != len(kernels):
        parser.error("kernels must be distinct values from " + ",".join(KERNELS))
    if args.tests_only and args.receipts_only:
        parser.error("choose either --tests-only or --receipts-only")
    if args.cpu is not None and (not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0)):
        parser.error("--cpu requires a CPU in the current Linux affinity mask")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("output must be empty; choose a fresh result directory")
    sources = output / "sources"
    sources.mkdir()
    logs = output / "logs"
    logs.mkdir()
    baseline_metadata = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline_path = HERE / "baseline/PlayerTheme.swift"
    if digest(baseline_path) != baseline_metadata["sha256"]:
        raise RuntimeError("Frozen PlayerTheme baseline does not match its manifest")
    baseline = baseline_path.read_text()
    candidate = (ROOT / THEME).read_text()
    if unchanged_theme_support(baseline) != unchanged_theme_support(candidate):
        raise RuntimeError("PlayerTheme differs outside PlayerTextPalette; requalify the baseline explicitly")

    commands: list[dict] = []
    linux = platform.system() == "Linux"
    with tempfile.TemporaryDirectory(prefix="illiquid-palette-reuse-") as temporary:
        build = Path(temporary)
        env = dict(os.environ)
        env["CLANG_MODULE_CACHE_PATH"] = str(build / "clang-module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(build / "swift-module-cache")
        # Match hash-table collision layouts across the two fresh processes.
        # This is a benchmark-only setting, as in Swift's benchmark driver;
        # production keeps the runtime's normal randomized hashing.
        env["SWIFT_DETERMINISTIC_HASHING"] = "1"

        def run(command: list[str], *, stdout: Path | None = None, cpu: int | None = None) -> str:
            command_index = len(commands)
            stdout_path = stdout or logs / f"{command_index:04d}-stdout.txt"
            stderr_path = logs / f"{command_index:04d}-stderr.txt"
            started = time.time()
            wall = time.monotonic()
            before_exec = None if cpu is None else lambda: os.sched_setaffinity(0, {cpu})
            with stdout_path.open("w") as out, stderr_path.open("w") as err:
                result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                        stdout=out, stderr=err, preexec_fn=before_exec)
            commands.append({"argv": command, "started_unix_seconds": started,
                             "elapsed_seconds": time.monotonic() - wall, "returncode": result.returncode,
                             "stdout": str(stdout_path.relative_to(output)),
                             "stderr": str(stderr_path.relative_to(output)), "cpu_affinity": cpu})
            write_json(output / "commands.json", commands)
            if result.returncode:
                raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{stderr_path.read_text()}\n{stdout_path.read_text()}")
            return stdout_path.read_text()

        # The only compared source difference is the palette declaration.
        # Every common implementation must still match the pinned baseline.
        support_metadata = {}
        for name, path in SUPPORT.items():
            original = run(["git", "show", f"{baseline_metadata['commit']}:{path.as_posix()}"])
            current = (ROOT / path).read_text()
            if original != current:
                raise RuntimeError(f"Common support changed since baseline: {path}")
            shutil.copyfile(ROOT / path, sources / name)
            support_metadata[name] = {"original": path.as_posix(), "sha256": digest(sources / name),
                                      "matches_baseline": True}
        shutil.copyfile(baseline_path, sources / "baseline-PlayerTheme.swift")
        shutil.copyfile(ROOT / THEME, sources / "candidate-PlayerTheme.swift")
        shutil.copyfile(HERE / "LinuxColor.swift", sources / "LinuxColor.swift")
        shutil.copyfile(HERE / "run.py", sources / "run.py")
        if (HERE / "Driver.swift").is_file():
            shutil.copyfile(HERE / "Driver.swift", sources / "Driver.swift")
        if args.tests_only:
            shutil.copyfile(ROOT / TEST, sources / TEST.name)
        overlay = (sources / "PlayerOverlayMaterial.swift").read_text()
        for label, theme_source in (("baseline", baseline), ("candidate", candidate)):
            (sources / f"{label}-PlayerThemeSupport.swift").write_text(
                extract_theme(theme_source, overlay, linux=linux))

        swiftc = shutil.which(args.swiftc) or args.swiftc
        compiler = run([swiftc, "--version"]).strip()
        flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-enable-testing",
                 "-module-cache-path", str(build / "swift-module-cache")]
        cpu_model = platform.processor()
        if Path("/proc/cpuinfo").is_file():
            cpu_model = next((line.split(":", 1)[1].strip()
                              for line in Path("/proc/cpuinfo").read_text().splitlines()
                              if line.startswith("model name")), cpu_model)
        manifest = {
            "baseline": baseline_metadata,
            "candidate_git_head": run(["git", "rev-parse", "HEAD"]).strip(),
            "candidate_theme_sha256": digest(ROOT / THEME),
            "shared_support": support_metadata,
            "theme_support_outside_palette_unchanged": True,
            "sources": {path.name: digest(path) for path in sources.iterdir() if path.is_file()},
            "compiler": compiler, "compiler_flags": flags,
            "environment": {"platform": platform.platform(), "machine": platform.machine(),
                            "python": platform.python_version(), "logical_cpu_count": os.cpu_count(),
                            "cpu_model": cpu_model,
                            "allowed_cpus": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
                            "timed_cpu_affinity": args.cpu,
                            "swift_deterministic_hashing": env["SWIFT_DETERMINISTIC_HASHING"],
                            "thermal_or_frequency_controlled": False},
            "clocks": {"wall": "driver monotonic elapsed nanoseconds",
                       "cpu": "driver process CPU elapsed nanoseconds",
                       "orchestration": "Python time.monotonic"},
            "color_implementation": "numeric Linux Color shim" if linux else "native SwiftUI.Color",
            "scope": "Actual palette colors(), region extraction, caches, legibility and numeric output consumption. Includes revision publication in the revision workload and identical checksum/color resolution overhead. Excludes view rendering, decoding, and sampling.",
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        }
        write_json(output / "manifest.json", manifest)

        if args.tests_only:
            results = {}
            swift = str(Path(swiftc).with_name("swift"))
            for label in ("baseline", "candidate"):
                package = build / f"tests-{label}"
                package.mkdir()
                (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PaletteReuseValidation", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidPlayer", dependencies: ["IlliquidCore"]),
    .target(name: "IlliquidApp", dependencies: ["IlliquidCore", "IlliquidPlayer"]),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore", "IlliquidPlayer"])
])
''')
                files = {
                    "Sources/IlliquidCore/VideoColorSample.swift": "VideoColorSample.swift",
                    "Sources/IlliquidPlayer/PlaybackVideoColorStore.swift": "PlaybackVideoColorStore.swift",
                    "Sources/IlliquidApp/AdaptiveTextLegibility.swift": "AdaptiveTextLegibility.swift",
                    "Sources/IlliquidApp/PlayerThemeSupport.swift": f"{label}-PlayerThemeSupport.swift",
                }
                if linux:
                    files["Sources/IlliquidApp/LinuxColor.swift"] = "LinuxColor.swift"
                for destination, source_name in files.items():
                    target = package / destination
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(sources / source_name, target)
                test_target = package / "Tests/IlliquidAppTests" / TEST.name
                test_target.parent.mkdir(parents=True, exist_ok=True)
                test_target.write_text(test_imports((sources / TEST.name).read_text(), linux=linux))
                for configuration in ("debug", "release"):
                    log = output / f"tests-{label}-{configuration}.txt"
                    driver_flags = ["--use-integrated-swift-driver"] if linux else []
                    test_output = run([swift, "test", "--package-path", str(package),
                         "--scratch-path", str(package / ".build"), "--cache-path", str(package / "cache"),
                         "--config-path", str(package / "config"), "--security-path", str(package / "security"),
                         "--manifest-cache", "local", "--jobs", "1", *driver_flags,
                         "-c", configuration, "-Xswiftc", "-swift-version", "-Xswiftc", "6",
                         "-Xswiftc", "-warnings-as-errors"], stdout=log)
                    # An XCTest wrapper may exit zero after finding no tests.
                    # Require the Swift Testing execution receipt as well.
                    combined_output = test_output + (output / commands[-1]["stderr"]).read_text()
                    matches = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", combined_output)
                    executed = int(matches[-1]) if matches else 0
                    if executed < 6:
                        raise RuntimeError(f"Expected at least 6 executed Swift Testing cases for {label}/{configuration}, found {executed}")
                    results[f"{label}-{configuration}"] = {"passed": True, "executed_tests": executed,
                                                            "minimum_expected_tests": 6, "output": log.name}
                    write_json(output / "tests.json", results)
                    print(f"Actual-source tests passed: {label} {configuration}", flush=True)
            return

        if not (sources / "Driver.swift").is_file():
            raise RuntimeError("Driver.swift is required for benchmark and parity runs")
        suffix = ".so" if linux else ".dylib"
        common_link = ["-I", str(build), "-L", str(build), "-Xlinker", "-rpath", "-Xlinker", str(build)]
        run([swiftc, *flags, "-parse-as-library", "-emit-module", "-emit-library", "-module-name", "IlliquidCore",
             "-emit-module-path", str(build / "IlliquidCore.swiftmodule"), str(sources / "VideoColorSample.swift"),
             "-o", str(build / f"libIlliquidCore{suffix}")])
        run([swiftc, *flags, *common_link, "-lIlliquidCore", "-parse-as-library", "-emit-module", "-emit-library",
             "-module-name", "IlliquidPlayer", "-emit-module-path", str(build / "IlliquidPlayer.swiftmodule"),
             str(sources / "PlaybackVideoColorStore.swift"), "-o", str(build / f"libIlliquidPlayer{suffix}")])
        executables = {}
        for label in ("baseline", "candidate"):
            executable = build / label
            color_source = [str(sources / "LinuxColor.swift")] if linux else []
            run([swiftc, *flags, *common_link, "-lIlliquidCore", "-lIlliquidPlayer",
                 str(sources / f"{label}-PlayerThemeSupport.swift"), str(sources / "AdaptiveTextLegibility.swift"),
                 *color_source, str(sources / "Driver.swift"), "-o", str(executable)])
            executables[label] = executable
        manifest["binary_sha256"] = {label: digest(path) for label, path in executables.items()}
        for module in ("IlliquidCore", "IlliquidPlayer"):
            manifest["binary_sha256"][module] = digest(build / f"lib{module}{suffix}")
        write_json(output / "manifest.json", manifest)

        case_inventory = json.loads(run([str(executables["baseline"]), "cases"]))
        if not isinstance(case_inventory, list):
            raise RuntimeError("Driver cases must be a JSON array")
        cases = [entry.get("name") if isinstance(entry, dict) else entry for entry in case_inventory]
        if not all(isinstance(case, str) for case in cases) or len(set(cases)) != len(cases):
            raise RuntimeError("Driver cases must have distinct string names")
        if json.loads(run([str(executables["candidate"]), "cases"])) != case_inventory:
            raise RuntimeError("Baseline and candidate driver case inventories differ")
        write_json(output / "cases.json", case_inventory)

        receipt_files = {}
        for label in ("baseline", "candidate"):
            path = output / f"{label}-receipts.jsonl"
            run([str(executables[label]), "verify"], stdout=path)
            receipt_files[label] = path
        receipt_data = {label: path.read_bytes() for label, path in receipt_files.items()}
        if not receipt_data["baseline"].strip():
            raise RuntimeError("Driver produced no verification receipts")
        for data in receipt_data.values():
            for line in data.splitlines():
                json.loads(line)
        differential = {"exact_match": receipt_data["baseline"] == receipt_data["candidate"],
                        "receipt_count": len(receipt_data["baseline"].splitlines()),
                        "sha256": {label: digest(path) for label, path in receipt_files.items()}}
        if not differential["exact_match"]:
            baseline_lines = receipt_data["baseline"].splitlines()
            candidate_lines = receipt_data["candidate"].splitlines()
            differential["candidate_receipt_count"] = len(candidate_lines)
            for index, (left, right) in enumerate(zip(baseline_lines, candidate_lines)):
                if left != right:
                    differential["first_mismatch"] = {"line": index + 1, "baseline": json.loads(left),
                                                       "candidate": json.loads(right)}
                    break
        write_json(output / "differential.json", differential)
        print(f"Exact palette receipts: {differential['receipt_count']}, match={differential['exact_match']}", flush=True)
        if not differential["exact_match"]:
            raise RuntimeError("Exact baseline/candidate palette receipts differ")
        if args.receipts_only:
            return

        selected = cases if args.cases == "all" else args.cases.split(",")
        if not selected or len(set(selected)) != len(selected) or not set(selected) <= set(cases):
            parser.error("cases must be distinct names from the driver inventory")
        workloads = [(case, kernel) for case in selected for kernel in kernels]
        raw = output / "timings"
        raw.mkdir()

        def time_process(label: str, case: str, kernel: str, iterations: int, filename: str) -> dict:
            warmup = max(1, min(64, iterations // 10))
            result = json.loads(run([str(executables[label]), "time", case, kernel, str(iterations), str(warmup)],
                                    stdout=raw / filename, cpu=args.cpu))
            expected_fields = {"case": case, "kernel": kernel, "iterations": iterations,
                               "warmup_iterations": warmup}
            for field, expected in expected_fields.items():
                if result.get(field) != expected:
                    raise RuntimeError(f"Timing workload field {field} differs: expected {expected!r}, got {result.get(field)!r}")
            for field in ("elapsed_ns", "cpu_elapsed_ns", "ns_per_operation", "cpu_ns_per_operation"):
                if field not in result or not math.isfinite(result[field]) or result[field] <= 0:
                    raise RuntimeError(f"Invalid timing field {field}: {result}")
            if "checksum" not in result or "warmup_checksum" not in result:
                raise RuntimeError("Driver must consume and checksum measured and warmup outputs")
            for field in ("revision", "generation"):
                if type(result.get(field)) is not int or result[field] < 0:
                    raise RuntimeError(f"Missing or invalid cache counter {field}: {result}")
            return result

        iterations = {}
        calibration = []
        for case, kernel in workloads:
            record = time_process("baseline", case, kernel, 64, f"calibrate-{case}-{kernel}.json")
            count = max(1, min(10_000_000, math.ceil(args.target_ms * 1_000_000 / record["ns_per_operation"])))
            iterations[(case, kernel)] = count
            calibration.append({"case": case, "kernel": kernel, "iterations": count, "measurement": record})
        write_json(output / "calibration.json", calibration)

        measurements = []
        pairs = []
        for round_index in range(args.rounds):
            order = ("baseline", "candidate") if round_index % 2 == 0 else ("candidate", "baseline")
            offset = round_index % len(workloads)
            for case, kernel in workloads[offset:] + workloads[:offset]:
                pair = {}
                for label in order:
                    record = time_process(label, case, kernel, iterations[(case, kernel)],
                                          f"r{round_index + 1:02d}-{case}-{kernel}-{label}.json")
                    record.update({"variant": label, "case": case, "kernel": kernel,
                                   "round": round_index + 1, "iterations": iterations[(case, kernel)],
                                   "order": list(order)})
                    measurements.append(record)
                    pair[label] = record
                    write_json(output / "measurements.json", measurements)
                for invariant in ("checksum", "warmup_checksum", "revision", "generation"):
                    if pair["baseline"][invariant] != pair["candidate"][invariant]:
                        raise RuntimeError(f"Timing {invariant} differs for {case}/{kernel}/round {round_index + 1}")
                pairs.append({"case": case, "kernel": kernel, "round": round_index + 1,
                              "wall_reduction_percent": 100 * (1 - pair["candidate"]["ns_per_operation"] / pair["baseline"]["ns_per_operation"]),
                              "cpu_reduction_percent": 100 * (1 - pair["candidate"]["cpu_ns_per_operation"] / pair["baseline"]["cpu_ns_per_operation"])})
                write_json(output / "pairs.json", pairs)
            print(f"Finished balanced round {round_index + 1}/{args.rounds}", flush=True)

        summary = []
        for case, kernel in workloads:
            selected_pairs = [pair for pair in pairs if pair["case"] == case and pair["kernel"] == kernel]
            row = {"case": case, "kernel": kernel, "pairs": len(selected_pairs),
                   "iterations_per_process": iterations[(case, kernel)],
                   "median_paired_wall_reduction_percent": statistics.median(pair["wall_reduction_percent"] for pair in selected_pairs),
                   "median_paired_cpu_reduction_percent": statistics.median(pair["cpu_reduction_percent"] for pair in selected_pairs),
                   "candidate_faster_wall_pairs": sum(pair["wall_reduction_percent"] > 0 for pair in selected_pairs),
                   "candidate_faster_cpu_pairs": sum(pair["cpu_reduction_percent"] > 0 for pair in selected_pairs)}
            for label in ("baseline", "candidate"):
                values = [record for record in measurements
                          if record["case"] == case and record["kernel"] == kernel and record["variant"] == label]
                row[f"{label}_median_ns_per_operation"] = statistics.median(record["ns_per_operation"] for record in values)
                row[f"{label}_median_cpu_ns_per_operation"] = statistics.median(record["cpu_ns_per_operation"] for record in values)
            summary.append(row)
        write_json(output / "summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
