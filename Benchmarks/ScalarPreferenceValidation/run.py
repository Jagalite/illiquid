#!/usr/bin/env python3
"""Compare real scalar preference setters, retaining exact sources and raw timings."""
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DEFAULT_BASE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TEST_FILES = [
    "ScalarPreferenceValidationTests.swift",
    "PlaybackPersistenceStoreTests.swift",
    "IdempotentPersistenceTests.swift",
    "DeferredPersistenceTests.swift",
    "HistoryPolicyTests.swift",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ScalarPreferenceValidation",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "ScalarPreferenceBenchmark", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
"""


def command(args, **kwargs):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args!r}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(output, name, value):
    (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def prepare(work, variant, base):
    package = work / variant
    sources = package / "Sources/IlliquidCore"
    sources.mkdir(parents=True)
    if variant == "baseline":
        paths = command(["git", "ls-tree", "-r", "--name-only", base,
                         "--", "Sources/IlliquidCore"]).splitlines()
        for path in paths:
            relative = Path(path).relative_to("Sources/IlliquidCore")
            destination = sources / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(command(["git", "show", f"{base}:{path}"]))
    else:
        shutil.copytree(ROOT / "Sources/IlliquidCore", sources, dirs_exist_ok=True)
    tests = package / "Tests/IlliquidCoreTests"
    tests.mkdir(parents=True)
    for name in TEST_FILES:
        shutil.copy2(ROOT / "Tests/IlliquidCoreTests" / name, tests / name)
    driver = package / "Sources/ScalarPreferenceBenchmark"
    driver.mkdir(parents=True)
    shutil.copy2(HERE / "Driver.swift", driver / "Driver.swift")
    (package / "Package.swift").write_text(PACKAGE)
    receipt = {
        str(path.relative_to(package)): digest(path.read_bytes())
        for directory in ["Sources", "Tests"]
        for path in sorted((package / directory).rglob("*.swift"))
    }
    return package, receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--pairs", type=int, default=9)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.pairs < 3:
        parser.error("--pairs must be at least 3")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    base = command(["git", "rev-parse", "--verify", args.base + "^{commit}"]).strip()
    head = command(["git", "rev-parse", "HEAD"]).strip()
    manifest = {
        "baseline": base, "candidate": head,
        "working_tree_status": command(["git", "status", "--porcelain"]),
        "platform": platform.platform(), "machine": platform.machine(),
        "swift": command(["swift", "--version"]).strip(),
        "python": platform.python_version(), "pairs": args.pairs,
        "runner": os.environ.get("GITHUB_RUN_ID"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "method": "separate optimized modules; serial alternating process pairs",
        "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "sources": {},
    }
    if platform.system() == "Darwin":
        manifest["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
        manifest["macos"] = command(["sw_vers"]).strip()
    save(output, "manifest.json", manifest)
    binaries = {}
    test_receipts = []
    observations = []
    calibration = []
    parity = {}
    with tempfile.TemporaryDirectory(prefix="illiquid-scalar-preferences-") as temporary:
        work = Path(temporary)
        for variant in ["baseline", "candidate"]:
            package, receipt = prepare(work, variant, base)
            manifest["sources"][variant] = receipt
            save(output, "manifest.json", manifest)
            for configuration in ["debug", "release"]:
                invocation = [
                    "swift", "test", "--package-path", str(package),
                    "-c", configuration, "--jobs", "2", "--no-parallel",
                ]
                result = subprocess.run(invocation, cwd=ROOT, text=True, capture_output=True)
                log = result.stdout + "\n" + result.stderr
                log_name = f"tests-{variant}-{configuration}.log"
                (output / log_name).write_text(log)
                receipt = {
                    "variant": variant, "configuration": configuration,
                    "exit_code": result.returncode, "log": log_name,
                    "sha256": digest(log.encode()),
                    "summary": [line for line in log.splitlines()
                                if "Executed " in line or "Test run with " in line],
                }
                test_receipts.append(receipt)
                save(output, "tests.json", test_receipts)
                print("TEST_RESULT", json.dumps(receipt), flush=True)
                if result.returncode:
                    print(log, flush=True)
                    raise RuntimeError(f"{variant} {configuration} regressions failed")
            command(["swift", "build", "--package-path", str(package),
                     "-c", "release", "--jobs", "2", "--product", "ScalarPreferenceBenchmark"])
            binary_directory = command(["swift", "build", "--package-path", str(package),
                                        "-c", "release", "--show-bin-path"]).strip()
            binaries[variant] = str(Path(binary_directory) / "ScalarPreferenceBenchmark")

        cases = []
        for languages in [0, 4, 32]:
            for field in ["volume", "speed"]:
                for mode in ["unchanged", "changing", "clamped"]:
                    cases.append((field, mode, languages, "blocked"))
                cases.append((field, "changing", languages, "normal"))

        def run(variant, case, iterations):
            field, mode, languages, writer = case
            invocation = [binaries[variant], field, mode, str(languages),
                          str(iterations), writer]
            result = json.loads(command(invocation))
            identity = f"{field}-{mode}-{languages}-{writer}"
            expected = parity.setdefault(identity, result["preferences"])
            if result["preferences"] != expected or not result["reload_matches"]:
                raise RuntimeError(f"behavior mismatch: {identity} {variant}")
            result.pop("preferences")
            result.update(case=identity, variant=variant)
            return result

        for case_index, case in enumerate(cases):
            iterations = {}
            for variant in ["baseline", "candidate"]:
                if case[3] == "normal":
                    iterations[variant] = 32
                    continue
                pilot = run(variant, case, 128)
                calibration.append(pilot)
                # Aim for 50 ms independently, without millions of slow baseline
                # normalizations. Writer gating keeps timer/I/O behavior identical.
                count = math.ceil(50_000_000 / max(1, pilot["ns_per_update"]) / 64) * 64
                iterations[variant] = max(128, min(2_000_000, count))
            for pair in range(args.pairs):
                order = ["baseline", "candidate"] if (pair + case_index) % 2 == 0 else ["candidate", "baseline"]
                paired = {}
                for position, variant in enumerate(order):
                    observation = run(variant, case, iterations[variant])
                    observation.update(pair=pair, order=position)
                    observations.append(observation)
                    paired[variant] = observation
                if case[3] == "blocked" and paired["baseline"]["preference_writes_after_setup"] != paired["candidate"]["preference_writes_after_setup"]:
                    raise RuntimeError("writer callback counts differ")
            save(output, "observations.json", observations)
            save(output, "calibration.json", calibration)
            save(output, "parity.json", parity)
            print("CASE_COMPLETE", case, flush=True)

    summary = []
    for identity in parity:
        rows = [row for row in observations if row["case"] == identity]
        by_variant = {
            variant: [row["ns_per_update"] for row in rows if row["variant"] == variant]
            for variant in ["baseline", "candidate"]
        }
        ratios = []
        for pair in range(args.pairs):
            pair_rows = {row["variant"]: row for row in rows if row["pair"] == pair}
            ratios.append(pair_rows["baseline"]["ns_per_update"] /
                          pair_rows["candidate"]["ns_per_update"])
        summary.append({
            "case": identity, "pairs": args.pairs,
            "baseline_ns_median": statistics.median(by_variant["baseline"]),
            "candidate_ns_median": statistics.median(by_variant["candidate"]),
            "paired_speedup_median": statistics.median(ratios),
            "paired_speedup_min": min(ratios), "paired_speedup_max": max(ratios),
        })
    save(output, "summary.json", summary)
    save(output, "completion.json", {
        "status": "passed", "behavior_cases": len(parity),
        "timing_observations": len(observations),
        "test_runs": len(test_receipts),
    })
    # Plain JSON receipts also survive artifact expiration in the Actions log.
    # The caller can commit these exact records without reconstructing statistics.
    for name in ["manifest", "tests", "calibration", "parity", "observations", "summary", "completion"]:
        print("SCALAR_" + name.upper(), (output / (name + ".json")).read_text().replace("\n", ""), flush=True)
    for receipt in test_receipts:
        print("SCALAR_TEST_LOG", json.dumps({
            "name": receipt["log"], "text": (output / receipt["log"]).read_text()
        }), flush=True)


if __name__ == "__main__":
    main()
