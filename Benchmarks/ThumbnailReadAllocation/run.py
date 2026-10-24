#!/usr/bin/env python3
"""Paired component comparison of the complete bounded thumbnail read function."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timezone

BASELINE = "4abf4b44f13386ccd04f1ce4ad0e756255ca4d14"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SOURCE = "Sources/IlliquidNativePlayback/Media/NativeThumbnailDiskCache.swift"
LIMIT = 16 * 1024 * 1024
SIZES = [0, 4096, 65535, 65536, 65537, 262144, 1048576, 5242880, LIMIT, LIMIT + 1]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def project(source: str) -> str:
    """Preserve the entire function; change only access and its outer type."""
    start_marker = "    private nonisolated static func readEncodedImage(at url: URL) -> Data? {"
    end_marker = "\n    private static func filenames("
    assert source.count(start_marker) == 1, "Production function anchor changed"
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    function = source[start:end].rstrip()
    assert function.endswith("}"), "Incomplete production function extraction"
    function = function.replace("private nonisolated static func", "public nonisolated static func", 1)
    constant = re.search(r"^    static let maximumEncodedImageBytes = (.+)$", source, re.M)
    assert constant and constant.group(1) == "16 * 1024 * 1024", "Review changed limit"
    return ("import Foundation\n\npublic enum NativeThumbnailDiskCache {\n"
            "    public static let maximumEncodedImageBytes = " + constant.group(1) + "\n"
            + function + "\n}\n")


class Runner:
    def __init__(self, output: Path):
        self.output = output
        self.commands = output / "commands.jsonl"
        self.counter = 0

    def run(self, args: list[str], label: str, env_add: dict[str, str] | None = None) -> str:
        self.counter += 1
        env = os.environ.copy()
        env.update(env_add or {})
        stem = f"{self.counter:04d}-{label}"
        result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True)
        stdout = self.output / "logs" / (stem + ".stdout.log")
        stderr = self.output / "logs" / (stem + ".stderr.log")
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        with self.commands.open("a") as stream:
            stream.write(json.dumps({"argv": args, "cwd": str(ROOT), "env_add": env_add or {},
                                     "returncode": result.returncode,
                                     "stdout": str(stdout.relative_to(self.output)),
                                     "stderr": str(stderr.relative_to(self.output))}, sort_keys=True) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}); see {stderr}\n{result.stderr[-4000:]}")
        return result.stdout


def fixtures(output: Path, source_directory: Path) -> list[dict]:
    directory = output / "fixtures"
    directory.mkdir()
    values = []
    block = bytes(range(256)) * 4096
    for size in SIZES:
        path = directory / f"bytes-{size}.bin"
        with path.open("wb") as stream:
            remaining = size
            while remaining:
                chunk = block[:min(remaining, len(block))]
                stream.write(chunk)
                remaining -= len(chunk)
        values.append({"name": f"bytes-{size}", "path": str(path), "bytes": size,
                       "kind": "deterministic raw bytes; bounded-reader stress, not JPEG decode",
                       "sha256": sha256(path.read_bytes()), "expected_rejected": size > LIMIT,
                       "expected_checksum_per_read": 1 if size > LIMIT else size + ((size - 1) % 256 if size else 0)})
    provenance = json.loads((source_directory / "Fixtures/provenance.json").read_text())
    for jpeg in provenance["fixtures"]:
        source = source_directory / "Fixtures" / jpeg["path"]
        data = source.read_bytes()
        assert len(data) == jpeg["bytes"] and sha256(data) == jpeg["sha256"]
        path = directory / source.name
        path.write_bytes(data)
        values.append({"name": source.stem, "path": str(path), "bytes": len(data),
                       "kind": "valid JPEG of deterministic high-detail RGB noise",
                       "sha256": sha256(data), "expected_rejected": False,
                       "expected_checksum_per_read": len(data) + data[-1],
                       "width": jpeg["width"], "height": jpeg["height"]})
    values.append({"name": "missing", "path": str(directory / "missing-file.jpg"), "bytes": -1,
                   "kind": "unavailable-file control", "sha256": None, "expected_rejected": True,
                   "expected_checksum_per_read": 1})
    return values


def metric_summary(observations: list[dict], key: str, per_read: bool) -> dict:
    def value(item: dict) -> float:
        return item[key] / item["iterations"] if per_read else item[key]
    by_pair: dict[int, dict[str, float]] = {}
    for item in observations:
        by_pair.setdefault(item["pair"], {})[item["variant"]] = value(item)
    baseline = [pair["baseline"] for pair in by_pair.values()]
    candidate = [pair["candidate"] for pair in by_pair.values()]
    differences = [b - a for a, b in zip(baseline, candidate)]
    percentages = [100 * (b - a) / a for a, b in zip(baseline, candidate) if a > 0]
    return {"baseline_median": statistics.median(baseline),
            "candidate_median": statistics.median(candidate),
            "candidate_minus_baseline_pair_differences": differences,
            "median_paired_difference": statistics.median(differences),
            "median_paired_change_percent": statistics.median(percentages) if percentages else None,
            "per_read": per_read}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--swiftc", default=shutil.which("swiftc") or "swiftc")
    args = parser.parse_args()
    assert args.pairs >= 2 and args.pairs % 2 == 0, "Use an even pair count >= 2 for balanced AB/BA order"
    assert platform.system() in ("Linux", "Darwin"), "Only Linux/glibc and macOS are supported"
    output = args.output.resolve()
    assert not output.exists() or not any(output.iterdir()), "Use an empty output directory"
    output.mkdir(parents=True, exist_ok=True)
    (output / "logs").mkdir()
    build = output / "build"
    build.mkdir()
    staged = build / "harness"
    staged.mkdir()
    # Compile frozen copies so another editor cannot change one variant midway
    # through this serial build. Retain those exact inputs with the evidence.
    harness_paths = [Path("Harness.swift"), Path("run.py"), Path("allocmeter.c"),
                     Path("CThumbnailReadMetrics/Metrics.c"), Path("CThumbnailReadMetrics/Metrics.h"),
                     Path("CThumbnailReadMetrics/module.modulemap"), Path("Fixtures/provenance.json"),
                     Path("Fixtures/noise-320x180.jpg"), Path("Fixtures/noise-640x360.jpg")]
    for relative in harness_paths:
        destination = staged / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / relative, destination)
    runner = Runner(output)
    # Preserve the swiftc symlink name: the shared swift-driver binary selects
    # its frontend mode from argv[0].
    swift = str(Path(args.swiftc).absolute()) if Path(args.swiftc).exists() else args.swiftc
    swift_version = runner.run([swift, "--version"], "swift-version").strip()
    head = runner.run(["git", "rev-parse", "HEAD"], "head").strip()
    status = runner.run(["git", "status", "--short"], "status")
    baseline_source = runner.run(["git", "show", f"{BASELINE}:{SOURCE}"], "baseline-source")
    candidate_source = (ROOT / SOURCE).read_text()
    assert baseline_source != candidate_source, "Candidate production source has not changed"
    cc = ["xcrun", "clang"] if platform.system() == "Darwin" else [shutil.which("cc") or "cc"]
    runner.run(cc + ["--version"], "c-version")
    metrics = staged / "CThumbnailReadMetrics"
    object_file = build / "Metrics.o"
    runner.run(cc + ["-O2", "-c", str(metrics / "Metrics.c"), "-o", str(object_file)], "build-metrics")
    linux = platform.system() == "Linux"
    interposer = build / "libthumbnail_allocmeter.so"
    if linux:
        runner.run(cc + ["-O2", "-shared", "-fPIC", str(staged / "allocmeter.c"), "-o", str(interposer)], "build-allocation-meter")
    source_receipts = {}
    binaries = {}
    compiled_paths = [object_file] + ([interposer] if linux else [])
    common = [swift, "-O", "-whole-module-optimization", "-swift-version", "6", "-parse-as-library",
              "-module-cache-path", str(build / "module-cache")]
    for variant, source in (("baseline", baseline_source), ("candidate", candidate_source)):
        directory = build / variant
        directory.mkdir()
        full = directory / "NativeThumbnailDiskCache.swift"
        full.write_text(source)
        extracted = directory / "Projection.swift"
        extracted.write_text(project(source))
        source_receipts[variant] = {"complete_source_sha256": sha256(source.encode()),
                                    "projection_sha256": sha256(extracted.read_bytes()),
                                    "complete_source": str(full.relative_to(output)),
                                    "projection": str(extracted.relative_to(output))}
        library = directory / ("libThumbnailReadProjection.dylib" if not linux else "libThumbnailReadProjection.so")
        runner.run(common + ["-emit-library", "-emit-module", "-module-name", "ThumbnailReadProjection",
                             "-emit-module-path", str(directory / "ThumbnailReadProjection.swiftmodule"),
                             str(extracted), "-o", str(library)], f"build-{variant}-projection")
        compiled_paths.append(library)
        link = ["-I", str(directory), "-I", str(metrics), "-L", str(directory), "-lThumbnailReadProjection",
                "-Xlinker", "-rpath", "-Xlinker", str(directory)]
        binaries[variant] = {}
        for kind in (["plain", "allocations"] if linux else ["plain"]):
            executable = directory / kind
            extra = (["-D", "ALLOCATIONS", "-L", str(build), "-lthumbnail_allocmeter", "-Xlinker", "-rpath", "-Xlinker", str(build)]
                     if kind == "allocations" else [])
            runner.run(common + link + extra + [str(staged / "Harness.swift"), str(object_file), "-o", str(executable)], f"build-{variant}-{kind}")
            binaries[variant][kind] = str(executable)
            compiled_paths.append(executable)
    inputs = fixtures(output, staged)
    manifest = {"schema": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
                "baseline_revision": BASELINE, "candidate_checkout_revision": head,
                "candidate_worktree_status": status, "platform": platform.platform(),
                "machine": platform.machine(), "swift_version": swift_version,
                "pairs": args.pairs, "source": SOURCE, "source_receipts": source_receipts,
                "harness_sha256": {str(relative): sha256((staged / relative).read_bytes()) for relative in harness_paths},
                "compiled_sha256": {str(path.relative_to(output)): sha256(path.read_bytes()) for path in compiled_paths},
                "fixtures": inputs,
                "build_coordination": os.environ.get("ILLIQUID_BUILD_COORDINATION", "Serial isolated component builds; any external Kyoto submission is recorded by the caller. No shared .build used."),
                "protocol": {"pair_order": "AB for even pairs, BA for odd pairs; fresh process for every observation",
                             "warm_up": "one same-input read, released before each measured phase",
                             "memory": "one held Data in out-of-line helper; release sampled after helper returns; samples precede full-byte verification",
                             "timing": "plain binary, no allocation interposer; wall and process CPU reported separately",
                             "allocation_traffic": "Linux/glibc only; successful intercepted malloc/calloc/realloc requests, excluding aligned and other APIs; separate binary and LD_PRELOAD counter; not live bytes or peak",
                             "scope": "complete bounded read function only; excludes ImageIO, full cache actor and player"}}
    write_json(output / "manifest.json", manifest)
    receipts = {}
    observations = []
    for fixture in inputs:
        receipts[fixture["name"]] = {}
        for variant in ("baseline", "candidate"):
            result = json.loads(runner.run([binaries[variant]["plain"], "verify", fixture["path"], str(fixture["bytes"]), "1"], f"verify-{fixture['name']}-{variant}"))
            receipts[fixture["name"]][variant] = result["receipt"]
        assert receipts[fixture["name"]]["baseline"] == receipts[fixture["name"]]["candidate"], fixture["name"]
    write_json(output / "receipts.json", receipts)
    modes = ["memory", "timing"] + (["allocations"] if linux else [])
    for fixture in inputs:
        for mode in modes:
            iterations = (1 if mode == "memory" else 10 if mode == "allocations" else
                          max(16, min(2048, math.ceil(128 * 1024 * 1024 / max(fixture["bytes"], 65536)))))
            for pair in range(args.pairs):
                order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
                for position, variant in enumerate(order):
                    kind = "allocations" if mode == "allocations" else "plain"
                    extra = {"LD_PRELOAD": str(interposer)} if mode == "allocations" else None
                    result = json.loads(runner.run([binaries[variant][kind], mode, fixture["path"], str(fixture["bytes"]), str(iterations)],
                                                  f"{fixture['name']}-{mode}-{pair}-{variant}", extra))
                    assert result["receipt"] == receipts[fixture["name"]]["baseline"], (fixture["name"], mode, pair)
                    if mode != "memory":
                        assert result["iterations"] == iterations
                        assert result["checksum"] == fixture["expected_checksum_per_read"] * iterations, (fixture["name"], mode, pair)
                    if mode == "allocations":
                        assert result["allocation_requests"] > 0, "Allocation counter did not observe the read path"
                    result.update(fixture=fixture["name"], variant=variant, pair=pair, position=position)
                    observations.append(result)
                    with (output / "observations.jsonl").open("a") as stream:
                        stream.write(json.dumps(result, sort_keys=True) + "\n")
            print(f"completed {fixture['name']} {mode}", flush=True)
    metrics_by_mode = {"memory": ["heap_held_delta_bytes", "heap_released_delta_bytes", "resident_held_delta_bytes", "resident_released_delta_bytes"],
                       "timing": ["wall_nanoseconds", "cpu_nanoseconds"],
                       "allocations": ["allocation_requests", "allocation_requested_bytes"]}
    summary = {"schema": 1, "pairs": args.pairs, "observations": len(observations),
               "all_receipts_match": True, "difference_direction": "candidate minus baseline; negative means smaller",
               "limitations": ["Component measurements; no player frame-rate, end-to-end latency or GPU claim.",
                               "Requested allocation bytes are cumulative traffic, not live, peak, or RSS.",
                               "Held and released allocator/RSS snapshots are not peak memory or physical footprint.",
                               "Raw large fixtures exercise the size bound; real JPEG controls are listed separately.",
                               "Repeated reads use a warm filesystem cache; concurrent file mutation is not induced."],
               "fixtures": {}}
    for fixture in inputs:
        modes_summary = {}
        for mode in modes:
            selected = [item for item in observations if item["fixture"] == fixture["name"] and item["mode"] == mode]
            modes_summary[mode] = {key: metric_summary(selected, key, mode != "memory") for key in metrics_by_mode[mode]}
        summary["fixtures"][fixture["name"]] = {"bytes": fixture["bytes"], "kind": fixture["kind"], "metrics": modes_summary}
    write_json(output / "summary.json", summary)
    print(json.dumps({"output": str(output), "observations": len(observations), "all_receipts_match": True}, sort_keys=True))


if __name__ == "__main__":
    main()
