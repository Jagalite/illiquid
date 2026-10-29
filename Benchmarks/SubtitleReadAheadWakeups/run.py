#!/usr/bin/env python3
"""Compare the exact production subtitle read-ahead gate in fresh processes."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_BLOB = "10374be342abef4546031d6edd988566b31a62b0"
SOURCE = "Sources/IlliquidNativePlayback/Media/MediaReadAheadGate.swift"
TESTS = (
    "Tests/IlliquidNativePlaybackTests/MediaReadAheadGateTests.swift",
    "Tests/IlliquidNativePlaybackTests/MediaReadAheadGatePerformanceTests.swift",
    "Tests/IlliquidNativePlaybackTests/MediaReadAheadGateEOFTests.swift",
)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
KYOTO = Path("/Volumes/seed1/Projects/kyoto/kyoto.py")
CASES = [
    ("eof-paced", 120),
    ("gap-paced", 120),
    ("no-reader", 2_000_000),
    ("immediate-admission", 2_000_000),
    ("eof-burst", 500_000),
    ("gap-burst", 500_000),
    ("useful-progress", 2_000),
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=7)
    parser.add_argument("--queued", action="store_true",
                        help="Only set when this entire runner is executing inside a Kyoto job")
    args = parser.parse_args()
    if args.pairs < 3:
        parser.error("--pairs must be at least 3")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / "logs").mkdir()
    commands = []

    def run(argv, label, cwd=ROOT, timeout=300):
        argv = [str(value) for value in argv]
        started = time.monotonic()
        proc = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout)
        log = out / "logs" / (label + ".log")
        log.write_text(proc.stdout)
        commands.append({
            "argv": argv, "cwd": str(cwd), "label": label,
            "returncode": proc.returncode, "seconds": time.monotonic() - started,
            "log": str(log.relative_to(out)),
        })
        write_json(out / "commands.json", commands)
        if proc.returncode:
            print(proc.stdout, flush=True)
            raise RuntimeError(f"{label} failed: {proc.returncode}")
        return proc.stdout.strip()

    if KYOTO.exists() and not args.queued:
        raise SystemExit(
            "Kyoto is available. Submit this runner through the shared queue "
            "with --queued, then inspect the queue's show/logs/wait receipts."
        )
    print("Running serial builds inside the submitted Kyoto job." if KYOTO.exists() else
          "Kyoto is unavailable on this host; running isolated builds serially.", flush=True)

    swiftc = shutil.which("swiftc")
    swift = shutil.which("swift")
    if not swiftc or not swift:
        raise SystemExit("Swift 6 or later is required")
    head = run(["git", "rev-parse", "HEAD"], "head")
    blob = run(["git", "rev-parse", f"{BASELINE}:{SOURCE}"], "baseline-blob")
    if blob != BASELINE_BLOB:
        raise RuntimeError("Pinned baseline blob does not match")
    baseline = subprocess.check_output(["git", "show", f"{BASELINE}:{SOURCE}"], cwd=ROOT)
    candidate = (ROOT / SOURCE).read_bytes()
    inputs = {SOURCE: digest(candidate), **{path: digest((ROOT / path).read_bytes()) for path in TESTS}}
    for name in ("Driver.swift", "Probe.swift", "run.py"):
        inputs[str((HERE / name).relative_to(ROOT))] = digest((HERE / name).read_bytes())
    compiler = run([swiftc, "--version"], "compiler")
    manifest = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "test_sha256": {path: digest((ROOT / path).read_bytes()) for path in TESTS},
        "baseline_commit": BASELINE, "baseline_blob": BASELINE_BLOB,
        "candidate_commit": head,
        "baseline_source_sha256": digest(baseline),
        "candidate_source_sha256": digest(candidate),
        "input_sha256": inputs,
        "compiler": compiler, "platform": platform.platform(),
        "machine": platform.machine(), "processor": platform.processor(),
        "cpu_count": os.cpu_count(),
        "kyoto_available": KYOTO.exists(), "queued_invocation": args.queued,
        "ci_run_url": (
            f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/"
            f"{os.environ['GITHUB_RUN_ID']}"
            if os.environ.get("GITHUB_RUN_ID") else None
        ),
        "ci_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        "flags": ["-swift-version", "6", "-O", "-whole-module-optimization"],
        "pairs": args.pairs, "cases": CASES,
        "scope": "Isolated real Foundation gate; no FFmpeg, renderer, UI, or energy measurement.",
    }
    if sys.platform == "darwin":
        manifest["xcode"] = run(["xcodebuild", "-version"], "xcode")
        manifest["sdk"] = run(["xcrun", "--show-sdk-version"], "sdk")
        manifest["hardware"] = run(
            ["sysctl", "hw.model", "hw.ncpu", "hw.memsize", "machdep.cpu.brand_string"], "hardware"
        )
    write_json(out / "manifest.json", manifest)
    binaries = {}
    test_receipts = []
    probes = []
    package = """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ReadAheadQualification",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])
    ]
)
"""

    for variant, source in (("baseline", baseline), ("candidate", candidate)):
        print(f"Building and testing {variant}", flush=True)
        staged = out / variant
        staged.mkdir()
        source_path = staged / "MediaReadAheadGate.swift"
        source_path.write_bytes(source)
        driver = staged / "Driver.swift"
        driver.write_bytes((HERE / "Driver.swift").read_bytes())
        executable = staged / "driver"
        run([swiftc, "-swift-version", "6", "-O", "-whole-module-optimization",
             "-module-cache-path", out / "module-cache",
             source_path, driver, "-o", executable], f"{variant}-driver-build")
        binaries[variant] = executable

        # The timed source remains byte-for-byte identical. This separate
        # mechanism executable changes exactly one NSCondition construction.
        original = "private let condition = NSCondition()"
        replacement = "let condition = ProbeCondition()"
        source_text = source.decode()
        if source_text.count(original) != 1:
            raise RuntimeError("Unexpected source shape for mechanism probe")
        probe_source = staged / "ProbeGate.swift"
        probe_source.write_text(source_text.replace(original, replacement))
        probe_driver = staged / "Probe.swift"
        probe_driver.write_bytes((HERE / "Probe.swift").read_bytes())
        probe_executable = staged / "probe"
        run([swiftc, "-swift-version", "6", "-O", "-whole-module-optimization",
             "-module-cache-path", out / "module-cache",
             probe_source, probe_driver, "-o", probe_executable], f"{variant}-probe-build")
        probe = json.loads(run([probe_executable, "--variant", variant], f"{variant}-probe"))
        if not probe["passed"]:
            raise RuntimeError("Mechanism probe failed")
        probes.append(probe)

        test_package = staged / "tests"
        target = test_package / "Sources" / "IlliquidNativePlayback"
        tests = test_package / "Tests" / "IlliquidNativePlaybackTests"
        target.mkdir(parents=True)
        tests.mkdir(parents=True)
        (test_package / "Package.swift").write_text(package)
        (target / "MediaReadAheadGate.swift").write_bytes(source)
        for path in TESTS:
            (tests / Path(path).name).write_bytes((ROOT / path).read_bytes())
        for configuration in ("debug", "release"):
            label = f"{variant}-tests-{configuration}"
            output = run([swift, "test", "--package-path", test_package,
                          "--configuration", configuration, "--no-parallel"], label)
            # Require the Swift Testing suite, not merely a zero-test XCTest pass.
            if not re.search(r"Test run with 41 tests\b[^\n]*\bpassed\b", output):
                raise RuntimeError(f"Missing 41-test success receipt in {label}")
            test_receipts.append({
                "variant": variant, "configuration": configuration,
                "passed": 41, "log": f"logs/{label}.log",
                "log_sha256": digest((out / "logs" / f"{label}.log").read_bytes()),
            })
        manifest[variant] = {
            "staged_source_sha256": digest(source_path.read_bytes()),
            "driver_sha256": digest(executable.read_bytes()),
            "probe_executable_sha256": digest(probe_executable.read_bytes()),
            "probe_source_sha256": digest(probe_source.read_bytes()),
            "probe_transform": {"from": original, "to": replacement, "replacements": 1},
        }
        write_json(out / "manifest.json", manifest)

    write_json(out / "tests.json", test_receipts)
    write_json(out / "probes.json", probes)
    rows = []
    for pair in range(args.pairs):
        # Alternate process order within each case; rotate the case order.
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        cases = CASES[pair % len(CASES):] + CASES[:pair % len(CASES)]
        for name, iterations in cases:
            for slot, variant in enumerate(order):
                print(f"Pair {pair + 1}/{args.pairs}: {name} {variant}", flush=True)
                row = json.loads(run([binaries[variant], name, iterations],
                                     f"pair-{pair}-{name}-{variant}", timeout=60))
                if row["case"] != name or row["iterations"] != iterations:
                    raise RuntimeError("Driver returned the wrong workload")
                row.update({"pair": pair, "slot": slot, "variant": variant})
                rows.append(row)
                with (out / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")

    summary = {}
    metrics = ["wall_ns", "cpu_ns", "voluntary_context_switches", "involuntary_context_switches"]
    for name, iterations in CASES:
        selected = [row for row in rows if row["case"] == name]
        if len(selected) != args.pairs * 2:
            raise RuntimeError("Missing paired samples")
        variants = {
            variant: {metric: statistics.median(
                row[metric] for row in selected if row["variant"] == variant
            ) for metric in metrics}
            for variant in ("baseline", "candidate")
        }
        ratios = {}
        for metric in ("wall_ns", "cpu_ns"):
            values = []
            for pair in range(args.pairs):
                a = next(row for row in selected if row["pair"] == pair and row["variant"] == "baseline")
                b = next(row for row in selected if row["pair"] == pair and row["variant"] == "candidate")
                if a["final_position"] != b["final_position"] or a["admissions"] != b["admissions"]:
                    raise RuntimeError("Workload parity failed")
                if a[metric] > 0:
                    values.append(b[metric] / a[metric])
            ratios[metric] = {
                "median_candidate_over_baseline": statistics.median(values),
                "min": min(values), "max": max(values),
            }
        summary[name] = {"iterations": iterations, "medians": variants, "paired_ratios": ratios}

    # Recheck source and executable identity after every measurement.
    for path, expected in inputs.items():
        if digest((ROOT / path).read_bytes()) != expected:
            raise RuntimeError(f"Input changed during measurement: {path}")
    for variant in ("baseline", "candidate"):
        if digest(binaries[variant].read_bytes()) != manifest[variant]["driver_sha256"]:
            raise RuntimeError("Timed executable changed during measurement")
    write_json(out / "summary.json", summary)
    completion = {"passed": True, "pairs": args.pairs, "rows": len(rows),
                  "test_executions": 164, "mechanism_probes": len(probes)}
    write_json(out / "completion.json", completion)

    # Durable raw evidence is also emitted in the log for connector retrieval.
    # Each line is separately identifiable, so timestamp prefixes are harmless.
    for name, value in (
        ("manifest", manifest), ("tests", test_receipts), ("probes", probes),
        ("measurements", rows), ("summary", summary), ("completion", completion)
    ):
        print("READAHEAD_EVIDENCE " + json.dumps({"name": name, "data": value}, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
