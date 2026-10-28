#!/usr/bin/env python3
"""Compare actual ring and bounded-queue transfers in serial fresh AB/BA processes."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import os
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
TARGET = "Sources/IlliquidNativePlayback/Playback/FixedRingBuffer.swift"
SOURCES = [TARGET, "Sources/IlliquidNativePlayback/Playback/PacketQueue.swift"]
TESTS = ["Tests/IlliquidNativePlaybackTests/" + name for name in
         ["PacketQueueWakeupTests.swift", "FixedRingBufferIndexTests.swift"]]
HARNESS = ["Benchmarks/RingIndexWrap/" + name for name in
           ["Driver.swift", "Kernel.swift", "run.py", "README.md"]]
VARIANTS = ("baseline", "candidate")
METRICS = ("wallNanoseconds", "cpuNanoseconds")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def workloads() -> list[dict]:
    return [dict(id=f"{kind}-{operation}-{payload}-{capacity}", kind=kind,
                 operation=operation, payload=payload, capacity=capacity,
                 primary=operation == "append" and capacity in [48, 64, 96, 192])
            for capacity in [3, 48, 64, 96, 97, 192]
            for payload in ["int", "reference"]
            for operation in ["append", "prepend"] for kind in ["ring", "queue"]]


class Run:
    def __init__(self, output: Path):
        self.output, self.number = output, 0
        (output / "logs").mkdir()

    def command(self, args: list, label: str) -> str:
        args = [str(a) for a in args]
        self.number += 1
        log = self.output / "logs" / f"{self.number:04d}-{label}.log"
        env = os.environ.copy()
        cache = str(self.output / "module-cache")
        env.update(CLANG_MODULE_CACHE_PATH=cache, SWIFT_MODULECACHE_PATH=cache,
                   SWIFTPM_MODULECACHE_OVERRIDE=cache)
        start = time.monotonic()
        result = subprocess.run(args, cwd=ROOT, capture_output=True, env=env, timeout=1200)
        log.write_bytes(result.stdout + result.stderr)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(dict(command=args, returncode=result.returncode,
                seconds=time.monotonic() - start, log=str(log.relative_to(self.output)))) + "\n")
        if result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}); {log}\n"
                               + result.stderr.decode(errors="replace")[-10000:])
        return result.stdout.decode().strip()


def stage(run: Run, manifest: dict, baseline: str, frozen: dict[str, bytes]) -> dict:
    original = {path: git("show", f"{baseline}:{path}") for path in SOURCES}
    differences = [path for path in SOURCES if original[path] != frozen[path]]
    if differences != [TARGET]:
        raise ValueError(f"Only {TARGET} may differ; found {differences}")
    packages = {}
    for variant in VARIANTS:
        package = run.output / "build" / variant
        packages[variant] = package
        manifest["sources"][variant] = {}
        for path in SOURCES:
            data = original[path] if variant == "baseline" else frozen[path]
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            manifest["sources"][variant][path] = digest(data)
        for path in TESTS:
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(frozen[path])
        (package / "Package.swift").write_text(
            '// swift-tools-version: 6.1\nimport PackageDescription\n'
            'let package = Package(name: "RingIndexWrapQualification", platforms: [.macOS("26.0")],\n'
            'targets: [.target(name: "IlliquidNativePlayback"),\n'
            '.testTarget(name: "IlliquidNativePlaybackTests", dependencies: ["IlliquidNativePlayback"])],\n'
            'swiftLanguageModes: [.v6])\n')
    return packages


def build(run: Run, packages: dict, swiftc: str, manifest: dict) -> dict:
    native = platform.system() == "Darwin"
    target = ["-target", f"{platform.machine()}-apple-macosx26.0"] if native else []
    if native:
        target += ["-sdk", run.command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk")]
    binaries = {}
    for variant, package in packages.items():
        directory = package / "measured"
        directory.mkdir()
        common = [swiftc, "-O", "-whole-module-optimization", "-swift-version", "6",
                  "-warnings-as-errors", "-parse-as-library", "-module-cache-path",
                  directory / "module-cache", *target]
        library = directory / ("libIlliquidNativePlayback" + (".dylib" if native else ".so"))
        kernel = run.output / "inputs/Benchmarks/RingIndexWrap/Kernel.swift"
        run.command([*common, "-enable-testing", "-emit-library", "-emit-module",
            "-module-name", "IlliquidNativePlayback", "-emit-module-path",
            directory / "IlliquidNativePlayback.swiftmodule",
            *[package / path for path in SOURCES], kernel, "-o", library], f"{variant}-library")
        binary = directory / "ring-index-benchmark"
        run.command([*common, "-I", directory, "-L", directory,
            "-Xlinker", "-rpath", "-Xlinker", directory, "-lIlliquidNativePlayback",
            run.output / "inputs/Benchmarks/RingIndexWrap/Driver.swift", "-o", binary], f"{variant}-driver")
        binaries[variant] = binary
        manifest["binaries"][variant] = {p.name: digest(p.read_bytes()) for p in [binary, library]}
    return binaries


def run_tests(run: Run, packages: dict, swift: str) -> list[dict]:
    receipts = []
    for variant, package in packages.items():
        for configuration in ["debug", "release"]:
            command = [swift, "test", "--package-path", package,
                "--scratch-path", package / "tests-build", "--cache-path", package / "cache",
                "--config-path", package / "config", "--security-path", package / "security",
                "--jobs", "2", "--configuration", configuration, "--no-parallel"]
            if platform.system() == "Linux":
                command.append("--use-integrated-swift-driver")
            run.command(command, f"tests-{variant}-{configuration}")
            receipts.append(dict(variant=variant, configuration=configuration, passed=True))
            save(run.output / "tests.json", receipts)
    return receipts


def summarize(rows: list[dict], cases: list[dict], pairs: int) -> list[dict]:
    results = []
    for case in cases:
        cell = [r for r in rows if r["workload"] == case["id"]]
        expected = {(v, p) for v in VARIANTS for p in range(pairs)}
        if len(cell) != len(expected) or {(r["variant"], r["pair"]) for r in cell} != expected:
            raise ValueError("Incomplete or duplicated measurement grid: " + case["id"])
        metrics = {}
        for name in METRICS:
            data = {v: [next(r[name] / r["transfers"] for r in cell
                            if r["variant"] == v and r["pair"] == p)
                        for p in range(pairs)] for v in VARIANTS}
            reductions = [100 * (1 - b / a) for a, b in zip(data["baseline"], data["candidate"])]
            metrics[name] = dict(
                baseline_median_ns=statistics.median(data["baseline"]),
                candidate_median_ns=statistics.median(data["candidate"]),
                paired_reduction_percent=reductions,
                paired_median_reduction_percent=statistics.median(reductions),
                faster_pairs=sum(r > 0 for r in reductions),
                baseline_range_ns=[min(data["baseline"]), max(data["baseline"])],
                candidate_range_ns=[min(data["candidate"]), max(data["candidate"])])
        results.append(dict(**case, pairs=pairs, metrics=metrics))
    return results


def measure(run: Run, binaries: dict, cases: list[dict], pairs: int, seconds: float) -> dict:
    semantics = run.output / "semantics"
    semantics.mkdir()
    rows, pilots, parity = [], [], []
    for case in cases:
        print("Measure " + case["id"], flush=True)
        arguments = [case[k] for k in ["kind", "operation", "payload", "capacity"]]
        outputs = {}
        for variant in VARIANTS:
            path = semantics / f"{case['id']}-{variant}.json"
            run.command([binaries[variant], "verify", *arguments, path], f"verify-{case['id']}-{variant}")
            outputs[variant] = path.read_bytes()
        if outputs["baseline"] != outputs["candidate"]:
            raise ValueError("Full model-output parity failed: " + case["id"])
        reference = outputs["baseline"]
        (semantics / f"{case['id']}.json.gz").write_bytes(gzip.compress(reference, mtime=0))
        for variant in VARIANTS:
            (semantics / f"{case['id']}-{variant}.json").unlink()
        parity.append(dict(workload=case["id"], sha256=digest(reference), bytes=len(reference), equal=True))
        estimates = []
        for variant in VARIANTS:
            iterations = 128
            for attempt in range(4):
                row = json.loads(run.command([binaries[variant], "measure", *arguments, iterations],
                    f"pilot-{case['id']}-{variant}-{attempt}"))
                pilots.append(dict(**row, workload=case["id"], variant=variant))
                elapsed = min(row[m] for m in METRICS)
                minimum = min(0.02, seconds / 4) * 1e9
                if elapsed >= minimum:
                    break
                iterations = min(2_000_000, max(iterations + 1, math.ceil(iterations * minimum / elapsed * 1.1)))
            estimates.append(min(row[m] for m in METRICS) / row["iterations"])
        iterations = min(2_000_000, max(1, math.ceil(seconds * 1e9 / min(estimates) * 1.1)))
        for pair in range(pairs):
            order = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
            receipts = []
            for variant in order:
                row = json.loads(run.command([binaries[variant], "measure", *arguments, iterations],
                    f"measure-{case['id']}-{pair}-{variant}"))
                if any(row[k] != case[k] for k in ["kind", "operation", "payload", "capacity"]):
                    raise ValueError("Measurement identity mismatch")
                if row["iterations"] != iterations or row["transfers"] != iterations * 256:
                    raise ValueError("Measurement denominator mismatch")
                if any(row[m] <= 0 for m in METRICS):
                    raise ValueError("Invalid timing receipt")
                receipts.append({k: row.get(k) for k in ["checksum", "remaining", "budget", "occupancy"]})
                row.update(workload=case["id"], variant=variant, pair=pair, order=list(order))
                rows.append(row)
                with (run.output / "measurements.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if receipts[0] != receipts[1]:
                raise ValueError("Timed checksum, final output or budget parity failed")
        save(run.output / "calibration.json", pilots)
        save(run.output / "verification.json", parity)
        save(run.output / "summary.json", summarize(rows, cases[:len(parity)], pairs))
    summary = summarize(rows, cases, pairs)
    consistency = math.ceil(7 * pairs / 8)
    gate = dict(
        primary_medians_pass=all(m["paired_median_reduction_percent"] >= (10 if s["kind"] == "ring" else 5)
            for s in summary if s["primary"] for m in s["metrics"].values()),
        primary_pair_consistency_pass=all(m["faster_pairs"] >= consistency
            for s in summary if s["primary"] for m in s["metrics"].values()),
        control_flags=[dict(workload=s["id"], metric=name, reduction_percent=m["paired_median_reduction_percent"])
            for s in summary if not s["primary"] for name, m in s["metrics"].items()
            if m["paired_median_reduction_percent"] < -10 and pairs - m["faster_pairs"] >= consistency],
        short_measurements=[dict(workload=r["workload"], variant=r["variant"], pair=r["pair"])
            for r in rows if min(r[m] for m in METRICS) < seconds * 0.8e9],
        pairs=pairs, workloads=len(cases), observations=len(rows))
    return gate


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--swift", default=shutil.which("swift") or "swift")
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--pairs", type=int)
    parser.add_argument("--target-seconds", type=float)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--run-tests", action="store_true")
    parser.add_argument("--enforce-performance", action="store_true")
    args = parser.parse_args()
    pairs = args.pairs if args.pairs is not None else (4 if args.quick else 8)
    seconds = args.target_seconds if args.target_seconds is not None else (0.05 if args.quick else 0.2)
    if pairs < 2 or pairs % 2 or not math.isfinite(seconds) or seconds <= 0:
        parser.error("Use an even positive pair count and finite positive duration")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output must be new and empty")
    swift = shutil.which(args.swift) or str(Path(args.swift).absolute())
    if not Path(swift).is_file():
        parser.error("Swift executable not found")
    run = Run(output)
    baseline = git("rev-parse", args.baseline + "^{commit}").decode().strip()
    frozen = {path: (ROOT / path).read_bytes() for path in [*SOURCES, *TESTS, *HARNESS]}
    for path, data in frozen.items():
        destination = output / "inputs" / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    cases = workloads()
    save(output / "workloads.json", cases)
    manifest = dict(schema=1, baseline_commit=baseline,
        candidate_head=git("rev-parse", "HEAD").decode().strip(),
        candidate_status=git("status", "--short").decode().splitlines(),
        compiler=run.command([swift, "--version"], "compiler"),
        platform=platform.platform(), machine=platform.machine(), cpu_count=os.cpu_count(),
        pairs=pairs, target_seconds=seconds, quick=args.quick,
        method="Matched complete production sources, identical concrete kernels, separate driver; serial fresh AB/BA",
        success="All production-capacity append/pop cases: >=10% ring and >=5% queue in CPU and wall, >=7/8 faster pairs; no repeatable >10% control regression",
        sources={}, binaries={}, tests={path: digest(frozen[path]) for path in TESTS},
        harnesses={path: digest(frozen[path]) for path in HARNESS})
    packages = stage(run, manifest, baseline, frozen)
    save(output / "manifest.json", manifest)
    binaries = build(run, packages, str(Path(swift).with_name("swiftc")), manifest)
    save(output / "manifest.json", manifest)
    tests = run_tests(run, packages, swift) if args.run_tests else []
    acceptance = measure(run, binaries, cases, pairs, seconds)
    acceptance["qualifying_cohort"] = platform.system() == "Darwin" and not args.quick and pairs >= 8 and len(tests) == 4
    acceptance["accepted"] = (acceptance["qualifying_cohort"] and acceptance["primary_medians_pass"]
        and acceptance["primary_pair_consistency_pass"] and not acceptance["control_flags"]
        and not acceptance["short_measurements"])
    save(output / "acceptance.json", acceptance)
    print(json.dumps(acceptance, indent=2), flush=True)
    if args.enforce_performance and not acceptance["accepted"]:
        raise SystemExit("Performance acceptance not met; inspect all retained results.")


if __name__ == "__main__":
    main()
