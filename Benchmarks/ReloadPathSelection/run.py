#!/usr/bin/env python3
"""Measure complete sidebar reload selection against a pinned production baseline."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
CONSUMER = "Sources/IlliquidApp/UI/SourceTreeDirectoryState.swift"
CASES = [
    "empty-plan", "no-active-roots", "root-rescan-1", "root-rescan-32",
    "expanded-1x1", "expanded-1x32", "expanded-1x256", "mixed-8x256",
    "mixed-32x1024", "collapsed-32x1024", "outside-8x256",
    "filesystem-root-256", "overlapping-8x256",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def execute(argv: list, out: Path, env: dict[str, str], timeout: int = 900) -> str:
    command = list(map(str, argv))
    started = time.monotonic()
    result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    with (out / "commands.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps({"argv": command, "returncode": result.returncode,
                              "wall_seconds": time.monotonic() - started,
                              "output": result.stdout}) + "\n")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stdout[-12000:]}")
    return result.stdout


def prepare(out: Path, variant: str, baseline: bytes, support) -> Path:
    package = support.prepare_package(out / variant)
    receipt = json.loads((package / "source-receipt.json").read_text())

    def stage(relative: str, destination: str, data: bytes | None = None) -> None:
        original = (ROOT / relative).read_bytes()
        compiled = original if data is None else data
        target = package / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(compiled)
        receipt["inputs"].append({
            "path": relative, "source_sha256": digest(original),
            "compiled_path": destination, "compiled_sha256": digest(compiled),
        })

    stage(CONSUMER, "Sources/IlliquidApp/SourceTreeDirectoryState.swift",
          baseline if variant == "baseline" else None)
    stage("Sources/IlliquidApp/UI/SourceFilesystemInvalidation.swift",
          "Sources/IlliquidApp/SourceFilesystemInvalidation.swift")
    stage("Tests/IlliquidAppTests/SourceTreeDirectoryStateTests.swift",
          "Tests/IlliquidAppTests/SourceTreeDirectoryStateTests.swift")
    sidebar = "Sources/IlliquidApp/UI/SourcesSidebar.swift"
    listing, first, last = support.declaration((ROOT / sidebar).read_text(), "SourceDirectoryListing")
    stage(sidebar, "Sources/IlliquidApp/SourceDirectoryListing.swift",
          ("import Foundation\n\n" + listing + "\n").encode())
    receipt["inputs"][-1]["declarations"] = [{
        "name": "SourceDirectoryListing", "first_line": first, "last_line": last,
        "slice_sha256": digest(listing.encode()),
    }]
    oracle = baseline.decode()
    marker = "final class SourceTreeDirectoryState"
    if oracle.count(marker) != 1:
        raise ValueError("Oracle declaration moved; review the mechanical rename")
    oracle = oracle.replace(marker, "final class BaselineSourceTreeDirectoryState")
    (package / "Sources/IlliquidApp/BaselineSourceTreeDirectoryState.swift").write_text(oracle)
    harness = package / "Sources/ReloadBenchmark"
    harness.mkdir(parents=True)
    shutil.copy2(HERE / "Harness.swift", harness / "Harness.swift")
    manifest = (package / "Package.swift").read_text()
    ending = "    ]\n)\n"
    if manifest.count(ending) != 1:
        raise ValueError("Portable manifest changed; review benchmark target insertion")
    manifest = manifest.replace(ending,
        '        .executableTarget(name: "ReloadBenchmark", dependencies: ["IlliquidApp"]),\n' + ending)
    (package / "Package.swift").write_text(manifest)
    receipt.update({
        "oracle_sha256": digest(oracle.encode()),
        "benchmark_manifest_sha256": digest(manifest.encode()),
        "compiled_sources": {
            str(path.relative_to(package)): digest(path.read_bytes())
            for path in sorted((package / "Sources").rglob("*.swift"))
        },
        "tests_sha256": {
            str(path.relative_to(package)): digest(path.read_bytes())
            for path in sorted((package / "Tests").rglob("*.swift"))
        },
    })
    save(package / "source-receipt.json", receipt)
    return package


def summary(rows: list[dict]) -> list[dict]:
    groups = []
    for name in dict.fromkeys(row["case"] for row in rows):
        selected = [row for row in rows if row["case"] == name]
        group = {"case": name, "pairs": len(selected) // 2, "variants": {}}
        for variant in ("baseline", "candidate"):
            values = [row for row in selected if row["variant"] == variant]
            entry = {key: values[0][key] for key in ("input_paths", "active_roots", "expanded_paths", "output_paths")}
            for metric in ("elapsed_ns", "cpu_ns"):
                samples = [row[metric] / row["iterations"] for row in values]
                entry[metric + "_per_operation"] = {
                    "median": statistics.median(samples), "minimum": min(samples), "maximum": max(samples),
                }
            group["variants"][variant] = entry
        group["paired_reduction_percent"] = {}
        for metric in ("elapsed_ns", "cpu_ns"):
            changes = []
            for pair in sorted({row["pair"] for row in selected}):
                values = {row["variant"]: row[metric] / row["iterations"]
                          for row in selected if row["pair"] == pair}
                changes.append(100 * (1 - values["candidate"] / values["baseline"]))
            group["paired_reduction_percent"][metric] = {
                "median": statistics.median(changes), "all": changes,
                "candidate_faster_pairs": sum(value > 0 for value in changes),
            }
        groups.append(group)
    return groups


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=100)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--via-kyoto", action="store_true",
                        help="Confirm this entire command is executing as a submitted Kyoto job")
    args = parser.parse_args()
    if not args.swift:
        parser.error("Swift 6.1+ with its bundled Testing module is required")
    if args.pairs < 2 or args.pairs > 20 or args.pairs % 2:
        parser.error("--pairs must be even and between 2 and 20")
    if not 1 <= args.target_ms <= 1000:
        parser.error("--target-ms must be between 1 and 1000")
    kyoto = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
    if kyoto.exists() and not args.via_kyoto:
        parser.error("Kyoto is available: submit this command through Kyoto with --via-kyoto; see README.md")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Output directory must be new or empty")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(out / "module-cache")
    env["LC_ALL"] = "en_US.UTF-8" if platform.system() == "Darwin" else "C.UTF-8"
    swift = os.path.abspath(args.swift)
    baseline_ref = execute(["git", "rev-parse", "--verify", args.baseline_ref + "^{commit}"], out, env).strip()
    baseline = subprocess.check_output(["git", "-C", str(ROOT), "show", baseline_ref + ":" + CONSUMER])
    environment = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(), "compiler": execute([swift, "--version"], out, env).strip(),
        "git_head": execute(["git", "rev-parse", "HEAD"], out, env).strip(),
        "baseline_ref": baseline_ref, "baseline_source_sha256": digest(baseline),
        "candidate_source_sha256": digest((ROOT / CONSUMER).read_bytes()),
        "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "pairs": args.pairs, "target_ms": args.target_ms, "minimum_variant_ms": 20,
        "iteration_cap": 500000, "locale": env["LC_ALL"],
        "cpu_description": (Path("/proc/cpuinfo").read_text().split("\n\n")[0]
            if Path("/proc/cpuinfo").exists()
            else execute(["sysctl", "-n", "machdep.cpu.brand_string"], out, env).strip()),
    }
    save(out / "environment.json", environment)
    if not kyoto.exists():
        print("Kyoto is unavailable on this host; using serialized isolated component builds.", flush=True)
    spec = importlib.util.spec_from_file_location("browser_support", ROOT / "Scripts/test-source-browser-search.py")
    support = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(support)
    packages = {variant: prepare(out, variant, baseline, support) for variant in ("baseline", "candidate")}
    receipts = {variant: json.loads((package / "source-receipt.json").read_text())
                for variant, package in packages.items()}
    changed = [path for path, value in receipts["baseline"]["compiled_sources"].items()
               if receipts["candidate"]["compiled_sources"].get(path) != value]
    if changed != ["Sources/IlliquidApp/SourceTreeDirectoryState.swift"]:
        raise RuntimeError(f"Expected only the production directory consumer to differ: {changed}")
    for key in ("tests_sha256", "oracle_sha256", "benchmark_manifest_sha256"):
        if receipts["baseline"][key] != receipts["candidate"][key]:
            raise RuntimeError(f"Baseline and candidate inputs differ: {key}")
    binaries = {}
    tests = []
    verifications = []
    for variant, package in packages.items():
        for configuration in ("debug", "release"):
            output = execute([swift, "test", "--package-path", package, "--configuration", configuration,
                              "--jobs", "2", "-Xswiftc", "-enable-testing",
                              "-Xswiftc", "-warnings-as-errors"], out, env)
            (out / f"{variant}-{configuration}-tests.log").write_text(output)
            counts = re.findall(r"Test run with (\d+) tests?\b", output)
            if not counts or int(counts[-1]) == 0:
                raise RuntimeError("No completed Swift Testing tests reported")
            tests.append({"variant": variant, "configuration": configuration,
                          "count": int(counts[-1]), "passed": True})
            execute([swift, "build", "--package-path", package, "--configuration", configuration,
                     "--product", "ReloadBenchmark", "--jobs", "2",
                     "-Xswiftc", "-enable-testing", "-Xswiftc", "-warnings-as-errors"], out, env)
            binary_dir = execute([swift, "build", "--package-path", package,
                                  "--configuration", configuration, "--show-bin-path"], out, env).strip()
            binary = Path(binary_dir) / "ReloadBenchmark"
            verified = json.loads(execute([binary, "verify"], out, env))
            if verifications and verified != verifications[0]["result"]:
                raise RuntimeError("Differential verification receipts differ")
            verifications.append({"variant": variant, "configuration": configuration,
                                  "binary_sha256": digest(binary.read_bytes()), "result": verified})
            if configuration == "release":
                binaries[variant] = binary
            print(f"{variant} {configuration}: {counts[-1]} tests; {verified['verified_cases']} differential cases passed",
                  flush=True)
    save(out / "tests.json", tests)
    save(out / "verification.json", verifications)
    rows = []
    if not args.tests_only:
        if hasattr(os, "sched_setaffinity"):
            cpu = min(os.sched_getaffinity(0))
            os.sched_setaffinity(0, {cpu})
            environment["measurement_cpu_affinity"] = [cpu]
            save(out / "environment.json", environment)
        for name in CASES:
            calibration = {variant: json.loads(execute([binary, "bench", name, "1"], out, env))
                           for variant, binary in binaries.items()}
            longest = max(row["elapsed_ns"] for row in calibration.values())
            shortest = min(max(1, row["elapsed_ns"]) for row in calibration.values())
            # Keep one shared count while allowing the faster implementation
            # at least 20 ms of work when practical. Cheap controls hit the cap.
            iterations = max(1, min(500000, max(
                math.ceil(args.target_ms * 1_000_000 / max(1, longest)),
                math.ceil(20_000_000 / shortest),
            )))
            save(out / (name + "-calibration.json"), calibration)
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                paired = []
                for sequence, variant in enumerate(order):
                    row = json.loads(execute([binaries[variant], "bench", name, str(iterations)], out, env))
                    row.update(variant=variant, pair=pair, sequence=sequence)
                    rows.append(row)
                    paired.append(row)
                    with (out / "measurements.jsonl").open("a") as log:
                        log.write(json.dumps(row, sort_keys=True) + "\n")
                for key in ("fingerprint", "checksum", "output_paths", "input_paths", "iterations", "oracle_equal"):
                    if paired[0][key] != paired[1][key]:
                        raise RuntimeError(f"Paired result differs: {name}: {key}")
            groups = summary(rows)
            save(out / "summary.json", groups)
            last = groups[-1]
            print(name, "median_us", {
                variant: round(last["variants"][variant]["elapsed_ns_per_operation"]["median"] / 1000, 3)
                for variant in ("baseline", "candidate")
            }, "paired_reduction_percent",
                round(last["paired_reduction_percent"]["elapsed_ns"]["median"], 2), flush=True)
    completion = {"complete": True, "cases": 0 if args.tests_only else len(CASES), "measurements": len(rows)}
    save(out / "completion.json", completion)
    # Keep reviewable compact receipts in the job log even after artifact expiry.
    print("RELOAD_RESULTS_JSON=" + json.dumps({
        "environment": environment, "tests": tests,
        "verified_cases_per_binary": verifications[0]["result"]["verified_cases"],
        "source_receipts": receipts, "completion": completion,
        "summary": summary(rows), "measurements": rows,
    }, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
