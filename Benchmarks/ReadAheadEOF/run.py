#!/usr/bin/env python3
"""Qualify EOF read-ahead notifications using exact production sources."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_SHA256 = "0eb12da34194e55f47502f2bbb55649718c552d5128021228d9b81728c5973ee"
CASES = [("eof-update", 24), ("eof-update", 60), ("eof-update", 120),
         ("eof-idle", 120), ("timed-update", 120)]
METRICS = [
    "reader_cpu_nanoseconds", "reader_voluntary_switches",
    "reader_involuntary_switches", "process_cpu_nanoseconds",
    "process_voluntary_switches", "process_involuntary_switches",
    "elapsed_nanoseconds",
]
PACKAGE = """// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "ReadAheadEOFQualification",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ReadAheadBenchmark", targets: ["ReadAheadBenchmark"])],
    targets: [
        .target(name: "IlliquidNativePlayback",
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .target(name: "CReadAheadMetrics", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]),
        .executableTarget(name: "ReadAheadBenchmark",
                          dependencies: ["IlliquidNativePlayback", "CReadAheadMetrics"]),
        .testTarget(name: "IlliquidNativePlaybackTests",
                    dependencies: ["IlliquidNativePlayback"]),
    ],
    swiftLanguageModes: [.v6]
)
"""


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def append_json(path: Path, value: object) -> None:
    with path.open("a") as stream:
        stream.write(json.dumps(value, sort_keys=True) + "\n")


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--duration", type=float, default=3.0)
    parser.add_argument("--tests-only", action="store_true")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be an even count of at least two")
    if not math.isfinite(args.duration) or not 0 < args.duration <= 300:
        parser.error("--duration must be finite, greater than zero, and at most 300")

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    for name in ("logs", "cache", "module-cache", "tmp"):
        (output / name).mkdir()
    environment = os.environ.copy()
    environment.update(
        TMPDIR=str(output / "tmp"),
        CLANG_MODULE_CACHE_PATH=str(output / "module-cache"),
        SWIFTPM_MODULECACHE_OVERRIDE=str(output / "module-cache"),
    )
    commands: list[dict] = []
    observations: list[dict] = []
    checks: dict[Path, str] = {}
    manifest = {
        "started_utc": utc_now(),
        "host": {
            "system": platform.system(), "release": platform.release(),
            "machine": platform.machine(), "python": platform.python_version(),
            "reader_context_switches_supported": sys.platform.startswith("linux"),
            "allowed_cpus": sorted(os.sched_getaffinity(0))
                if hasattr(os, "sched_getaffinity") else None,
        },
        "pairs": args.pairs, "duration_seconds": args.duration,
        "tests_only": args.tests_only, "baseline_commit": BASELINE_COMMIT,
        "baseline_sha256": BASELINE_SHA256,
        "cases": [{"scenario": name, "rate": rate} for name, rate in CASES],
        "tests": [], "binaries": {},
    }
    write_json(output / "completion.json", {"status": "running"})

    def execute(argv: list[str], label: str, timeout=600, check=True) -> str:
        log = output / "logs" / f"{len(commands):03d}-{label}.log"
        started, started_utc = time.monotonic(), utc_now()
        error, returncode, text = None, None, ""
        try:
            process = subprocess.run(
                argv, cwd=ROOT, env=environment, text=True, errors="replace",
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
            )
            returncode, text = process.returncode, process.stdout
        except (OSError, subprocess.TimeoutExpired) as exception:
            error = str(exception)
            text = getattr(exception, "stdout", "") or ""
            if isinstance(text, bytes):
                text = text.decode("utf-8", errors="replace")
            text += "\n" + error + "\n"
        log.write_text(text)
        record = {
            "argv": argv, "cwd": str(ROOT), "started_utc": started_utc,
            "elapsed_seconds": time.monotonic() - started,
            "returncode": returncode, "error": error,
            "log": str(log.relative_to(output)),
        }
        commands.append(record)
        append_json(output / "commands.jsonl", record)
        if check and (error is not None or returncode != 0):
            raise RuntimeError(f"{label} failed; see {log}\n{text[-6000:]}")
        return text

    def validate(row: dict, scenario: str, rate: int) -> None:
        ticks = max(1, math.ceil(rate * args.duration))
        position = 0.0 if scenario == "eof-idle" else ticks / rate
        if type(row.get("ticks")) is not int or row["ticks"] != ticks:
            raise ValueError(f"Unexpected tick count: {row}")
        actual = row.get("final_position")
        if (type(actual) not in (int, float) or not math.isfinite(actual)
                or not math.isclose(actual, position, rel_tol=1e-12, abs_tol=1e-12)):
            raise ValueError(f"Unexpected final position: {row}")
        if row.get("admitted") is not (scenario == "timed-update"):
            raise ValueError(f"Unexpected admission result: {row}")
        for name in METRICS:
            if name not in row:
                raise ValueError(f"Missing metric {name}")
            value = row[name]
            if (value is None and name.startswith("reader_") and name.endswith("_switches")
                    and not sys.platform.startswith("linux")):
                continue
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError(f"Invalid metric {name}: {value!r}")

    def summarize() -> dict:
        result = {"observations": len(observations), "cases": {}}
        for scenario, rate in CASES:
            key = f"{scenario}/{rate}Hz"
            rows = [row for row in observations if row["case"] == key]
            if not rows:
                continue
            entry = {}
            for metric in METRICS:
                stats = {}
                for variant in ("baseline", "candidate"):
                    values = [row["data"][metric] for row in rows
                              if row["variant"] == variant and row["data"][metric] is not None]
                    stats[variant] = (
                        {"samples": len(values), "median": statistics.median(values),
                         "minimum": min(values), "maximum": max(values)} if values else None
                    )
                baseline, candidate = stats["baseline"], stats["candidate"]
                stats["reduction_between_medians_percent"] = (
                    100 * (1 - candidate["median"] / baseline["median"])
                    if baseline and candidate and baseline["median"] > 0 else None
                )
                entry[metric] = stats
            result["cases"][key] = entry
        return result

    try:
        swift_name = shutil.which(args.swift)
        if swift_name is None:
            raise RuntimeError(f"Swift executable not found: {args.swift}")
        # Preserve argv[0] as swift: resolving its swift-driver symlink changes dispatch.
        swift = Path(swift_name).absolute()
        checks[swift] = digest(swift)
        manifest["compiler"] = {
            "path": str(swift), "sha256": checks[swift],
            "version": execute([str(swift), "--version"], "swift-version").strip(),
        }
        manifest["git_head"] = execute(["git", "rev-parse", "HEAD"], "git-head", check=False).strip()
        manifest["git_status"] = execute(["git", "status", "--short"], "git-status", check=False)
        common = {
            "Sources/ReadAheadBenchmark/Harness.swift": HERE / "Harness.swift",
            "Sources/CReadAheadMetrics/CReadAheadMetrics.c":
                HERE / "CReadAheadMetrics/CReadAheadMetrics.c",
            "Sources/CReadAheadMetrics/include/CReadAheadMetrics.h":
                HERE / "CReadAheadMetrics/include/CReadAheadMetrics.h",
            "Tests/IlliquidNativePlaybackTests/MediaReadAheadGateTests.swift":
                ROOT / "Tests/IlliquidNativePlaybackTests/MediaReadAheadGateTests.swift",
        }
        variants = {
            "baseline": HERE / "baseline/MediaReadAheadGate.swift",
            "candidate": ROOT / "Sources/IlliquidNativePlayback/Media/MediaReadAheadGate.swift",
        }
        inputs = set(common.values()) | set(variants.values()) | {Path(__file__).resolve()}
        snapshots = {path: path.read_bytes() for path in inputs}
        checks.update({path: hashlib.sha256(raw).hexdigest() for path, raw in snapshots.items()})
        if checks[variants["baseline"]] != BASELINE_SHA256:
            raise ValueError("Frozen baseline SHA-256 does not match")
        manifest["inputs"] = {str(path.relative_to(ROOT)): checks[path] for path in inputs}
        manifest["staged"] = {}
        packages, binaries = {}, {}
        for variant, gate in variants.items():
            package = output / "packages" / variant
            package.mkdir(parents=True)
            staged = dict(common)
            staged["Sources/IlliquidNativePlayback/MediaReadAheadGate.swift"] = gate
            for relative, source in staged.items():
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(snapshots[source])
                checks[destination] = checks[source]
            (package / "Package.swift").write_text(PACKAGE)
            checks[package / "Package.swift"] = digest(package / "Package.swift")
            manifest["staged"][variant] = {
                str(path.relative_to(package)): value
                for path, value in checks.items() if package in path.parents
            }
            packages[variant] = package
        write_json(output / "manifest.json", manifest)

        for variant, package in packages.items():
            options = [
                "--package-path", str(package), "--scratch-path", str(output / "build" / variant),
                "--cache-path", str(output / "cache"), "--jobs", "2",
                "-Xswiftc", "-warnings-as-errors", "-Xswiftc", "-module-cache-path",
                "-Xswiftc", str(output / "module-cache"),
            ]
            for configuration in ("debug", "release"):
                label = f"{variant}-{configuration}-tests"
                print(label, flush=True)
                execute([str(swift), "test", *options, "-c", configuration, "--no-parallel"], label)
                manifest["tests"].append({
                    "variant": variant, "configuration": configuration, "status": "passed"
                })
                write_json(output / "manifest.json", manifest)
            if not args.tests_only:
                execute([str(swift), "build", *options, "-c", "release", "--product",
                         "ReadAheadBenchmark"], f"{variant}-release-build")
                bin_directory = execute(
                    [str(swift), "build", *options, "-c", "release", "--show-bin-path"],
                    f"{variant}-binary-path",
                ).strip().splitlines()[-1]
                binary = Path(bin_directory) / "ReadAheadBenchmark"
                binaries[variant] = binary
                checks[binary] = digest(binary)
                manifest["binaries"][variant] = {
                    "path": str(binary.relative_to(output)), "sha256": checks[binary]
                }
                write_json(output / "manifest.json", manifest)

        if not args.tests_only:
            for scenario, rate in CASES:
                key = f"{scenario}/{rate}Hz"
                for pair in range(args.pairs):
                    order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                    paired = {}
                    for slot, variant in enumerate(order):
                        text = execute(
                            [str(binaries[variant]), scenario, str(rate), str(args.duration)],
                            f"{scenario}-{rate}-pair-{pair + 1}-{variant}",
                            timeout=max(30, args.duration + 15),
                        )
                        row = json.loads(text.strip().splitlines()[-1])
                        observation = {
                            "case": key, "pair": pair + 1, "slot": slot + 1,
                            "variant": variant, "data": row,
                        }
                        observations.append(observation)
                        append_json(output / "observations.jsonl", observation)
                        validate(row, scenario, rate)
                        paired[variant] = row
                    for field in ("ticks", "final_position", "admitted"):
                        if paired["baseline"][field] != paired["candidate"][field]:
                            raise ValueError(f"Pair semantic mismatch: {key}: {field}")
                    write_json(output / "summary.json", summarize())
                    print(f"{key}: pair {pair + 1}/{args.pairs} passed", flush=True)

        for path, expected in checks.items():
            if digest(path) != expected:
                raise ValueError(f"Input, staged source, compiler or binary changed: {path}")
        write_json(output / "summary.json", summarize())
        write_json(output / "completion.json", {
            "status": "passed", "finished_utc": utc_now(), "tests_only": args.tests_only,
            "test_runs": len(manifest["tests"]), "observations": len(observations),
            "source_integrity_verified": True,
        })
        print(f"Qualification complete: {output}", flush=True)
        return 0
    except BaseException as error:
        write_json(output / "manifest.json", manifest)
        write_json(output / "completion.json", {
            "status": "failed", "finished_utc": utc_now(),
            "error": f"{type(error).__name__}: {error}",
            "test_runs": len(manifest["tests"]), "observations": len(observations),
        })
        print(f"Qualification failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
