#!/usr/bin/env python3
"""Measure actual ASS packet-key storage in balanced, fresh-process pairs."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PIPELINE = "Sources/IlliquidNativePlayback/Subtitles/SubtitlePipeline.swift"
HELPER = "Sources/IlliquidNativePlayback/Subtitles/ProcessedSubtitlePacketKey.swift"
TEST = "Tests/IlliquidNativePlaybackTests/ProcessedSubtitlePacketKeyTests.swift"
CASES = ("tiny", "text", "dense", "drawing", "duplicate", "long-prefix",
         "offset-input", "no-comma", "overallocated")
METRICS = {
    "retain": ("retained_allocator_delta_bytes", "released_allocator_delta_bytes"),
    "time": ("wall_nanoseconds", "cpu_nanoseconds"),
    "allocation": ("allocation_requests", "requested_bytes"),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def extract_baseline(source: str) -> str:
    """Keep the original fields and exact payload expression, with a new wrapper."""
    declarations = list(re.finditer(
        r"^    private struct ProcessedPacketKey: Hashable \{\n(?P<fields>.*?)^    \}",
        source, re.MULTILINE | re.DOTALL))
    if len(declarations) != 1:
        raise ValueError("Expected exactly one baseline ProcessedPacketKey declaration")
    fields = declarations[0].group("fields")
    expected = ("        let presentationMilliseconds: Int64\n"
                "        let durationMilliseconds: Int64\n"
                "        let data: Data\n")
    if fields != expected:
        raise ValueError("Baseline key fields changed; review the extraction")
    expression = ('data.firstIndex(of: UInt8(ascii: ",")).map {\n'
                  '                        Data(data[data.index(after: $0)...])\n'
                  '                    } ?? data')
    if source.count(expression) != 1 or source.count("let key = ProcessedPacketKey(") != 1:
        raise ValueError("Expected the unique original ASS payload normalization expression")
    construction = source.index("let key = ProcessedPacketKey(")
    expression_start = source.index(expression)
    construction_end = source.find("\n                )", construction)
    if not construction < expression_start < construction_end:
        raise ValueError("Payload expression is no longer inside the baseline key initializer")
    expression = re.sub(r"\bdata\b", "packetData", expression)
    expression = expression.replace("\n                        ", "\n            ")
    expression = expression.replace("\n                    ", "\n        ")
    fields = "\n".join(line[4:] for line in fields.rstrip("\n").splitlines())
    return ("import Foundation\n\nstruct ProcessedSubtitlePacketKey: Hashable {\n"
            + fields + "\n\n"
            "    init(presentationMilliseconds: Int64, durationMilliseconds: Int64, packetData: Data) {\n"
            "        self.presentationMilliseconds = presentationMilliseconds\n"
            "        self.durationMilliseconds = durationMilliseconds\n"
            "        self.data = " + expression + "\n    }\n}\n")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.counter = 0
        self.last_stderr = ""
        (output / "logs").mkdir()

    def run(self, arguments: list, label: str, *, timeout: int = 600,
            env_add: dict[str, str] | None = None) -> str:
        argv = [str(value) for value in arguments]
        self.counter += 1
        stem = f"{self.counter:04d}-{label}"
        stdout_path = self.output / "logs" / f"{stem}.stdout.log"
        stderr_path = self.output / "logs" / f"{stem}.stderr.log"
        env = os.environ.copy()
        # Timing and retained-memory processes must never inherit an interposer.
        env.pop("LD_PRELOAD", None)
        overrides = {
            "CLANG_MODULE_CACHE_PATH": str(self.output / "module-cache"),
            "SWIFT_MODULECACHE_PATH": str(self.output / "module-cache"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(self.output / "module-cache"),
            "TERM": "dumb", "NO_COLOR": "1",
        }
        overrides.update(env_add or {})
        env.update(overrides)
        started_utc = datetime.now(timezone.utc).isoformat()
        started = time.monotonic()
        timed_out = False
        try:
            result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, timeout=timeout)
            raw_stdout, raw_stderr, returncode = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            raw_stdout, raw_stderr, returncode = error.stdout or b"", error.stderr or b"", None
            timed_out = True
        stdout = raw_stdout.decode("utf-8", errors="replace")
        stderr = raw_stderr.decode("utf-8", errors="replace")
        self.last_stderr = stderr
        stdout_path.write_text(stdout)
        stderr_path.write_text(stderr)
        append(self.output / "commands.jsonl", {
            "argv": argv, "cwd": str(ROOT), "environment_overrides": overrides,
            "inherited_ld_preload_removed": "LD_PRELOAD" in os.environ,
            "started_utc": started_utc, "elapsed_seconds": time.monotonic() - started,
            "returncode": returncode, "timed_out": timed_out, "timeout_seconds": timeout,
            "stdout": str(stdout_path.relative_to(self.output)),
            "stderr": str(stderr_path.relative_to(self.output)),
        })
        if timed_out:
            raise TimeoutError(f"{label} exceeded {timeout}s; see {stderr_path}")
        if returncode:
            raise RuntimeError(f"{label} failed ({returncode}); see {stderr_path}\n{stderr[-3000:]}")
        return stdout


def swift_path(argument: str) -> Path:
    path = Path(argument).expanduser()
    if not path.is_file():
        located = shutil.which(argument)
        if located is None:
            raise ValueError(f"Swift executable not found: {argument}")
        path = Path(located)
    # Do not resolve symlinks: the shared Swift driver selects its mode by argv[0].
    path = path.absolute()
    if not path.with_name("swiftc").is_file():
        raise ValueError(f"No sibling swiftc for {path}")
    return path


def stage(output: Path, runner: Runner, baseline: str, aa_control: bool) -> dict:
    sources = output / "sources"
    (sources / "baseline").mkdir(parents=True)
    (sources / "candidate").mkdir()
    original = runner.run(["git", "show", f"{baseline}:{PIPELINE}"], "baseline-source").encode()
    (sources / "baseline" / "SubtitlePipeline.original.swift").write_bytes(original)
    baseline_helper = extract_baseline(original.decode()).encode()
    candidate_helper = (ROOT / HELPER).read_bytes()
    baseline_path = sources / "baseline" / "ProcessedSubtitlePacketKey.swift"
    candidate_path = sources / "candidate" / "ProcessedSubtitlePacketKey.swift"
    baseline_path.write_bytes(baseline_helper)
    candidate_path.write_bytes(baseline_helper if aa_control else candidate_helper)
    (sources / "CurrentProcessedSubtitlePacketKey.swift").write_bytes(candidate_helper)
    (sources / "ProcessedSubtitlePacketKeyTests.swift").write_bytes((ROOT / TEST).read_bytes())
    (sources / "run.py").write_bytes(Path(__file__).read_bytes())
    transformation = (
        "Extract the unique original nested ProcessedPacketKey fields; remove private and outer "
        "type nesting; rename to ProcessedSubtitlePacketKey. Extract its exact firstIndex/map "
        "normalization expression, rename its input data to packetData, and wrap it in an "
        "initializer with unchanged millisecond fields. No payload policy is changed."
    )
    return {
        "baseline": {
            "original_path": PIPELINE, "original_sha256": digest(original),
            "original_git_blob": runner.run(["git", "rev-parse", f"{baseline}:{PIPELINE}"],
                                             "baseline-blob").strip(),
            "staged_path": str(baseline_path.relative_to(output)),
            "staged_sha256": digest(baseline_helper), "transformation": transformation,
        },
        "candidate": {
            "original_path": PIPELINE if aa_control else HELPER,
            "original_sha256": digest(original if aa_control else candidate_helper),
            "staged_path": str(candidate_path.relative_to(output)),
            "staged_sha256": digest(candidate_path.read_bytes()),
            "transformation": transformation if aa_control else "none; exact current production helper",
            "aa_control": aa_control,
        },
        "current_helper_sha256": digest(candidate_helper),
        "test": {"original_path": TEST, "sha256": digest((sources / "ProcessedSubtitlePacketKeyTests.swift").read_bytes()),
                 "transformation": "none; exact current XCTest file"},
        "runner_sha256": digest((sources / "run.py").read_bytes()),
    }


def run_tests(output: Path, runner: Runner, swift: Path) -> dict:
    package = output / "test-package"
    source_dir = package / "Sources" / "IlliquidNativePlayback"
    test_dir = package / "Tests" / "IlliquidNativePlaybackTests"
    source_dir.mkdir(parents=True)
    test_dir.mkdir(parents=True)
    shutil.copyfile(output / "sources" / "CurrentProcessedSubtitlePacketKey.swift",
                    source_dir / "ProcessedSubtitlePacketKey.swift")
    shutil.copyfile(output / "sources" / "ProcessedSubtitlePacketKeyTests.swift",
                    test_dir / "ProcessedSubtitlePacketKeyTests.swift")
    package_source = '''// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "IlliquidNativePlayback",
    products: [.library(name: "IlliquidNativePlayback", targets: ["IlliquidNativePlayback"])],
    targets: [
        .target(name: "IlliquidNativePlayback"),
        .testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
'''
    (package / "Package.swift").write_text(package_source)
    results = {"status": "passed", "package_sha256": digest(package_source.encode()), "configurations": {}}
    for configuration in ("debug", "release"):
        print(f"Test actual packet-key source: {configuration}", flush=True)
        command = [swift, "test", "--package-path", package, "--configuration", configuration,
                   "--scratch-path", output / "build" / "tests", "--jobs", "2", "--no-parallel",
                   "--cache-path", output / "pm-cache", "--config-path", output / "pm-config",
                   "--security-path", output / "pm-security", "-Xswiftc", "-warnings-as-errors"]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        log = runner.run(command, f"tests-{configuration}") + runner.last_stderr
        counts = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log)
        if not counts or max(int(count) for count, _ in counts) == 0:
            raise ValueError(f"{configuration} command did not report executed XCTest cases")
        if any(int(failures) for _, failures in counts):
            raise ValueError(f"{configuration} XCTest failures were reported")
        results["configurations"][configuration] = {"executed_tests": max(int(count) for count, _ in counts)}
    # The exact inputs and command/test logs are retained. Test-only object and
    # index caches are not evidence and need not occupy space during measurements.
    shutil.rmtree(output / "build" / "tests")
    results["test_build_products_removed_after_success"] = True
    return results


def build(output: Path, runner: Runner, swift: Path, linux: bool) -> tuple[dict, dict]:
    harness_dir = output / "sources" / "harness"
    harness_dir.mkdir()
    required = ["Harness.swift", "HeapMetrics.c"] + (["AllocationMeter.c"] if linux else [])
    receipts = {}
    for filename in required:
        data = (HERE / filename).read_bytes()
        (harness_dir / filename).write_bytes(data)
        receipts[filename] = digest(data)
    build_dir = output / "build"
    build_dir.mkdir(exist_ok=True)
    cc = "/usr/bin/cc" if Path("/usr/bin/cc").is_file() else shutil.which("cc")
    if cc is None:
        raise ValueError("A C compiler is required for allocator/process metrics")
    receipts["c_compiler_version"] = runner.run([cc, "--version"], "c-version").strip()
    metrics = build_dir / "HeapMetrics.o"
    runner.run([cc, "-O2", "-c", harness_dir / "HeapMetrics.c", "-o", metrics], "build-heap-metrics")
    interposer = output / "libAllocationMeter.so"
    if linux:
        runner.run([cc, "-O2", "-shared", "-fPIC", harness_dir / "AllocationMeter.c",
                    "-ldl", "-o", interposer], "build-allocation-meter")
    binaries = {}
    common = [swift.with_name("swiftc"), "-O", "-whole-module-optimization", "-swift-version", "6",
              "-parse-as-library", "-module-cache-path", output / "module-cache"]
    for variant in ("baseline", "candidate"):
        print(f"Build isolated {variant} workload binaries", flush=True)
        directory = build_dir / variant
        directory.mkdir()
        helper = output / "sources" / variant / "ProcessedSubtitlePacketKey.swift"
        binaries[variant] = {}
        for kind in (("plain", "allocation") if linux else ("plain",)):
            binary = directory / kind
            metering = (["-D", "ALLOCATION_METER", "-L", output, "-lAllocationMeter",
                         "-Xlinker", "-rpath", "-Xlinker", output] if kind == "allocation" else [])
            runner.run(common + metering + [helper, harness_dir / "Harness.swift", metrics, "-o", binary],
                       f"build-{variant}-{kind}")
            binaries[variant][kind] = binary
    receipts["compiled_sha256"] = {
        str(path.relative_to(output)): digest(path.read_bytes())
        for path in [metrics, *([interposer] if linux else []),
                     *(path for entries in binaries.values() for path in entries.values())]
    }
    return binaries, receipts


def metric_summary(rows: list[dict], metric: str) -> dict:
    pairs: dict[int, dict[str, float]] = {}
    for row in rows:
        pairs.setdefault(row["pair"], {})[row["variant"]] = row[metric]
    if any(set(pair) != {"baseline", "candidate"} for pair in pairs.values()):
        raise ValueError("Incomplete pair in metric summary")
    baseline = [pairs[index]["baseline"] for index in sorted(pairs)]
    candidate = [pairs[index]["candidate"] for index in sorted(pairs)]
    differences = [b - a for a, b in zip(baseline, candidate)]
    changes = [100 * (b - a) / a for a, b in zip(baseline, candidate) if a > 0]
    a_median, b_median = statistics.median(baseline), statistics.median(candidate)
    return {
        "baseline_median": a_median, "candidate_median": b_median,
        "baseline_range": [min(baseline), max(baseline)],
        "candidate_range": [min(candidate), max(candidate)],
        "paired_differences": differences, "median_paired_difference": statistics.median(differences),
        "median_paired_change_percent": statistics.median(changes) if changes else None,
        "paired_change_percent_range": [min(changes), max(changes)] if changes else None,
        "pairs_with_positive_baseline": len(changes),
        "ratio_of_medians_change_percent": 100 * (b_median - a_median) / a_median if a_median > 0 else None,
        "candidate_higher_pairs": sum(b > a for a, b in zip(baseline, candidate)),
    }


def measure(args: argparse.Namespace, runner: Runner, binaries: dict, linux: bool) -> dict:
    groups = []
    total_rows = 0
    verified_pairs = 0
    for scenario in args.cases:
        for pipelines in (1, 2):
            for mode in (("retain", "time", "allocation") if linux else ("retain", "time")):
                iterations = args.iterations if mode == "time" else 1
                group_rows = []
                reference = None
                for pair in range(args.pairs):
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    paired = {}
                    for position, variant in enumerate(order):
                        kind = "allocation" if mode == "allocation" else "plain"
                        binary = binaries[variant][kind]
                        env_add = {"LD_PRELOAD": str(args.output / "libAllocationMeter.so")} if kind == "allocation" else None
                        stdout = runner.run([binary, mode, scenario, pipelines, args.count, iterations],
                                            f"{scenario}-{pipelines}-{mode}-{pair}-{variant}",
                                            timeout=300, env_add=env_add)
                        lines = [line for line in stdout.splitlines() if line.strip()]
                        if len(lines) != 1:
                            raise ValueError("Workload must emit exactly one JSON line")
                        result = json.loads(lines[0])
                        for field in ("unique_keys", "payload_checksum", *METRICS[mode]):
                            if field not in result:
                                raise ValueError(f"Workload omitted {field}: {scenario}/{mode}/{variant}")
                        identity = (result["unique_keys"], result["payload_checksum"])
                        paired[variant] = identity
                        row = {**result, "mode": mode, "scenario": scenario, "pipelines": pipelines,
                               "count": args.count, "iterations": iterations, "variant": variant,
                               "pair": pair, "position": position, "order": list(order),
                               "aa_control": args.aa_control,
                               "binary": str(binary.relative_to(args.output))}
                        append(args.output / "rows.jsonl", row)
                        group_rows.append(row)
                        total_rows += 1
                    if paired["baseline"] != paired["candidate"]:
                        raise ValueError(f"Semantic mismatch: {scenario}, {pipelines} pipelines, {mode}, pair {pair}")
                    if reference is not None and paired["baseline"] != reference:
                        raise ValueError(f"Nondeterministic semantic result: {scenario}/{pipelines}/{mode}")
                    reference = paired["baseline"]
                    verified_pairs += 1
                groups.append({
                    "scenario": scenario, "pipelines": pipelines, "mode": mode,
                    "count": args.count, "iterations": iterations, "pairs": args.pairs,
                    "unique_keys": reference[0], "payload_checksum": reference[1],
                    "metrics": {metric: metric_summary(group_rows, metric) for metric in METRICS[mode]},
                })
                print(f"Completed {scenario}: {pipelines} pipeline(s), {mode}, {args.pairs} pairs", flush=True)
    return {"schema": 1, "status": "complete", "rows": total_rows, "verified_pairs": verified_pairs,
            "all_semantic_pairs_match": True, "aa_control": args.aa_control,
            "difference_direction": "candidate minus baseline; negative means smaller",
            "normalization": "Raw metrics per invocation; count and iterations are recorded per group",
            "groups": groups}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--count", type=int, default=1_024)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--skip-tests", action="store_true",
                        help="Use only with separately retained, hash-matching correctness receipts")
    parser.add_argument("--aa-control", action="store_true",
                        help="Use baseline code in both slots; candidate ownership tests are explicitly skipped")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be a positive even integer (at least 2)")
    if args.count < 1 or args.iterations < 1:
        parser.error("--count and --iterations must be positive")
    if args.tests_only and (args.skip_tests or args.aa_control):
        parser.error("--tests-only cannot be combined with --skip-tests or --aa-control")
    args.cases = [value.strip() for value in args.cases.split(",")]
    if not args.cases or any(value not in CASES for value in args.cases) or len(set(args.cases)) != len(args.cases):
        parser.error("--cases must contain distinct supported case names: " + ",".join(CASES))
    if platform.system() not in ("Linux", "Darwin"):
        parser.error("Only Linux/glibc and macOS allocator metrics are supported")
    args.output = args.output.expanduser().resolve()
    if args.output.exists() and (not args.output.is_dir() or any(args.output.iterdir())):
        parser.error("--output must be a new or empty directory")
    swift = swift_path(args.swift)
    args.output.mkdir(parents=True, exist_ok=True)
    runner = Runner(args.output)
    baseline = runner.run(["git", "rev-parse", f"{args.baseline}^{{commit}}"], "baseline-commit").strip()
    manifest = {
        "schema": 1, "status": "running", "created_utc": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": baseline,
        "candidate_checkout_commit": runner.run(["git", "rev-parse", "HEAD"], "candidate-head").strip(),
        "candidate_worktree_status": runner.run(["git", "status", "--short"], "candidate-status"),
        "compiler": runner.run([swift, "--version"], "swift-version").strip(),
        "swift": str(swift), "swiftc": str(swift.with_name("swiftc")),
        "platform": platform.platform(), "machine": platform.machine(),
        "pairs": args.pairs, "count": args.count, "iterations": args.iterations,
        "cases": args.cases, "pipelines": [1, 2], "aa_control": args.aa_control,
        "tests_only": args.tests_only,
        "build_coordination": os.environ.get("ILLIQUID_BUILD_COORDINATION",
            "Serial isolated component builds; external Kyoto submission, if available, is recorded by the caller. No shared .build used."),
        "protocol": {
            "ordering": "AB for even pairs, BA for odd pairs; fresh process for every observation",
            "timing": "Optimized plain binary; allocation interposer absent",
            "allocation": "Linux-only separate ALLOCATION_METER binary with explicit LD_PRELOAD; not live memory",
            "memory": "Allocator deltas while keys are held and after release; not player RSS or GPU memory",
            "scope": "Exact ASS semantic-key source plus synthetic corpus; excludes libass, rendering and playback",
            "tests": "Exact production helper and XCTest source in a dependency-free temporary package",
        },
    }
    save(args.output / "manifest.json", manifest)
    try:
        manifest["sources"] = stage(args.output, runner, baseline, args.aa_control)
        save(args.output / "manifest.json", manifest)
        if args.aa_control or args.skip_tests:
            reason = ("A/A uses baseline in both slots; candidate ownership tests intentionally do not apply"
                      if args.aa_control else "Explicit --skip-tests; this run alone does not establish correctness")
            print("Tests skipped: " + reason, flush=True)
            manifest["tests"] = {"status": "skipped", "reason": reason}
        else:
            manifest["tests"] = run_tests(args.output, runner, swift)
        save(args.output / "manifest.json", manifest)
        if args.tests_only:
            summary = {"schema": 1, "status": "complete", "tests_only": True, "tests": manifest["tests"]}
        else:
            linux = platform.system() == "Linux"
            binaries, receipts = build(args.output, runner, swift, linux)
            manifest["build"] = receipts
            save(args.output / "manifest.json", manifest)
            summary = measure(args, runner, binaries, linux)
        save(args.output / "summary.json", summary)
        manifest["status"] = "complete"
        manifest["completed_utc"] = datetime.now(timezone.utc).isoformat()
        save(args.output / "manifest.json", manifest)
        print(f"Completed; evidence: {args.output}", flush=True)
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        save(args.output / "manifest.json", manifest)
        raise


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, TimeoutError, OSError) as error:
        sys.exit(str(error))
