#!/usr/bin/env python3
"""Build actual Swift sources, compare exact decisions, and time balanced AB/BA runs.

Example (use a toolchain wrapper by setting SWIFTC to its actual swiftc path):
  python3 Benchmarks/AdaptiveTextLegibility/run.py --output /tmp/legibility-results

The standalone build has no package dependencies. Output includes source copies,
hashes, compiler commands, exact differential receipts, and raw timing records.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
APP_SOURCE = Path("Sources/IlliquidApp/UI/AdaptiveTextLegibility.swift")
THEME_SOURCE = Path("Sources/IlliquidApp/UI/PlayerTheme.swift")
CORE_SOURCE = Path("Sources/IlliquidCore/Player/VideoColorSample.swift")
KERNELS = {"style_miss", "score", "opacity", "init_score"}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def extract_support(source: str) -> str:
    palette_start = source.index("enum PlayerRainbowPalette:")
    palette_end = source.index("\nenum PlayerTextSamplingCoordinateSpace", palette_start)
    color_start = source.index("struct AdaptiveRainbowTextColor:")
    color_end = source.index("\n@MainActor\n@Observable\nfinal class PlayerThemeStore", color_start)
    return "import Foundation\nimport IlliquidCore\n\n" + source[palette_start:palette_end] + "\n\n" + source[color_start:color_end] + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--cpu", type=int, help="pin timed processes to this allowed Linux CPU")
    parser.add_argument("--rounds", type=int, default=6, help="positive even count; fresh processes alternate AB/BA")
    parser.add_argument("--target-ms", type=float, default=150, help="baseline-calibrated duration for each timed process")
    parser.add_argument("--cases", default="all", help="comma-separated names; use --list-cases to inspect")
    parser.add_argument("--kernels", default="style_miss", help="style_miss,score,opacity,init_score")
    parser.add_argument("--receipt-samples", type=int, default=320)
    parser.add_argument("--receipts-only", action="store_true")
    parser.add_argument("--tests-only", action="store_true", help="run the exact new app tests in an isolated package, debug and release")
    parser.add_argument("--list-cases", action="store_true")
    args = parser.parse_args()
    kernels = args.kernels.split(",")
    if args.rounds <= 0 or args.rounds % 2 or args.target_ms <= 0 or args.receipt_samples < 0:
        parser.error("rounds must be positive and even; target-ms positive; receipt-samples nonnegative")
    if any(kernel not in KERNELS for kernel in kernels):
        parser.error("unknown kernel")
    if args.cpu is not None and (not hasattr(os, "sched_getaffinity") or args.cpu not in os.sched_getaffinity(0)):
        parser.error("--cpu requires an allowed CPU and Linux affinity support")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / "manifest.json").exists():
        parser.error("output already contains a run; choose a new directory")
    sources = output / "sources"
    sources.mkdir()
    baseline_metadata = json.loads((HERE / "baseline/manifest.json").read_text())
    if digest(HERE / "baseline/AdaptiveTextLegibility.swift") != baseline_metadata["sha256"]:
        raise RuntimeError("frozen baseline does not match its manifest")
    source_inputs = {
        "baseline.swift": HERE / "baseline/AdaptiveTextLegibility.swift",
        "candidate.swift": ROOT / APP_SOURCE,
        "VideoColorSample.swift": ROOT / CORE_SOURCE,
        "PlayerTheme.swift": ROOT / THEME_SOURCE,
        "Driver.swift": HERE / "Driver.swift",
        "run.py": HERE / "run.py",
    }
    if args.tests_only:
        source_inputs["AdaptiveTextLegibilityPerformanceTests.swift"] = (
            ROOT / "Tests/IlliquidAppTests/AdaptiveTextLegibilityPerformanceTests.swift")
    for name, source in source_inputs.items():
        shutil.copyfile(source, sources / name)
    (sources / "PlayerThemeSupport.swift").write_text(extract_support((sources / "PlayerTheme.swift").read_text()))
    commands: list[dict] = []

    with tempfile.TemporaryDirectory(prefix="illiquid-legibility-") as temporary:
        build = Path(temporary)
        env = dict(os.environ)
        env["CLANG_MODULE_CACHE_PATH"] = str(build / "clang-module-cache")
        env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(build / "swift-module-cache")

        def run(command: list[str], stdout: Path | None = None, cpu: int | None = None) -> str:
            start = time.monotonic()
            before_exec = None if cpu is None else lambda: os.sched_setaffinity(0, {cpu})
            if stdout is None:
                result = subprocess.run(command, env=env, cwd=ROOT, text=True, capture_output=True, preexec_fn=before_exec)
                text = result.stdout
            else:
                with stdout.open("w") as stream:
                    result = subprocess.run(command, env=env, cwd=ROOT, text=True, stdout=stream, stderr=subprocess.PIPE, preexec_fn=before_exec)
                text = ""
            commands.append({"argv": command, "elapsed_seconds": time.monotonic() - start,
                             "returncode": result.returncode, "stderr": result.stderr, "cpu_affinity": cpu})
            write_json(output / "commands.json", commands)
            if result.returncode:
                raise RuntimeError(f"Command failed: {command}\n{result.stderr}\n{text}")
            return text

        swiftc = shutil.which(args.swiftc) or args.swiftc
        version = run([swiftc, "--version"]).strip()
        flags = ["-O", "-whole-module-optimization", "-module-cache-path", str(build / "swift-module-cache")]
        cpu_model = platform.processor()
        if Path("/proc/cpuinfo").exists():
            cpu_model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                              if line.startswith("model name")), cpu_model)
        manifest = {
            "baseline": baseline_metadata,
            "sources": {name: {"original": str(path.relative_to(ROOT)), "sha256": digest(sources / name)}
                        for name, path in source_inputs.items()},
            "support_sha256": digest(sources / "PlayerThemeSupport.swift"),
            "runner_sha256": digest(HERE / "run.py"),
            "compiler": version, "flags": flags,
            "environment": {"platform": platform.platform(), "machine": platform.machine(),
                            "python": platform.python_version(), "logical_cpu_count": os.cpu_count(),
                            "cpu_model": cpu_model,
                            "allowed_cpus": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None},
            "git_head": run(["git", "rev-parse", "HEAD"]).strip(),
            "scope": "Numeric style cache miss: context init+resolve, second context init+two readableOpacity calls (.96/.90). Excludes UI, sample generation/region extraction, cache lookup, video decode.",
            "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        }
        write_json(output / "manifest.json", manifest)
        if args.tests_only:
            package = build / "test-package"
            package.mkdir()
            (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "IlliquidLegibilityValidation", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .target(name: "IlliquidApp", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"])
])
''')
            package_files = {
                "Sources/IlliquidCore/VideoColorSample.swift": "VideoColorSample.swift",
                "Sources/IlliquidApp/PlayerThemeSupport.swift": "PlayerThemeSupport.swift",
                "Sources/IlliquidApp/AdaptiveTextLegibility.swift": "candidate.swift",
                "Tests/IlliquidAppTests/AdaptiveTextLegibilityPerformanceTests.swift": "AdaptiveTextLegibilityPerformanceTests.swift",
            }
            for target, source in package_files.items():
                path = package / target
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(sources / source, path)
            swift = str(Path(swiftc).with_name("swift"))
            # SwiftPM's standalone Linux driver probes unrelated /proc entries
            # on this sandbox. Its integrated driver avoids that restricted IO.
            driver_flags = ["--use-integrated-swift-driver"] if platform.system() == "Linux" else []
            results = {}
            for configuration in ("debug", "release"):
                log = output / f"tests-{configuration}.txt"
                run([swift, "test", "--package-path", str(package), "--cache-path", str(build / "package-cache"),
                     "--manifest-cache", "local", "--jobs", "2", *driver_flags,
                     "-c", configuration, "-Xswiftc", "-warnings-as-errors"], stdout=log)
                results[configuration] = {"passed": True, "output": log.name}
                print(f"Exact-source tests passed: {configuration}", flush=True)
            write_json(output / "tests.json", results)
            return

        library_suffix = ".dylib" if platform.system() == "Darwin" else ".so"
        run([swiftc, *flags, "-parse-as-library", "-emit-module", "-emit-library", "-module-name", "IlliquidCore",
             "-emit-module-path", str(build / "IlliquidCore.swiftmodule"), str(sources / "VideoColorSample.swift"),
             "-o", str(build / ("libIlliquidCore" + library_suffix))])
        executables = {}
        for label in ("baseline", "candidate"):
            executable = build / label
            run([swiftc, *flags, "-I", str(build), "-L", str(build), "-lIlliquidCore",
                 "-Xlinker", "-rpath", "-Xlinker", str(build),
                 str(sources / "PlayerThemeSupport.swift"), str(sources / f"{label}.swift"),
                 str(sources / "Driver.swift"), "-o", str(executable)])
            executables[label] = executable
        manifest["binary_sha256"] = {label: digest(path) for label, path in executables.items()}
        manifest["binary_sha256"]["IlliquidCore"] = digest(build / ("libIlliquidCore" + library_suffix))
        write_json(output / "manifest.json", manifest)
        cases = json.loads(run([str(executables["baseline"]), "cases"]))
        write_json(output / "cases.json", cases)
        if args.list_cases:
            print(json.dumps(cases, indent=2))
            return

        if args.receipt_samples:
            receipt_files = {}
            for label in ("baseline", "candidate"):
                receipt_files[label] = output / f"{label}-receipts.jsonl"
                run([str(executables[label]), "receipts", str(args.receipt_samples)], stdout=receipt_files[label])
            a = receipt_files["baseline"].read_bytes()
            b = receipt_files["candidate"].read_bytes()
            differential = {"samples": args.receipt_samples, "decisions": a.count(b"\n"),
                            "exact_match": a == b,
                            "sha256": {label: digest(path) for label, path in receipt_files.items()}}
            if a != b:
                for index, (left, right) in enumerate(zip(a.splitlines(), b.splitlines())):
                    if left != right:
                        differential["first_mismatch"] = {"line": index + 1,
                                                          "baseline": json.loads(left), "candidate": json.loads(right)}
                        break
            write_json(output / "differential.json", differential)
            print(f"Exact decision receipts: {differential['decisions']} decisions, match={a == b}", flush=True)
            if a != b:
                raise RuntimeError("baseline and candidate exact decision receipts differ")
        if args.receipts_only:
            return

        available = {case["name"] for case in cases}
        selected = [case["name"] for case in cases] if args.cases == "all" else args.cases.split(",")
        if not set(selected) <= available:
            parser.error("unknown case: " + ", ".join(sorted(set(selected) - available)))
        workloads = [(case, kernel) for case in selected for kernel in kernels]

        def time_process(label: str, case: str, kernel: str, iterations: int) -> dict:
            warmup = max(8, min(iterations, max(16, iterations // 10)))
            return json.loads(run([str(executables[label]), "time", case, kernel, str(iterations), str(warmup)], cpu=args.cpu))

        iterations = {}
        for case, kernel in workloads:
            calibration = time_process("baseline", case, kernel, 16)
            iterations[(case, kernel)] = max(8, min(10_000_000, math.ceil(args.target_ms * 1_000_000 / calibration["ns_per_operation"])))
        measurements = []
        for round_index in range(args.rounds):
            order = ("baseline", "candidate") if round_index % 2 == 0 else ("candidate", "baseline")
            offset = round_index % len(workloads)
            for case, kernel in workloads[offset:] + workloads[:offset]:
                paired = []
                for position, label in enumerate(order):
                    measurement = time_process(label, case, kernel, iterations[(case, kernel)])
                    measurement.update({"round": round_index, "order": "/".join(order),
                                        "position": position, "variant": label})
                    measurements.append(measurement)
                    paired.append(measurement)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(measurement, sort_keys=True) + "\n")
                if paired[0]["checksum"] != paired[1]["checksum"]:
                    raise RuntimeError(f"timed output checksum mismatch: {case}/{kernel}")
            print(f"Completed balanced round {round_index + 1}/{args.rounds}", flush=True)

        summary = []
        for case, kernel in workloads:
            matching = [item for item in measurements if item["case"] == case and item["kernel"] == kernel]
            baseline = [item["ns_per_operation"] for item in matching if item["variant"] == "baseline"]
            candidate = [item["ns_per_operation"] for item in matching if item["variant"] == "candidate"]
            baseline_median, candidate_median = statistics.median(baseline), statistics.median(candidate)
            baseline_cpu = [item["cpu_ns_per_operation"] for item in matching if item["variant"] == "baseline"]
            candidate_cpu = [item["cpu_ns_per_operation"] for item in matching if item["variant"] == "candidate"]
            baseline_cpu_median, candidate_cpu_median = statistics.median(baseline_cpu), statistics.median(candidate_cpu)
            ratios = [next(item["ns_per_operation"] for item in matching if item["round"] == index and item["variant"] == "candidate")
                      / next(item["ns_per_operation"] for item in matching if item["round"] == index and item["variant"] == "baseline")
                      for index in range(args.rounds)]
            summary.append({"case": case, "kernel": kernel, "iterations": iterations[(case, kernel)],
                            "baseline_median_ns": baseline_median, "candidate_median_ns": candidate_median,
                            "median_change_percent": (candidate_median / baseline_median - 1) * 100,
                            "baseline_median_cpu_ns": baseline_cpu_median,
                            "candidate_median_cpu_ns": candidate_cpu_median,
                            "cpu_median_change_percent": (candidate_cpu_median / baseline_cpu_median - 1) * 100,
                            "paired_ratio_median": statistics.median(ratios),
                            "paired_ratio_min": min(ratios), "paired_ratio_max": max(ratios),
                            "baseline_samples_ns": baseline, "candidate_samples_ns": candidate})
        write_json(output / "summary.json", summary)
        for item in summary:
            print(f"{item['case']:32} {item['kernel']:10} "
                  f"{item['baseline_median_ns']/1000:9.2f} -> {item['candidate_median_ns']/1000:9.2f} us "
                  f"({item['median_change_percent']:+.1f}% wall, {item['cpu_median_change_percent']:+.1f}% CPU)")


if __name__ == "__main__":
    main()
