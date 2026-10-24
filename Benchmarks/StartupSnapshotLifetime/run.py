#!/usr/bin/env python3
"""Qualify startup handoff ownership and measure obsolete saved-source retention."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
APP = "Sources/IlliquidApp/App/AppModel.swift"
LOADER = "Sources/IlliquidApp/App/ReadOnlyStartupLoader.swift"
SNAPSHOT = "Sources/IlliquidApp/App/SourceStartupSnapshot.swift"
CORE = "Sources/IlliquidCore/Utilities/NormalizedFileURL.swift"
LOADER_TEST = "Tests/IlliquidAppTests/ReadOnlyStartupLoaderTests.swift"
SNAPSHOT_TEST = "Tests/IlliquidAppTests/SourceStartupSnapshotTests.swift"
SCENARIOS = ("unchanged", "append-item", "remove-half", "remove-all", "replace-visibility")
START = "enum SourceFolderLibrary {"
END = "\nprivate struct PlaybackLifecycleObservation:"
PRELUDE = "import Foundation\nimport IlliquidCore\n\n"
PRODUCT = "StartupSnapshotProbe"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def extract_models(app: bytes) -> bytes:
    text = app.decode()
    if text.count(START) != 1 or text.count(END) != 1:
        raise RuntimeError("Production source-model boundaries changed; review the extraction")
    begin, end = text.index(START), text.index(END)
    if begin >= end:
        raise RuntimeError("Source-model boundaries are reversed")
    return (PRELUDE + text[begin:end]).encode()


def check_handoff(app: bytes) -> None:
    text = app.decode()
    begin = text.index("    static func loadShared() async -> AppModel? {")
    end = text.index("    static func handleStartupOpenURLs(", begin)
    handoff = text[begin:end]
    # The benchmark calls the same finish operation after adoption. Do not let
    # source extraction silently qualify a loader that the app never finishes.
    if handoff.count("historyStartup.finish()") != 1:
        raise RuntimeError("AppModel must finish its startup loader exactly once")
    publish = handoff.index("sharedInstance = model")
    finish = handoff.index("historyStartup.finish()")
    requests = handoff.index("let requests = pendingStartupOpenRequests")
    if not publish < finish < requests or "await " in handoff[publish:finish]:
        raise RuntimeError("Startup must finish synchronously after model publication")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.env = os.environ.copy()
        self.env.update(CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
                        SWIFT_MODULECACHE_PATH=str(output / "module-cache"),
                        SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
                        TERM="dumb", NO_COLOR="1")
        self.sequence = 0
        (output / "logs").mkdir()

    def run(self, arguments: list, label: str, timeout: int = 900) -> str:
        arguments = [str(a) for a in arguments]
        self.sequence += 1
        log = self.output / "logs" / f"{self.sequence:04d}-{label}.log"
        started = time.monotonic()
        result = subprocess.run(arguments, cwd=ROOT, env=self.env,
                                capture_output=True, text=True, timeout=timeout)
        log.write_text(result.stdout + result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"arguments": arguments, "returncode": result.returncode,
                                     "seconds": time.monotonic() - started,
                                     "log": str(log.relative_to(self.output))}, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed: {log}\n{result.stdout[-5000:]}\n{result.stderr[-5000:]}")
        # Swift Testing can write its successful completion to stderr.
        return result.stdout if label not in ("baseline-debug-tests", "baseline-release-tests",
                                             "candidate-debug-tests", "candidate-release-tests") else result.stdout + result.stderr


def package_manifest(baseline: bool) -> bytes:
    define = ', swiftSettings: [.define("BASELINE")]' if baseline else ""
    return f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "StartupSnapshotLifetime", platforms: [.macOS("26.0")],
    products: [.executable(name: "{PRODUCT}", targets: ["{PRODUCT}"])],
    targets: [
        .target(name: "CStartupHeap", publicHeadersPath: "include"),
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "{PRODUCT}", dependencies: ["IlliquidApp", "IlliquidCore", "CStartupHeap"]{define}),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp", "IlliquidCore"])
    ], swiftLanguageModes: [.v6])
'''.encode()


def stage(output: Path, variant: str, models: bytes) -> dict:
    frozen = variant == "baseline"
    package = output / "packages" / variant
    files = {
        "Package.swift": package_manifest(frozen),
        "Sources/IlliquidApp/ReadOnlyStartupLoader.swift":
            (HERE / "baseline/ReadOnlyStartupLoader.swift").read_bytes() if frozen else (ROOT / LOADER).read_bytes(),
        "Sources/IlliquidApp/SourceModels.swift": models,
        "Sources/IlliquidApp/SourceStartupSnapshot.swift": (ROOT / SNAPSHOT).read_bytes(),
        "Sources/IlliquidCore/NormalizedFileURL.swift": (ROOT / CORE).read_bytes(),
        f"Sources/{PRODUCT}/Driver.swift": (HERE / "Driver.swift").read_bytes(),
        "Sources/CStartupHeap/heap.c": (HERE / "CStartupHeap/heap.c").read_bytes(),
        "Sources/CStartupHeap/include/heap.h": (HERE / "CStartupHeap/include/heap.h").read_bytes(),
        "Tests/IlliquidAppTests/ReadOnlyStartupLoaderTests.swift":
            (HERE / "baseline/ReadOnlyStartupLoaderTests.swift").read_bytes() if frozen else (ROOT / LOADER_TEST).read_bytes(),
        "Tests/IlliquidAppTests/SourceStartupSnapshotTests.swift": (ROOT / SNAPSHOT_TEST).read_bytes(),
    }
    for name, data in files.items():
        path = package / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return {name: digest(data) for name, data in files.items()}


def swift_command(swift: str, output: Path, variant: str, operation: str, configuration: str) -> list:
    # Test instrumentation must not rebuild the binaries that supply evidence.
    scratch = output / "build" / variant / ("tests" if operation == "test" else "probe")
    command = [swift, operation, "--package-path", output / "packages" / variant,
               "--configuration", configuration, "--jobs", "2", "--scratch-path", scratch,
               "--cache-path", output / "package-cache", "--config-path", output / "package-config",
               "--security-path", output / "package-security", "-Xswiftc", "-warnings-as-errors"]
    if operation == "test":
        command.append("--no-parallel")
    if platform.system() == "Linux":
        command.append("--use-integrated-swift-driver")
    return command


def summarize(rows: list[dict], pairs: int, sizes: list[int]) -> dict:
    metrics = ["allocator_after_handoff_bytes", "allocator_after_mutation_bytes",
               "allocator_after_model_release_bytes", "allocator_after_cleanup_bytes",
               "retained_allocator_delta_bytes", "mutation_wall_nanoseconds", "mutation_cpu_nanoseconds"]
    results = []
    for size in sizes:
        for scenario in SCENARIOS:
            selected = [r for r in rows if r["scenario"] == scenario and r["count"] == size]
            by_pair = {(r["pair"], r["variant"]): r for r in selected}
            result = {"scenario": scenario, "saved_item_count": size, "pairs": pairs, "metrics": {}}
            for metric in metrics:
                if metric not in selected[0]:
                    continue
                before = [by_pair[p, "baseline"][metric] for p in range(pairs)]
                after = [by_pair[p, "candidate"][metric] for p in range(pairs)]
                differences = [a - b for a, b in zip(before, after)]
                reductions = [100 * (a - b) / a for a, b in zip(before, after) if a > 0]
                result["metrics"][metric] = {
                    "baseline_median": statistics.median(before),
                    "candidate_median": statistics.median(after),
                    "paired_median_saved": statistics.median(differences),
                    "paired_median_reduction_percent": statistics.median(reductions) if len(reductions) == pairs else None,
                    "paired_saved_range": [min(differences), max(differences)],
                    "pairs_lower": sum(b < a for a, b in zip(before, after)),
                }
            results.append(result)
    return {"pairs": pairs, "processes": len(rows), "all_state_pairs_byte_equal": True, "results": results}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", default=6, type=int)
    parser.add_argument("--sizes", default="1,32,1000,10000,100000")
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even integer >= 2 for balanced AB/BA sampling")
    sizes = [int(n) for n in args.sizes.split(",")]
    if len(set(sizes)) != len(sizes) or not sizes or any(n < 0 or n > 100_000 for n in sizes):
        parser.error("--sizes must be distinct saved-item counts from 0 to 100000")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    swift = shutil.which(os.environ.get("SWIFT", "swift"))
    if not swift:
        parser.error("Swift is unavailable; set SWIFT or add the toolchain to PATH")
    runner = Runner(output)
    app = (ROOT / APP).read_bytes()
    models = extract_models(app)
    check_handoff(app)
    frozen = json.loads((HERE / "baseline/manifest.json").read_text())
    if not args.tests_only:
        if frozen["revision"] != BASELINE:
            raise RuntimeError("Frozen baseline revision changed")
        for name, key in (("ReadOnlyStartupLoader.swift", "source_sha256"),
                          ("ReadOnlyStartupLoaderTests.swift", "test_sha256")):
            if digest((HERE / "baseline" / name).read_bytes()) != frozen[key]:
                raise RuntimeError(f"Frozen baseline hash mismatch: {name}")
        if digest(models) != frozen["support_extraction"]["sha256"]:
            raise RuntimeError("Shared source models differ from the baseline; requalify before measuring")
        for path, expected in frozen["shared_sources"].items():
            if digest((ROOT / path).read_bytes()) != expected:
                raise RuntimeError(f"Shared production dependency changed: {path}")
    variants = ("candidate",) if args.tests_only else ("baseline", "candidate")
    inputs = [ROOT / p for p in (APP, LOADER, SNAPSHOT, CORE, LOADER_TEST, SNAPSHOT_TEST)]
    inputs += [HERE / p for p in ("run.py", "Driver.swift", "CStartupHeap/heap.c", "CStartupHeap/include/heap.h",
                                  "baseline/manifest.json", "baseline/ReadOnlyStartupLoader.swift",
                                  "baseline/ReadOnlyStartupLoaderTests.swift")]
    manifest = {
        "schema_version": 1,
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "baseline": frozen,
        "candidate_head": runner.run(["git", "rev-parse", "HEAD"], "head").strip(),
        "candidate_status": runner.run(["git", "status", "--short", "--", APP, LOADER, LOADER_TEST,
                                         str(HERE.relative_to(ROOT))], "status").strip(),
        "inputs": {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in inputs},
        "environment": {"platform": platform.platform(), "machine": platform.machine(),
                        "swift": runner.run([swift, "--version"], "swift-version").strip(),
                        "swift_command": swift, "python": platform.python_version(),
                        "DEVELOPER_DIR": runner.env.get("DEVELOPER_DIR"),
                        "SWIFT_DETERMINISTIC_HASHING": runner.env.get("SWIFT_DETERMINISTIC_HASHING")},
        "method": {"pairs": args.pairs, "sizes": sizes, "scenarios": SCENARIOS,
                   "tests_only": args.tests_only,
                   "sampling": "separate fresh process per variant; balanced AB/BA; rotated workload order",
                   "scope": "live allocator bytes for a saved explicit-source snapshot and adopted value model; no native player, recursive scan index, RSS, GPU, or playback-FPS measurement",
                   "primary_metric": "allocator_after_mutation_bytes minus allocator_before_load_bytes",
                   "cleanup_metric": "diagnostic only: sampled after canonical state serialization, which may populate runtime caches",
                   "timing": "one mutation per process; includes object destruction when it occurs; descriptive, not a timing acceptance gate",
                   "parity": "canonical actual measured model JSON is compared byte-for-byte after primary memory sampling; payload SHA256/length are retained",
                   "extraction": "exact unchanged production source models plus imports; real loader/snapshot/normalizer; fixture model represents adoption without native player graph"},
    }
    save(output / "manifest.json", manifest)
    receipts, test_results, binaries = {}, {}, {}
    for variant in variants:
        print(f"Stage and test {variant}", flush=True)
        receipts[variant] = stage(output, variant, models)
        save(output / "source-receipts.json", receipts)
        test_results[variant] = {}
        for configuration in ("debug", "release"):
            text = runner.run(swift_command(swift, output, variant, "test", configuration),
                              f"{variant}-{configuration}-tests")
            counts = re.findall(r"Test run with (\d+) tests? .*passed", text)
            if not counts or int(counts[-1]) < (5 if variant == "baseline" else 10):
                raise RuntimeError(f"Missing expected test completion receipt: {variant}/{configuration}")
            test_results[variant][configuration] = {"passed": True, "tests": int(counts[-1])}
            save(output / "tests.json", test_results)
        if args.tests_only:
            continue
        command = swift_command(swift, output, variant, "build", "release")
        runner.run([*command, "--product", PRODUCT], f"{variant}-build")
        directory = runner.run([*command, "--show-bin-path"], f"{variant}-bin-path").strip()
        binaries[variant] = Path(directory) / PRODUCT
    if args.tests_only:
        save(output / "summary.json", {"tests_only": True, "tests": test_results, "app_handoff_verified": True})
        return
    binary_hashes = {variant: digest(p.read_bytes()) for variant, p in binaries.items()}
    save(output / "build-receipts.json", {variant: {"path": str(p.relative_to(output)),
                                                   "sha256": binary_hashes[variant]} for variant, p in binaries.items()})
    rows, verification = [], []
    workloads = [(scenario, n) for n in sizes for scenario in SCENARIOS]
    for pair in range(args.pairs):
        ordered = workloads[pair % len(workloads):] + workloads[:pair % len(workloads)]
        variants_order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        for scenario, count in ordered:
            observed, payloads = {}, {}
            for variant in variants_order:
                label = f"pair-{pair:02d}-{scenario}-{count}-{variant}"
                payload = output / f"{label}-state.json"
                row = json.loads(runner.run([binaries[variant], scenario, count, payload], label))
                if row.get("scenario") != scenario or row.get("saved_explicit_item_count") != count:
                    raise RuntimeError(f"Probe input receipt mismatch: {label}")
                for key in ("allocator_before_load_bytes", "allocator_after_mutation_bytes"):
                    if not isinstance(row.get(key), int) or row[key] <= 0:
                        raise RuntimeError(f"Invalid live allocator measurement: {label}/{key}")
                row["retained_allocator_delta_bytes"] = row["allocator_after_mutation_bytes"] - row["allocator_before_load_bytes"]
                row.update(variant=variant, pair=pair, count=count,
                           order=list(variants_order), sequence=len(rows))
                payloads[variant] = payload.read_bytes()
                row.update(state_sha256=digest(payloads[variant]), state_bytes=len(payloads[variant]))
                rows.append(row)
                observed[variant] = row
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if payloads["baseline"] != payloads["candidate"] or observed["baseline"]["checks"] != observed["candidate"]["checks"]:
                raise RuntimeError(f"Actual live model parity failed: {scenario}/{count}/pair-{pair}")
            verification.append({"pair": pair, "scenario": scenario, "count": count,
                                 "byte_equal": True, "state_sha256": observed["candidate"]["state_sha256"],
                                 "state_bytes": observed["candidate"]["state_bytes"],
                                 "checks": observed["candidate"]["checks"]})
            for variant in variants_order:
                (output / f"pair-{pair:02d}-{scenario}-{count}-{variant}-state.json").unlink()
        save(output / "verification.json", verification)
        save(output / "summary.json", summarize(rows, pair + 1, sizes))
        print(f"Completed paired memory sample {pair + 1}/{args.pairs}", flush=True)
    for variant, binary in binaries.items():
        if digest(binary.read_bytes()) != binary_hashes[variant]:
            raise RuntimeError(f"Measured binary changed: {variant}")
    for path, expected in manifest["inputs"].items():
        if digest((ROOT / path).read_bytes()) != expected:
            raise RuntimeError(f"Experiment source changed during measurement: {path}")
    print(json.dumps({"processes": len(rows), "byte_equal_pairs": len(verification),
                      "source_and_binary_hashes_verified": True}), flush=True)


if __name__ == "__main__":
    main()
