#!/usr/bin/env python3
"""Compare complete production history stores on macOS; never use user media."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
STORE = "Sources/IlliquidCore/Persistence/PlaybackPersistenceStore.swift"
CASES = [
    ("empty", 200), ("small-100", 100), ("progress-1000", 40),
    ("rich-1000", 20), ("deep-1000", 40), ("unicode-1000", 20),
    ("rich-10000", 4),
]
TESTS = [
    "PlaybackPersistenceStoreTests.swift", "DeferredPersistenceTests.swift",
    "IdempotentPersistenceTests.swift", "PlaybackHistoryScalingTests.swift",
    "HistoryPolicyTests.swift", "MediaContentVersionTests.swift",
    "PersistenceWriterTests.swift", "PersistenceWriterLifetimeTests.swift",
    "HistoryJSONEncodingTests.swift", "TestSupport/TemporaryDirectory.swift",
]
MANIFEST = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "HistoryJSONResearch", platforms: [.macOS("26.0")],
    targets: [
        .target(name: "IlliquidCore"),
        .executableTarget(name: "HistoryJSONBenchmark", dependencies: ["IlliquidCore"]),
        .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"]),
    ]
)
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def canonical(raw):
    value = json.loads(raw)
    value["completedFiles"] = sorted(value["completedFiles"])
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":")).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--swift", default=shutil.which("swift"))
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("This experiment compiles the full, unmodified macOS IlliquidCore target")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two")
    if not args.swift:
        parser.error("A Swift 6.1+ compiler is required")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("--output must be new or empty")
    evidence = out / "evidence"
    evidence.mkdir(parents=True)
    env = dict(os.environ)
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    for key in ("ILLIQUID_ENABLE_BENCHMARK_OVERRIDES", "ILLIQUID_BENCHMARK_NONDECODE"):
        env.pop(key, None)
    commands = []

    def run(command, label, timeout=300):
        command = list(map(str, command))
        started = time.time()
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=timeout)
        text = result.stdout + result.stderr
        log = evidence / "logs" / (label + ".log")
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(text)
        receipt = {
            "command": command, "label": label, "returncode": result.returncode,
            "elapsed_seconds": time.time() - started,
            "log_sha256": digest(text.encode()),
        }
        commands.append(receipt)
        with (evidence / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(receipt, sort_keys=True) + "\n")
        if result.returncode:
            print(text, flush=True)
            raise RuntimeError("Command failed: " + label)
        return result.stdout

    environment = {
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "architecture": platform.machine(),
        "python": sys.version, "cpu_count": os.cpu_count(),
        "swift": run([args.swift, "--version"], "swift-version").strip(),
        "macos": run(["sw_vers"], "macos-version").strip(),
        "xcode": run(["xcodebuild", "-version"], "xcode-version").strip(),
        "hardware": run(["sysctl", "-n", "hw.model"], "hardware").strip(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").strip(),
        "memory_bytes": int(run(["sysctl", "-n", "hw.memsize"], "memory")),
        "candidate_commit": run(["git", "rev-parse", "HEAD"], "candidate-commit").strip(),
        "baseline_commit": BASELINE,
        "git_status": run(["git", "status", "--porcelain"], "git-status").strip(),
        "deterministic_hashing": True, "pairs": args.pairs,
        "github_run_id": os.environ.get("GITHUB_RUN_ID"),
        "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    }
    dump(evidence / "environment.json", environment)
    print("ENVIRONMENT " + json.dumps(environment, sort_keys=True), flush=True)

    baseline_paths = run(
        ["git", "ls-tree", "-r", "--name-only", BASELINE, "Sources/IlliquidCore"],
        "baseline-files",
    ).splitlines()
    baseline_paths = [path for path in baseline_paths if path.endswith(".swift")]
    candidate_paths = sorted(str(path.relative_to(ROOT))
                             for path in (ROOT / "Sources/IlliquidCore").rglob("*.swift"))
    if sorted(baseline_paths) != candidate_paths:
        raise RuntimeError("Core source membership differs from the frozen baseline")
    sources = {"baseline": {}, "candidate": {}}
    executables = {}
    staged = []
    for variant in sources:
        package = out / variant
        target = package / "Sources/IlliquidCore"
        target.mkdir(parents=True)
        for path in baseline_paths:
            content = (subprocess.check_output(["git", "show", BASELINE + ":" + path], cwd=ROOT)
                       if variant == "baseline" else (ROOT / path).read_bytes())
            destination = target / pathlib.Path(path).relative_to("Sources/IlliquidCore")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            sources[variant][path] = digest(content)
            staged.append((destination, digest(content)))
        benchmark = package / "Sources/HistoryJSONBenchmark/Harness.swift"
        benchmark.parent.mkdir(parents=True)
        shutil.copyfile(HERE / "Harness.swift", benchmark)
        staged.append((benchmark, digest(benchmark.read_bytes())))
        tests = package / "Tests/IlliquidCoreTests"
        tests.mkdir(parents=True)
        for name in TESTS:
            shutil.copyfile(ROOT / "Tests/IlliquidCoreTests" / name, tests / pathlib.Path(name).name)
        (package / "Package.swift").write_text(MANIFEST)
        run([args.swift, "build", "--package-path", package, "-c", "release",
             "--product", "HistoryJSONBenchmark", "--jobs", "2",
             "-Xswiftc", "-warnings-as-errors"], variant + "-build", timeout=600)
        binary_dir = run(
            [args.swift, "build", "--package-path", package, "-c", "release",
             "--show-bin-path"], variant + "-binary-path"
        ).strip()
        executable = out / "binaries" / variant
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(pathlib.Path(binary_dir) / "HistoryJSONBenchmark", executable)
        executables[variant] = executable

    changed = [path for path in baseline_paths
               if sources["baseline"][path] != sources["candidate"][path]]
    if changed != [STORE]:
        raise RuntimeError("Only the history store may differ: " + repr(changed))
    source_manifest = {
        "baseline_commit": BASELINE, "candidate_commit": environment["candidate_commit"],
        "source_sha256": sources,
        "research_sha256": {path: digest((ROOT / path).read_bytes()) for path in [
            "Benchmarks/HistoryJSONEncoding/Harness.swift",
            "Benchmarks/HistoryJSONEncoding/run.py",
            "Tests/IlliquidCoreTests/HistoryJSONEncodingTests.swift",
        ]},
        "binary_sha256": {variant: digest(path.read_bytes()) for variant, path in executables.items()},
        "package_manifest": MANIFEST,
    }
    dump(evidence / "source-manifest.json", source_manifest)
    print("MANIFEST " + json.dumps(source_manifest, sort_keys=True), flush=True)

    expected = {}
    payloads = {}
    preflights = []
    temporary_json = out / "observation.json"

    def observe(variant, name, sink, iterations, label):
        stdout = run([executables[variant], name, sink, iterations, temporary_json], label)
        row = json.loads(stdout)
        if (row["writes"] != iterations or not row["fixture_verified"]
                or row["instrumentation_enabled"]):
            raise RuntimeError("Invalid observation: " + label)
        raw = temporary_json.read_bytes()
        if len(raw) != row["payload_bytes"]:
            raise RuntimeError("Payload receipt mismatch")
        value = canonical(raw)
        if name in expected and value != expected[name]:
            raise RuntimeError("Complete history differs: " + label)
        expected.setdefault(name, value)
        row["canonical_sha256"] = digest(value)
        row["raw_payload_sha256"] = digest(raw)
        key = (variant, name)
        identity = (row["payload_bytes"], row["slash_count"], row["canonical_sha256"])
        if key in payloads and payloads[key] != identity:
            raise RuntimeError("Payload changed across observations")
        payloads[key] = identity
        receipt = evidence / "fixtures" / (name + "-" + variant + ".json")
        if not receipt.exists():
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_bytes(raw)
        temporary_json.unlink()
        return row

    for name, iterations in CASES:
        for sink in ("memory", "defaults"):
            for variant in executables:
                row = observe(variant, name, sink, iterations,
                              "preflight-" + name + "-" + sink + "-" + variant)
                row["variant"] = variant
                preflights.append(row)
                print("PREFLIGHT " + json.dumps(row, sort_keys=True), flush=True)
        baseline_bytes, slash_count, _ = payloads[("baseline", name)]
        candidate_bytes, candidate_slashes, _ = payloads[("candidate", name)]
        if candidate_slashes != slash_count or baseline_bytes - candidate_bytes != slash_count:
            raise RuntimeError("Expected exactly one removed escape byte per slash")
    dump(evidence / "preflight.json", preflights)

    schedule = []
    if not args.verify_only:
        for pair in range(args.pairs):
            cases = CASES[pair % len(CASES):] + CASES[:pair % len(CASES)]
            sinks = ("memory", "defaults") if pair % 2 == 0 else ("defaults", "memory")
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for name, iterations in cases:
                for sink in sinks:
                    for position, variant in enumerate(order):
                        schedule.append({
                            "pair": pair, "workload": name, "iterations": iterations,
                            "sink": sink, "variant": variant, "process_order": position,
                        })
    dump(evidence / "schedule.json", schedule)
    observations = []
    for item in schedule:
        label = "pair-{pair}-{workload}-{sink}-{variant}".format(**item)
        row = observe(item["variant"], item["workload"], item["sink"], item["iterations"], label)
        row.update(item)
        observations.append(row)
        with (evidence / "observations.jsonl").open("a") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        print("OBSERVATION " + json.dumps(row, sort_keys=True), flush=True)

    summary = {"preflight_observations": len(preflights),
               "timed_observations": len(observations), "groups": []}
    for name, iterations in CASES:
        for sink in ("memory", "defaults"):
            group = {"workload": name, "sink": sink, "iterations": iterations}
            bbytes = payloads[("baseline", name)][0]
            cbytes = payloads[("candidate", name)][0]
            group.update(baseline_payload_bytes=bbytes, candidate_payload_bytes=cbytes,
                         payload_saved_bytes=bbytes-cbytes,
                         payload_reduction_pct=100*(1-cbytes/bbytes))
            if observations:
                rows = [row for row in observations
                        if row["workload"] == name and row["sink"] == sink]
                if len(rows) != 2 * args.pairs:
                    raise RuntimeError("Incomplete cohort")
                for variant in executables:
                    positions = [row["process_order"] for row in rows if row["variant"] == variant]
                    if positions.count(0) != args.pairs // 2 or positions.count(1) != args.pairs // 2:
                        raise RuntimeError("Unbalanced process order")
                for metric in ("wall_ns", "cpu_ns"):
                    values = {variant: [row[metric]/iterations for row in rows
                                        if row["variant"] == variant] for variant in executables}
                    paired = []
                    for pair in range(args.pairs):
                        by_variant = {row["variant"]: row[metric] for row in rows if row["pair"] == pair}
                        if set(by_variant) != set(executables):
                            raise RuntimeError("Incomplete pair")
                        paired.append(100*(1-by_variant["candidate"]/by_variant["baseline"]))
                    group[metric + "_per_write"] = {
                        variant: {"median": statistics.median(numbers),
                                  "min": min(numbers), "max": max(numbers)}
                        for variant, numbers in values.items()
                    }
                    group[metric + "_paired_reduction_pct"] = statistics.median(paired)
                    group[metric + "_paired_reductions_pct"] = paired
                    group[metric + "_faster_pairs"] = sum(value > 0 for value in paired)
            summary["groups"].append(group)

    # Build/test work cannot overlap the timing cohort. Both variants were built first.
    tests = []
    for configuration in ("debug", "release"):
        output = run([args.swift, "test", "--package-path", out / "candidate",
                      "-c", configuration, "--jobs", "2",
                      "-Xswiftc", "-warnings-as-errors"], configuration + "-tests", timeout=600)
        output = (evidence / "logs" / (configuration + "-tests.log")).read_text()
        if not re.search(r"Test run with [1-9][0-9]* tests? passed", output):
            raise RuntimeError("Swift Testing did not report a nonempty successful run")
        lines = [line for line in output.splitlines()
                 if "Executed " in line or "Test run with " in line]
        tests.append({"configuration": configuration, "result": "passed", "summary": lines})
        print("TEST_RESULT " + json.dumps(tests[-1], sort_keys=True), flush=True)
    run([args.swift, "test", "--package-path", out / "baseline", "-c", "release",
         "--jobs", "2", "-Xswiftc", "-warnings-as-errors",
         "--filter", "readsAndRewritesBothLegacySlashForms|roundTripsCompleteHistoryWithDifficultPathsAndMetadata"],
        "baseline-compatibility-tests", timeout=600)
    baseline_test_output = (evidence / "logs" / "baseline-compatibility-tests.log").read_text()
    required_methods = ("readsAndRewritesBothLegacySlashForms",
                        "roundTripsCompleteHistoryWithDifficultPathsAndMetadata")
    if (not re.search(r"Test run with [1-9][0-9]* tests? passed", baseline_test_output)
            or any(name not in baseline_test_output for name in required_methods)):
        raise RuntimeError("Baseline compatibility filter did not execute the required tests")
    baseline_test_lines = [line for line in baseline_test_output.splitlines()
                           if "Executed " in line or "Test run with " in line]
    tests.append({"configuration": "baseline-release-compatibility", "result": "passed",
                  "summary": baseline_test_lines})
    print("TEST_RESULT " + json.dumps(tests[-1], sort_keys=True), flush=True)
    dump(evidence / "tests.json", tests)

    for path, expected_digest in staged:
        if digest(path.read_bytes()) != expected_digest:
            raise RuntimeError("Staged source changed during experiment")
    for variant, path in executables.items():
        if digest(path.read_bytes()) != source_manifest["binary_sha256"][variant]:
            raise RuntimeError("Benchmark binary changed during experiment")
    if not args.verify_only:
        retained = [json.loads(line) for line in (evidence / "observations.jsonl").read_text().splitlines()]
        if retained != observations:
            raise RuntimeError("Retained observation log differs")
    summary["sources_and_binaries_unchanged"] = True
    summary["tests"] = tests
    dump(evidence / "summary.json", summary)
    print("SUMMARY " + json.dumps(summary, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
