#!/usr/bin/env python3
"""Native actual-source geometry attachment comparison; no external packages."""
import argparse
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

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
DECODER = "Sources/IlliquidNativePlayback/Media/VideoDecoder.swift"
HELPER = "Sources/IlliquidNativePlayback/Media/VideoGeometryMetadataCache.swift"
TESTS = ROOT / "Tests/IlliquidNativePlaybackTests/VideoGeometryMetadataCacheTests.swift"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--target-ms", type=float, default=150)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("Requires macOS and real CoreVideo; Linux substitutes are not supported")
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("--pairs must be even and >= 2; --target-ms must be positive")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Output directory must be empty or nonexistent")
    out.mkdir(parents=True, exist_ok=True)
    for name in ("logs", "sources", "build", "packages"):
        (out / name).mkdir()
    manifest = {"schema_version": 1, "baseline_commit": BASELINE,
                "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "host": platform.platform(), "machine": platform.machine(),
                "commands": [], "tests": [], "files": {}, "status": "running",
                "protocol": {"pairs": args.pairs, "target_ms": args.target_ms,
                             "max_estimated_sample_ms": 1500, "tests_only": args.tests_only,
                             "fresh_process_per_observation": True,
                             "timed_operation": "one aspect and one aperture application",
                             "excluded": ["buffer setup", "warmup", "output snapshot/checksum"]}}

    def command(argv, name, cwd=ROOT):
        result = subprocess.run([str(value) for value in argv], cwd=cwd,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = out / "logs" / (name + ".log")
        log.write_bytes(result.stdout)
        manifest["commands"].append({"argv": [str(value) for value in argv], "cwd": str(cwd),
                                     "exit_code": result.returncode, "log": str(log.relative_to(out)),
                                     "log_sha256": digest(result.stdout)})
        write_json(out / "manifest.json", manifest)
        if result.returncode:
            raise RuntimeError(f"{name} failed ({result.returncode}); see {log}\n"
                               + result.stdout.decode(errors="replace")[-6000:])
        return result.stdout

    def stage(name, data):
        path = out / "sources" / name
        path.write_bytes(data)
        manifest["files"][str(path.relative_to(out))] = digest(data)
        return path

    try:
        manifest["candidate_head"] = command(["git", "rev-parse", "HEAD"], "git-head").decode().strip()
        manifest["worktree_status"] = command(["git", "status", "--porcelain"], "git-status").decode()
        manifest["swift_version"] = command(["swift", "--version"], "swift-version").decode().strip()
        manifest["cpu"] = command(["sysctl", "-n", "machdep.cpu.brand_string"], "cpu").decode().strip()
        manifest["macos"] = command(["sw_vers"], "macos").decode().strip()
        sdk = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").decode().strip()
        target = platform.machine() + "-apple-macosx26.0"
        native_flags = ["-target", target, "-sdk", sdk]
        baseline_decoder = command(["git", "show", BASELINE + ":" + DECODER], "baseline-decoder")
        stage("baseline-VideoDecoder.swift", baseline_decoder)
        text = baseline_decoder.decode()
        methods = []
        for start, end in (("applyPixelAspectMetadata", "masteringDisplayPayload"),
                           ("applyCleanApertureMetadata", "contentLightPayload")):
            first = "    private func " + start + "("
            last = "    private func " + end + "("
            if text.count(first) != 1 or text.count(last) != 1:
                raise RuntimeError("Baseline method boundaries changed")
            method = text[text.index(first):text.index(last)]
            methods.append(method.replace("private func", "func", 1))
        baseline = ("import CoreVideo\nimport Foundation\n\nfinal class VideoGeometryMetadataCache {\n"
                    + "\n".join(methods) + "}\n").encode()
        production = ROOT / HELPER
        prototype = HERE / "VideoGeometryMetadataCache.swift"
        if production.exists() and prototype.exists() and production.read_bytes() != prototype.read_bytes():
            raise RuntimeError("Production helper and prototype diverge; remove or synchronize prototype")
        candidate_path = production if production.exists() else prototype
        candidate = candidate_path.read_bytes()
        manifest["candidate_source"] = str(candidate_path.relative_to(ROOT))
        tracked_inputs = {path: digest(path.read_bytes()) for path in
                          (candidate_path, TESTS, HERE / "Harness.swift", Path(__file__).resolve())}
        stage("candidate-VideoDecoder.swift", (ROOT / DECODER).read_bytes())
        variants = {"baseline": stage("baseline-VideoGeometryMetadataCache.swift", baseline),
                    "candidate": stage("candidate-VideoGeometryMetadataCache.swift", candidate)}
        test_source = stage("VideoGeometryMetadataCacheTests.swift", TESTS.read_bytes())
        harness_source = stage("Harness.swift", (HERE / "Harness.swift").read_bytes())
        stage("run.py", Path(__file__).read_bytes())
        executables = {}
        package_text = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "GeometryMetadata", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidNativePlayback"),
    .testTarget(name: "GeometryMetadataTests", dependencies: ["IlliquidNativePlayback"])
])
'''
        for variant, source in variants.items():
            package = out / "packages" / variant
            src = package / "Sources/IlliquidNativePlayback"
            tests = package / "Tests/GeometryMetadataTests"
            src.mkdir(parents=True)
            tests.mkdir(parents=True)
            (package / "Package.swift").write_text(package_text)
            shutil.copyfile(source, src / "VideoGeometryMetadataCache.swift")
            shutil.copyfile(test_source, tests / "VideoGeometryMetadataCacheTests.swift")
            for configuration in ("debug", "release"):
                log = command(["swift", "test", "--package-path", package, "-c", configuration,
                               "--jobs", "2", "--no-parallel", "-Xswiftc", "-warnings-as-errors"],
                              variant + "-" + configuration + "-tests").decode(errors="replace")
                counts = re.findall(r"Test run with (\d+) tests? (?:in \d+ suites? )?passed", log)
                if not counts or int(counts[-1]) == 0:
                    raise RuntimeError("No successful Swift Testing test count found")
                manifest["tests"].append({"variant": variant, "configuration": configuration,
                                          "passed": int(counts[-1])})
            build = out / "build" / variant
            build.mkdir()
            flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-warnings-as-errors"] + native_flags
            library = build / "libIlliquidNativePlayback.dylib"
            command(["swiftc", *flags, "-parse-as-library", "-enable-testing", "-module-name",
                     "IlliquidNativePlayback", "-emit-library", "-emit-module", "-emit-module-path",
                     build / "IlliquidNativePlayback.swiftmodule", source, "-o", library], variant + "-library")
            executable = build / "geometry-benchmark"
            command(["swiftc", *flags, "-parse-as-library", harness_source, "-I", build, "-L", build,
                     "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", build,
                     "-o", executable], variant + "-harness")
            executables[variant] = executable
            for path in (library, executable):
                manifest["files"][str(path.relative_to(out))] = digest(path.read_bytes())
        receipts = {}
        for variant, executable in executables.items():
            receipts[variant] = json.loads(command([executable, "outputs"], variant + "-outputs"))
            write_json(out / ("receipts-" + variant + ".json"), receipts[variant])
        if receipts["baseline"] != receipts["candidate"]:
            raise RuntimeError("Complete attachment output parity failed")
        manifest["output_parity"] = {"workloads": len(receipts["baseline"]),
                                     "steps_per_workload": 32, "matched": True}
        observations, calibrations, summary = [], [], []
        if not args.tests_only:
            cases = json.loads(command([executables["candidate"], "list"], "workload-list"))
            for case in cases:
                probes = {}
                for variant, executable in executables.items():
                    probe = json.loads(command([executable, "bench", case, "2048"], variant + "-calibrate-" + case))
                    probe["variant"] = variant
                    calibrations.append(probe)
                    probes[variant] = probe["elapsed_ns"] / probe["iterations"]
                count = max(1, min(int(args.target_ms * 1e6 / min(probes.values())),
                                   int(1500e6 / max(probes.values())), 5_000_000))
                paired = []
                for pair in range(args.pairs):
                    rows = {}
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    for position, variant in enumerate(order):
                        row = json.loads(command([executables[variant], "bench", case, str(count)],
                                                 f"{case}-pair-{pair}-{variant}"))
                        row.update(variant=variant, pair=pair, order=position)
                        observations.append(row)
                        rows[variant] = row
                    if rows["baseline"]["checksum"] != rows["candidate"]["checksum"]:
                        raise RuntimeError("Timed output checksum mismatch: " + case)
                    paired.append(rows)
                    write_json(out / "observations.json", observations)
                item = {"workload": case, "iterations_per_observation": count, "pairs": args.pairs}
                for metric in ("elapsed_ns", "cpu_ns"):
                    changes = [100 * (p["candidate"][metric] / p["baseline"][metric] - 1) for p in paired]
                    item[metric] = {"baseline_median_per_operation": statistics.median(p["baseline"][metric] / count for p in paired),
                                    "candidate_median_per_operation": statistics.median(p["candidate"][metric] / count for p in paired),
                                    "median_paired_change_percent": statistics.median(changes),
                                    "faster_pairs": sum(value < 0 for value in changes),
                                    "paired_changes_percent": changes}
                summary.append(item)
                print(json.dumps(item, sort_keys=True), flush=True)
                write_json(out / "summary.json", summary)
        write_json(out / "calibrations.json", calibrations)
        write_json(out / "observations.json", observations)
        write_json(out / "summary.json", summary)
        if any(digest(path.read_bytes()) != expected for path, expected in tracked_inputs.items()):
            raise RuntimeError("An input changed during qualification")
        manifest["status"] = "passed"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_json(out / "manifest.json", manifest)


if __name__ == "__main__":
    main()
