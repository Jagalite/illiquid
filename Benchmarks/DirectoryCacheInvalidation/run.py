#!/usr/bin/env python3
"""Benchmark actual directory-cache invalidation with a frozen production baseline.

Python 3.10+ and Swift 6.1+. Builds are isolated, serial, and temporary.
Results, source receipts, subprocess logs, and raw observations are retained.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BENCH = HERE.relative_to(ROOT).as_posix()
BASELINE_REF = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "c41afc25e48a5983aa85304cce8651af5ff19fe2"
STATE = "Sources/IlliquidApp/UI/SourceTreeDirectoryState.swift"
PLANNER = "Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift"
SIDEBAR = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
TEST = "Tests/IlliquidAppTests/SourceTreeDirectoryStateTests.swift"
HELPER = "Scripts/test-source-browser-search.py"
CORE = [
    "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift",
    "Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift",
]
FLAGS = ["-O", "-whole-module-optimization", "-swift-version", "6",
         "-enable-testing", "-warnings-as-errors", "-parse-as-library"]
VARIANTS = ("baseline", "candidate")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compact(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n",
                    encoding="utf-8")


def stage(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def paired_summary(pairs: list[dict], metric: str) -> dict:
    baseline = [p["baseline"][metric] / p["baseline"]["iterations"] for p in pairs]
    candidate = [p["candidate"][metric] / p["candidate"]["iterations"] for p in pairs]
    logs = [math.log(b / c) for b, c in zip(baseline, candidate)]
    rng = random.Random(0xD1CE)
    bootstrap = sorted(math.exp(statistics.fmean(rng.choices(logs, k=len(logs))))
                       for _ in range(4000))
    return {
        "baselineMedianNanosecondsPerCall": statistics.median(baseline),
        "candidateMedianNanosecondsPerCall": statistics.median(candidate),
        "baselineRangeNanosecondsPerCall": [min(baseline), max(baseline)],
        "candidateRangeNanosecondsPerCall": [min(candidate), max(candidate)],
        "candidateFasterPairs": sum(c < b for b, c in zip(baseline, candidate)),
        "pairedGeometricMeanSpeedup": math.exp(statistics.fmean(logs)),
        "pairedBootstrap95PercentCI": [bootstrap[99], bootstrap[3899]],
        "bootstrapResamples": len(bootstrap),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New output directory")
    parser.add_argument("--pairs", type=int, default=8, help="Even number, at least 2")
    parser.add_argument("--target-ms", type=float, default=80.0)
    parser.add_argument("--mode", choices=["tests", "benchmark", "all"], default="all")
    parser.add_argument("--log-evidence", action="store_true",
                        help="Print compact machine-readable evidence to CI logs")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least 2")
    if not math.isfinite(args.target_ms) or args.target_ms <= 0:
        parser.error("--target-ms must be finite and positive")
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must be a new directory")
    swift, swiftc = shutil.which("swift"), shutil.which("swiftc")
    if not swift or not swiftc:
        parser.error("Swift 6.1+ and swiftc must be installed")
    if platform.system() not in {"Darwin", "Linux"}:
        parser.error("Supported platforms are macOS and Linux")
    output.mkdir(parents=True)
    (output / "logs").mkdir()
    commands, observations, calibration, summaries = [], [], [], []
    sources = {"baseline_commit": BASELINE_REF, "baseline_git_blob": BASELINE_BLOB,
               "inputs": {}, "declarations": [], "benchmark_variants": {}}
    report = {"status": "running", "mode": args.mode, "tests": [],
              "pairs": args.pairs, "target_ms": args.target_ms,
              "iteration_cap": 100000, "performance_threshold": None}

    def read_source(path: str) -> bytes:
        data = (ROOT / path).read_bytes()
        sources["inputs"][path] = {"sha256": digest(data), "bytes": len(data)}
        return data

    def run(argv, label, *, timeout=120, env=None, check=True):
        argv = [str(item) for item in argv]
        stem = f"{len(commands):04d}-{re.sub(r'[^A-Za-z0-9_.-]', '_', label)}"
        entry = {"argv": argv, "cwd": str(ROOT), "timeout_seconds": timeout,
                 "environment_overrides": env or {}, "log_prefix": f"logs/{stem}"}
        commands.append(entry)
        save(output / "commands.json", commands)
        started = time.monotonic()
        try:
            result = subprocess.run(
                argv, cwd=ROOT, env={**os.environ, **(env or {})},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired as error:
            def text(value):
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
            result = subprocess.CompletedProcess(argv, 124, text(error.output), text(error.stderr))
            entry["timed_out"] = True
        entry.update(exit_code=result.returncode, elapsed_seconds=time.monotonic() - started)
        (output / "logs" / f"{stem}.stdout.log").write_text(result.stdout, encoding="utf-8")
        (output / "logs" / f"{stem}.stderr.log").write_text(result.stderr, encoding="utf-8")
        save(output / "commands.json", commands)
        if check and result.returncode:
            print(result.stdout[-12000:] + result.stderr[-12000:], file=sys.stderr, flush=True)
            raise RuntimeError(f"{label} failed ({result.returncode}); see {entry['log_prefix']}.*.log")
        return result

    try:
        kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
        if not kyoto.exists():
            print("Kyoto is unavailable; using serial isolated component builds directly.", flush=True)
        print("Scope: cached-tree invalidation; no full app, native playback, or live FSEvents.",
              flush=True)
        report["metadata"] = {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "swift": run([swift, "--version"], "swift-version").stdout.strip(),
            "swiftc": run([swiftc, "--version"], "swiftc-version").stdout.strip(),
            "git_sha": None,
            "build_flags": FLAGS,
        }
        if shutil.which("git"):
            git = run(["git", "rev-parse", "HEAD"], "git-head", check=False)
            if git.returncode == 0:
                report["metadata"]["git_sha"] = git.stdout.strip()
        if platform.system() == "Darwin":
            report["metadata"]["macos"] = run(["sw_vers"], "macos").stdout.strip()
            report["metadata"]["cpu"] = run(
                ["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").stdout.strip()
            report["metadata"]["xcode"] = run(["xcodebuild", "-version"], "xcode").stdout.strip()
        else:
            report["metadata"]["cpu"] = run(["lscpu"], "cpu", check=False).stdout.strip()
        print(report["metadata"]["swift"], flush=True)

        read_source(f"{BENCH}/run.py")
        read_source(HELPER)
        baseline = read_source(f"{BENCH}/baseline/SourceTreeDirectoryState.swift")
        blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
        if blob != BASELINE_BLOB:
            raise ValueError(f"Frozen baseline Git blob mismatch: {blob}")
        variants = {"baseline": baseline, "candidate": read_source(STATE)}
        planner = read_source(PLANNER)
        sidebar = read_source(SIDEBAR).decode("utf-8")
        fixture = read_source(f"{BENCH}/FixtureSupport.swift")
        driver = read_source(f"{BENCH}/Driver.swift")
        core_sources = {Path(path).name: read_source(path) for path in CORE}
        spec = importlib.util.spec_from_file_location("browser_support", ROOT / HELPER)
        if spec is None or spec.loader is None:
            raise RuntimeError("Cannot import the portable test-package helper")
        support = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(support)
        declarations = {}
        for name in ["SourceTreeEntry", "SourceDirectoryListing", "SourceTreeIdentity"]:
            text, first, last = support.declaration(sidebar, name)
            declarations[name] = text
            sources["declarations"].append({
                "path": SIDEBAR, "name": name, "first_line": first,
                "last_line": last, "slice_sha256": digest(text.encode("utf-8"))})
        portable = ("import Foundation\nimport IlliquidCore\n\n"
                    + "\n\n".join(declarations.values()) + "\n").encode("utf-8")
        sources["benchmark_support_sha256"] = digest(portable)

        with tempfile.TemporaryDirectory(prefix="illiquid-cache-invalidation-") as temporary:
            work = Path(temporary)
            if args.mode in {"tests", "all"}:
                test_source = read_source(TEST)
                listing = ("import Foundation\n\n"
                           + declarations["SourceDirectoryListing"] + "\n").encode("utf-8")
                for variant in VARIANTS:
                    package = support.prepare_package(work / f"tests-{variant}" / "package")
                    receipt = json.loads((package / "source-receipt.json").read_text())
                    overlays = {
                        "Sources/IlliquidApp/SourceTreeDirectoryState.swift": variants[variant],
                        "Sources/IlliquidApp/SourceFilesystemInvalidation.swift": planner,
                        "Sources/IlliquidApp/SourceDirectoryListing.swift": listing,
                        "Tests/IlliquidAppTests/SourceTreeDirectoryStateTests.swift": test_source,
                    }
                    for path, data in overlays.items():
                        stage(package / path, data)
                    receipt["directory_cache_overlay"] = {
                        "variant": variant, "benchmark_adapter_included": False,
                        "compiled_sha256": {path: digest(data) for path, data in overlays.items()}}
                    save(output / f"tests-{variant}-source-receipt.json", receipt)
                    for configuration in ["debug", "release"]:
                        build = work / f"tests-{variant}" / configuration
                        env = {"CLANG_MODULE_CACHE_PATH": str(build / "clang-cache"),
                               "SWIFTPM_MODULECACHE_OVERRIDE": str(build / "swift-cache")}
                        result = run([
                            swift, "test", "--package-path", package,
                            "--scratch-path", build / "build",
                            "--cache-path", build / "package-cache",
                            "--config-path", build / "package-config",
                            "--security-path", build / "package-security",
                            "--configuration", configuration, "--jobs", "2", "--no-parallel",
                            "-Xswiftc", "-warnings-as-errors",
                        ], f"tests-{variant}-{configuration}", timeout=600, env=env)
                        counts = re.findall(r"Test run with (\d+) tests?\b",
                                            result.stdout + "\n" + result.stderr)
                        count = int(counts[-1]) if counts else 0
                        if count == 0:
                            raise RuntimeError(f"No completed Swift Testing tests: {variant}/{configuration}")
                        report["tests"].append({"variant": variant,
                                                "configuration": configuration, "count": count})
                        save(output / "result.json", report)
                        print(f"TESTS {variant} {configuration} {count} passed", flush=True)

            if args.mode in {"benchmark", "all"}:
                suffix = ".dylib" if platform.system() == "Darwin" else ".so"

                def links(dependencies):
                    result = []
                    for directory, name in dependencies:
                        result += ["-I", str(directory), "-L", str(directory), f"-l{name}",
                                   "-Xlinker", "-rpath", "-Xlinker", str(directory)]
                    return result

                def build_module(name, directory, files, dependencies=()):
                    directory.mkdir(parents=True, exist_ok=True)
                    run([swiftc, *FLAGS, "-module-cache-path", directory / "module-cache",
                         "-emit-library", "-emit-module", "-module-name", name,
                         "-emit-module-path", directory / f"{name}.swiftmodule",
                         "-o", directory / f"lib{name}{suffix}", *links(dependencies), *files],
                        f"build-{directory.name}-{name}",
                        env={"CLANG_MODULE_CACHE_PATH": str(directory / "clang-cache")})

                core_dir = work / "core"
                core_files = [stage(core_dir / name, data) for name, data in core_sources.items()]
                build_module("IlliquidCore", core_dir, core_files)
                driver_path = stage(work / "Driver.swift", driver)
                executables = {}
                for variant in VARIANTS:
                    app = work / variant
                    compiled = variants[variant] + b"\n\n" + fixture
                    files = [
                        stage(app / "SourceTreeDirectoryState.swift", compiled),
                        stage(app / "SourceFilesystemInvalidation.swift", planner),
                        stage(app / "PortableSupport.swift", portable),
                    ]
                    sources["benchmark_variants"][variant] = {
                        "production_prefix_sha256": digest(variants[variant]),
                        "production_prefix_bytes": len(variants[variant]),
                        "appended_fixture_sha256": digest(b"\n\n" + fixture),
                        "compiled_state_sha256": digest(compiled),
                    }
                    build_module("IlliquidApp", app, files, [(core_dir, "IlliquidCore")])
                    executable = app / "DirectoryCacheInvalidation"
                    run([swiftc, *FLAGS, "-module-cache-path", app / "driver-module-cache",
                         *links([(app, "IlliquidApp"), (core_dir, "IlliquidCore")]),
                         driver_path, "-o", executable], f"build-{variant}-driver",
                        env={"CLANG_MODULE_CACHE_PATH": str(app / "driver-clang-cache")})
                    executables[variant] = executable

                def invoke(variant, *arguments):
                    return json.loads(run(
                        [executables[variant], *arguments],
                        variant + "-" + "-".join(map(str, arguments))).stdout)

                configs = {variant: invoke(variant, "--list") for variant in VARIANTS}
                if compact(configs["baseline"]) != compact(configs["candidate"]):
                    raise ValueError("Baseline/candidate workload lists differ")
                cases = configs["baseline"]
                if not isinstance(cases, list) or not cases:
                    raise ValueError("Driver --list must return a nonempty array")
                ids = [case["id"] for case in cases]
                if any(not isinstance(item, str) or not item for item in ids) or len(set(ids)) != len(ids):
                    raise ValueError("Workload IDs must be unique nonempty strings")
                save(output / "cases.json", cases)
                parity = {variant: invoke(variant, "--verify") for variant in VARIANTS}
                save(output / "parity.json", parity)
                if any(not isinstance(value, dict) or set(value) != set(ids) for value in parity.values()):
                    raise ValueError("Verification receipts do not cover exactly the listed workloads")
                if compact(parity["baseline"]) != compact(parity["candidate"]):
                    raise ValueError("Baseline/candidate full byte receipts differ")
                report["parity_case_count"] = len(ids)

                def measure(variant, case, iterations):
                    value = invoke(variant, case, iterations)
                    if value.get("id") != case or value.get("iterations") != iterations:
                        raise ValueError("Driver measurement identity/iteration mismatch")
                    for key in ["cpuNanoseconds", "wallNanoseconds"]:
                        if type(value.get(key)) is not int or value[key] <= 0:
                            raise ValueError(f"Invalid measured duration: {key}")
                    if "checksum" not in value:
                        raise ValueError("Missing measurement checksum")
                    return value

                for case in ids:
                    iterations, step = 1, 0
                    while True:
                        order = VARIANTS if step % 2 == 0 else VARIANTS[::-1]
                        values = {v: measure(v, case, iterations) for v in order}
                        if compact(values["baseline"]["checksum"]) != compact(values["candidate"]["checksum"]):
                            raise ValueError(f"Calibration checksum mismatch: {case}")
                        fastest = min(value["cpuNanoseconds"] for value in values.values())
                        calibration.append({"id": case, "iterations": iterations,
                                            "order": list(order), "measurements": values})
                        save(output / "calibration.json", calibration)
                        if fastest >= args.target_ms * 1_000_000 or iterations == 100000:
                            break
                        estimate = math.ceil(iterations * args.target_ms * 1_000_000 / fastest * 1.1)
                        iterations = min(100000, max(iterations + 1, min(iterations * 10, estimate)))
                        step += 1
                    pairs = []
                    for pair in range(args.pairs):
                        order = VARIANTS if pair % 2 == 0 else VARIANTS[::-1]
                        values = {}
                        for position, variant in enumerate(order):
                            values[variant] = measure(variant, case, iterations)
                            row = {"id": case, "pair": pair, "position": position,
                                   "variant": variant, "measurement": values[variant]}
                            observations.append(row)
                            with (output / "observations.jsonl").open("a", encoding="utf-8") as stream:
                                stream.write(compact(row) + "\n")
                        if compact(values["baseline"]["checksum"]) != compact(values["candidate"]["checksum"]):
                            raise ValueError(f"Measured checksum mismatch: {case}, pair {pair}")
                        pairs.append(values)
                    summary = {"id": case, "iterations": iterations, "pairs": args.pairs,
                               "calibration_target_reached": fastest >= args.target_ms * 1_000_000,
                               "cpu": paired_summary(pairs, "cpuNanoseconds"),
                               "wall": paired_summary(pairs, "wallNanoseconds")}
                    summaries.append(summary)
                    save(output / "summary.json", summaries)
                    for metric in ["cpu", "wall"]:
                        item = summary[metric]
                        low, high = item["pairedBootstrap95PercentCI"]
                        print(f"SUMMARY {case} {metric} "
                              f"baseline={item['baselineMedianNanosecondsPerCall']:.1f}ns/call "
                              f"candidate={item['candidateMedianNanosecondsPerCall']:.1f}ns/call "
                              f"speedup={item['pairedGeometricMeanSpeedup']:.3f}x "
                              f"paired95%=[{low:.3f},{high:.3f}]", flush=True)

        report.update(status="complete", benchmark_case_count=len(summaries),
                      observation_count=len(observations))
        save(output / "result.json", report)
        save(output / "source-receipt.json", sources)
        if args.log_evidence:
            manifest = {**report["metadata"], "baseline_commit": BASELINE_REF,
                        "baseline_git_blob": BASELINE_BLOB,
                        "source_hashes": sources["inputs"],
                        "declarations": sources["declarations"],
                        "benchmark_variants": sources["benchmark_variants"],
                        "benchmark_support_sha256": sources["benchmark_support_sha256"]}
            print("EVIDENCE_MANIFEST " + compact(manifest), flush=True)
            print("EVIDENCE_RESULT " + compact(report), flush=True)
            print("EVIDENCE_SUMMARY " + compact(summaries), flush=True)
            for row in calibration:
                print("EVIDENCE_CALIBRATION " + compact(row), flush=True)
            for row in observations:
                print("EVIDENCE_OBSERVATION " + compact(row), flush=True)
        print(f"RESULT complete: {len(report['tests'])} test runs; "
              f"{report.get('parity_case_count', 0)} parity cases; "
              f"{len(observations)} observations. No performance threshold applied.", flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
        report.update(status="failed", error=str(error))
        save(output / "result.json", report)
        print(f"RESULT failed: {error}", file=sys.stderr, flush=True)
        return 1
    finally:
        save(output / "source-receipt.json", sources)


if __name__ == "__main__":
    raise SystemExit(main())
