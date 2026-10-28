#!/usr/bin/env python3
"""Exact-source, paired sort probe. No latency threshold or live-memory claim."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = ["Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
           "Sources/IlliquidCore/Playlist/FolderPlaylist.swift",
           "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"]
TESTS = ["Tests/IlliquidCoreTests/NaturalFilenameOrderingTests.swift",
         "Tests/IlliquidCoreTests/FolderPlaylistTests.swift"]
DRIVERS = ["run.py", "Harness.swift", "allocmeter.c", "MeterCheck.c"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "NaturalFilenameSortStorageProbe", targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
])
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def statistics_of(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values)} if values else None


def percent_change(before, after):
    return 100 * (after - before) / before if before else (0.0 if after == 0 else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="New or empty evidence directory")
    parser.add_argument("--swift", default="swift", help="Swift executable; swiftc must be beside it")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--jobs", type=int, default=2, help="Maximum concurrent Swift compiler jobs")
    parser.add_argument("--sizes", default="1000,10000", help="Comma-separated nonnegative counts")
    parser.add_argument("--quick", action="store_true", help="Use 100-element workloads plus tiny controls")
    parser.add_argument("--skip-tests", action="store_true", help="Exploration only; recorded in manifest")
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    try:
        sizes = [100] if args.quick else sorted(set(int(n) for n in args.sizes.split(",")))
        if not sizes or min(sizes) < 0 or args.pairs < 2 or args.pairs % 2 or args.jobs < 1:
            raise ValueError("sizes must be nonnegative; pairs must be even >= 2; jobs must be positive")
        if args.skip_tests and args.tests_only:
            raise ValueError("--skip-tests and --tests-only conflict")
    except ValueError as error:
        parser.error(str(error))
    swift = Path(os.path.abspath(os.path.expanduser(shutil.which(args.swift) or args.swift)))
    swiftc = swift.with_name("swiftc")
    if not swift.is_file() or not swiftc.is_file():
        parser.error("Swift and sibling swiftc executables are required")
    output = args.output.resolve()
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        parser.error("--output must be empty; prior evidence is never overwritten")
    output.mkdir(parents=True, exist_ok=True)
    logs, drivers = output / "logs", output / "drivers"
    logs.mkdir(); drivers.mkdir()
    for name in ["swiftpm-cache", "swiftpm-config", "swiftpm-security", "module-cache"]:
        (output / name).mkdir()
    environment = os.environ.copy()
    environment.pop("LD_PRELOAD", None)  # The latency executable never loads the meter.
    environment["CLANG_MODULE_CACHE_PATH"] = str(output / "module-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(output / "module-cache")
    command_number = 0

    def run(command, label, cwd=ROOT, overrides=None):
        nonlocal command_number
        command_number += 1
        command = [str(part) for part in command]
        stem = f"{command_number:04d}-{label}"
        stdout, stderr = logs / (stem + ".stdout.txt"), logs / (stem + ".stderr.txt")
        started = time.monotonic()
        timed_out = False
        try:
            result = subprocess.run(command, cwd=cwd, env=environment | (overrides or {}),
                                    capture_output=True, timeout=600)
            status, stdout_data, stderr_data = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as error:
            timed_out = True
            status, stdout_data = 124, error.stdout or b""
            stderr_data = (error.stderr or b"") + b"\nRunner timeout: 600 seconds.\n"
        except OSError as error:
            status, stdout_data, stderr_data = 127, b"", str(error).encode()
        stdout.write_bytes(stdout_data); stderr.write_bytes(stderr_data)
        record = {"command": command, "cwd": str(cwd), "label": label,
                  "environment_overrides": overrides or {}, "returncode": status, "timed_out": timed_out,
                  "elapsed_seconds": time.monotonic() - started,
                  "stdout": str(stdout.relative_to(output)), "stderr": str(stderr.relative_to(output))}
        with (output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        if status:
            raise RuntimeError(f"{label} failed ({status}); see {stderr}")
        return stdout_data

    manifest = {"baseline": BASELINE, "created_at_utc": datetime.now(timezone.utc).isoformat(),
                "host": {"system": platform.system(), "release": platform.release(),
                         "machine": platform.machine(), "libc": platform.libc_ver(),
                         "python": platform.python_version()},
                "swift": str(swift), "swiftc": str(swiftc), "invocation": sys.argv,
                "options": {**vars(args), "output": str(output), "resolved_sizes": sizes},
                "environment": {key: environment.get(key) for key in
                                ["LANG", "LC_ALL", "LC_COLLATE", "LC_CTYPE",
                                 "CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE"]},
                "sources": {}, "tests": {}, "drivers": {}, "binaries": {}, "tests_run": [],
                "notes": ["Whole production files, separate optimized module and unchanged driver.",
                          "Only the two focused test files; not a full player/macOS qualification.",
                          "Allocation requests are cumulative, not live heap, peak memory, or RSS.",
                          "No timing threshold; per-pair percentage changes retain negative/positive signs."]}
    try:
        manifest["compiler"] = run([swift, "--version"], "swift-version").decode().strip()
        manifest["head"] = run(["git", "rev-parse", "HEAD"], "git-head").decode().strip()
        manifest["git_status"] = run(["git", "status", "--short"], "git-status").decode()
        for name in DRIVERS:
            data = (HERE / name).read_bytes()
            (drivers / name).write_bytes(data); manifest["drivers"][name] = digest(data)
        current_sources = {path: (ROOT / path).read_bytes() for path in SOURCES}
        current_tests = {path: (ROOT / path).read_bytes() for path in TESTS}
        manifest["tests"] = {path: digest(data) for path, data in current_tests.items()}
        for variant in ["baseline", "candidate"]:
            package = output / variant
            source_dir, test_dir = package / "Sources/IlliquidCore", package / "Tests/IlliquidCoreTests"
            source_dir.mkdir(parents=True); test_dir.mkdir(parents=True)
            (package / "Package.swift").write_text(PACKAGE)
            manifest["sources"][variant] = {}
            for path in SOURCES:
                data = (run(["git", "show", f"{BASELINE}:{path}"], "baseline-" + Path(path).stem)
                        if variant == "baseline" else current_sources[path])
                (source_dir / Path(path).name).write_bytes(data)
                manifest["sources"][variant][path] = digest(data)
            for path, data in current_tests.items():
                (test_dir / Path(path).name).write_bytes(data)
        for path in SOURCES[1:]:
            if manifest["sources"]["baseline"][path] != manifest["sources"]["candidate"][path]:
                raise RuntimeError(f"Unchanged production dependency differs from baseline: {path}")
        manifest["unchanged_sources_verified"] = SOURCES[1:]
        save(output / "manifest.json", manifest)
        if not args.skip_tests:
            for variant, configuration in [("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]:
                print(f"Testing {variant} {configuration}", flush=True)
                test_flags = ["--use-integrated-swift-driver"] if platform.system() == "Linux" else []
                run([swift, "test", "--package-path", output / variant, "--no-parallel", "-c", configuration,
                     "--jobs", args.jobs, "--cache-path", output / "swiftpm-cache",
                     "--config-path", output / "swiftpm-config", "--security-path", output / "swiftpm-security",
                     "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-module-cache-path",
                     "-Xswiftc", output / "module-cache", *test_flags], f"test-{variant}-{configuration}")
                manifest["tests_run"].append({"variant": variant, "configuration": configuration, "passed": True})
        if args.tests_only:
            save(output / "summary.json", {"tests_only": True, "tests_run": manifest["tests_run"]})
            return
        meter = platform.system() == "Linux" and platform.libc_ver()[0] == "glibc"
        manifest["allocation_meter"] = "glibc successful requests, measured thread only" if meter else "unavailable on this host"
        meter_path = drivers / "liballocmeter.so"
        if meter:
            run(["cc", "-O2", "-std=c11", "-shared", "-fPIC", "-fno-builtin", "-Wall", "-Wextra", "-Werror",
                 drivers / "allocmeter.c", "-o", meter_path], "build-meter")
            run(["cc", "-O2", "-fno-builtin", "-std=c11", "-pthread", drivers / "MeterCheck.c", "-L", drivers,
                 "-lallocmeter", f"-Wl,-rpath,{drivers}", "-o", drivers / "meter-check"], "build-meter-check")
            run([drivers / "meter-check"], "meter-check", overrides={"LD_PRELOAD": str(meter_path)})
        for variant in ["baseline", "candidate"]:
            print(f"Building {variant} measurement executables", flush=True)
            package, binaries = output / variant, output / variant / "bin"
            binaries.mkdir()
            library = binaries / ("libIlliquidCore.dylib" if platform.system() == "Darwin" else "libIlliquidCore.so")
            flags = ["-swift-version", "6", "-O", "-parse-as-library", "-warnings-as-errors",
                     "-module-cache-path", output / "module-cache"]
            run([swiftc, *flags, "-whole-module-optimization", "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
                 "-emit-module-path", binaries / "IlliquidCore.swiftmodule",
                 *[package / "Sources/IlliquidCore" / Path(path).name for path in SOURCES], "-o", library], f"build-{variant}-module")
            link = ["-I", binaries, "-L", binaries, "-lIlliquidCore", "-Xlinker", "-rpath", "-Xlinker", binaries]
            run([swiftc, *flags, *link, drivers / "Harness.swift", "-o", binaries / "latency"], f"build-{variant}-latency")
            if meter:
                run([swiftc, *flags, *link, "-D", "ALLOCATION_METER", "-L", drivers, "-lallocmeter",
                     "-Xlinker", "-rpath", "-Xlinker", drivers, drivers / "Harness.swift", "-o", binaries / "allocations"],
                    f"build-{variant}-allocations")
            for path in binaries.iterdir():
                if path.is_file(): manifest["binaries"][str(path.relative_to(output))] = digest(path.read_bytes())
        if meter:
            for path in [meter_path, drivers / "meter-check"]:
                manifest["binaries"][str(path.relative_to(output))] = digest(path.read_bytes())
        verification = {variant: json.loads(run([output / variant / "bin/latency", "--verify"], f"verify-{variant}"))
                        for variant in ["baseline", "candidate"]}
        save(output / "verification.json", verification)
        if verification["baseline"] != verification["candidate"]:
            raise RuntimeError("Complete verification JSON differs between variants")
        cases = [{"operation": op, "pattern": pattern, "count": count}
                 for op in ["urls", "playlist"] for count in sizes
                 for pattern in ["shuffled", "sorted", "reversed", "ties", "unicode"]]
        cases += [{"operation": op, "pattern": "shuffled", "count": count}
                  for op in ["urls", "playlist"] for count in [0, 1, 2, 3, 8]
                  if {"operation": op, "pattern": "shuffled", "count": count} not in cases]
        for case in cases:
            case["id"] = f'{case["operation"]}/{case["pattern"]}/{case["count"]}'
            case["iterations"] = max(1, min(1000, 10000 // max(1, case["count"])))
        save(output / "cases.json", cases)
        rows = []
        identity = ["operation", "pattern", "count", "iterations", "locale", "checksum", "fingerprint", "full_output_verified"]
        for case in cases:
            print(f'Measuring {case["id"]} ({args.pairs} AB/BA pairs)', flush=True)
            for mode in (["latency", "allocations"] if meter else ["latency"]):
                for pair in range(args.pairs):
                    order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                    observations = {}
                    for variant in order:
                        iterations = 1 if mode == "allocations" else case["iterations"]
                        arguments = (["--allocations"] if mode == "allocations" else []) + [case["operation"], case["pattern"], case["count"], iterations]
                        raw = run([output / variant / "bin" / mode, *arguments], f'{mode}-{variant}-{len(rows):04d}',
                                  overrides={"LD_PRELOAD": str(meter_path)} if mode == "allocations" else None)
                        observation = json.loads(raw)
                        if observation["count"] != case["count"] or observation["iterations"] != iterations or observation["full_output_verified"] is not True:
                            raise RuntimeError("Harness result did not verify the requested case")
                        observations[variant] = observation
                        row = {**observation, "case": case["id"], "variant": variant, "pair": pair, "order": order}
                        rows.append(row)
                        with (output / "observations.jsonl").open("a") as stream:
                            stream.write(json.dumps(row, sort_keys=True) + "\n")
                    if any(observations["baseline"][key] != observations["candidate"][key] for key in identity):
                        raise RuntimeError(f'Paired output identity differs for {case["id"]} {mode} pair {pair}')
        summaries = []
        metrics = {"latency": ["ns_per_iteration"], "allocations": ["allocation_requested_bytes", "allocation_requests", "allocation_max_request"]}
        for case in cases:
            summary = {**case, "metrics": {}}
            for mode, names in metrics.items():
                selected = [row for row in rows if row["case"] == case["id"] and row["mode"] == mode]
                if not selected: continue
                variants = {v: sorted([r for r in selected if r["variant"] == v], key=lambda r: r["pair"]) for v in ["baseline", "candidate"]}
                for name in names:
                    before, after = [r[name] for r in variants["baseline"]], [r[name] for r in variants["candidate"]]
                    changes = [percent_change(b, a) for b, a in zip(before, after)]
                    summary["metrics"][name] = {"baseline": statistics_of(before), "candidate": statistics_of(after),
                                               "paired_percent_change": statistics_of([n for n in changes if n is not None])}
            summaries.append(summary)
        categories = {op: {name: statistics_of([s["metrics"][name]["paired_percent_change"]["median"] for s in summaries
                     if s["operation"] == op and name in s["metrics"] and s["metrics"][name]["paired_percent_change"] is not None])
                     for names in metrics.values() for name in names} for op in ["urls", "playlist"]}
        save(output / "summary.json", {"pairs": args.pairs, "cases": summaries,
             "categories": categories, "category_statistic": "distribution of case median paired percentage changes",
             "notes": manifest["notes"], "tests_skipped": args.skip_tests})
        print(f"Evidence written to {output}", flush=True)
    except Exception as error:
        manifest["error"] = str(error)
        raise
    finally:
        save(output / "manifest.json", manifest)


if __name__ == "__main__":
    main()
