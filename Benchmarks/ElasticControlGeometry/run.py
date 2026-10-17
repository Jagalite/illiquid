#!/usr/bin/env python3
"""Reproduce control-bar geometry tests and balanced, fresh-process timings.

The geometry and existing tests are extracted verbatim at named declarations.
Only the original rawPoint body is substituted to reconstruct the baseline;
its complete geometry excerpt is checked against the pinned revision's hash.
On macOS paths use SwiftUI. Linux uses a documented point-collector stand-in.
"""
from __future__ import annotations

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
import time

from verify import verify

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GEOMETRY_PATH = Path("Sources/IlliquidApp/UI/ElasticPlaybackControlBar.swift")
SCENARIOS = [
    "straight_construction", "straight_hover", "rotated_hover", "straight_paths",
    "straight_tracking", "turned_construction", "turned_hover", "turned_paths",
    "curved_construction", "curved_hover", "curved_paths", "curved_tracking",
    "slight_hover",
]


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def save_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def excerpt(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError(f"Source boundary changed: {start!r} / {end!r}")
    return source[source.index(start):source.index(end)]


def command(args: list[str | Path], output: Path, timeout: int = 240) -> str:
    args = [str(arg) for arg in args]
    started = time.time()
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    with (output / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps({"command": args, "returncode": result.returncode,
                                 "elapsed_seconds": time.time() - started,
                                 "stdout": result.stdout, "stderr": result.stderr}) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    if result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def extract_sources(output: Path) -> tuple[str, str, dict[str, str]]:
    source = (ROOT / GEOMETRY_PATH).read_text()
    geometry = excerpt(source, "enum ElasticPlaybackControlBarSide:",
                       "\nstruct ElasticPlaybackControlBarShape:")
    candidate_body = excerpt(geometry, "    private func rawPoint(at s: CGFloat) -> CGPoint {",
                             "\n    func pointOnSurface(")
    baseline_body = (HERE / "baseline-raw-point.swift").read_text()
    baseline = geometry.replace(candidate_body, baseline_body, 1)
    expected = json.loads((HERE / "baseline.json").read_text())
    if sha256(baseline_body.encode()) != expected["raw_point_sha256"]:
        raise ValueError("Pinned original rawPoint fixture changed")
    if sha256(baseline.encode()) != expected["geometry_sha256"]:
        raise ValueError("Reconstructed baseline differs from the pinned production geometry")
    imports = "import Foundation\n#if canImport(SwiftUI)\nimport SwiftUI\n#endif\n\n"
    hashes = {str(GEOMETRY_PATH): sha256(source.encode()),
              "candidate_geometry": sha256(geometry.encode()),
              "baseline_geometry": sha256(baseline.encode())}
    return imports + geometry, imports + baseline, hashes


def build_tests(output: Path, variant: str, geometry: str) -> Path:
    package = output / f"tests-{variant}"
    sources = package / "Sources/IlliquidApp"
    tests = package / "Tests/IlliquidAppTests"
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    source = (ROOT / GEOMETRY_PATH).read_text()
    helpers = excerpt(source, "struct TimelineThumbnailPlacement {",
                      "\nprivate struct ElasticPlaybackControlBarSurface:")
    helpers += excerpt(source, "enum ElasticPlaybackUtility:",
                       "\nprivate enum ElasticPlaybackGestureMode:")
    sidebar = (ROOT / "Sources/IlliquidApp/UI/SourcesSidebar.swift").read_text()
    # These two pure sizing types are the final declarations in the source file.
    helpers += sidebar[sidebar.index("enum SourcesSidebarSizing {"):]
    (sources / "Geometry.swift").write_text(geometry + "\n" + helpers)
    shutil.copyfile(HERE / "PathSupport.swift", sources / "PathSupport.swift")
    chrome = (ROOT / "Tests/IlliquidAppTests/PlaybackChromeAndSidebarTests.swift").read_text()
    selected = excerpt(chrome, '@Suite("Elastic playback control bar placement")',
                       '@Suite("Sources sidebar mount policy")')
    (tests / "ExistingGeometryTests.swift").write_text(
        "import Foundation\nimport Testing\n@testable import IlliquidApp\n\n" + selected)
    for name in ["TimelineDesignRegressionTests.swift", "ElasticGeometryPerformanceRegressionTests.swift"]:
        shutil.copyfile(ROOT / "Tests/IlliquidAppTests" / name, tests / name)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ElasticGeometryTests", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidApp"),
    .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidApp"])
])
''')
    return package


def run(output: Path, tests_only: bool, rounds: int, iterations: int) -> None:
    if output.exists() and any(output.iterdir()):
        raise ValueError("Use a new empty output directory to preserve prior evidence")
    output.mkdir(parents=True, exist_ok=True)
    harness_hashes = {p.name: sha256(p.read_bytes()) for p in HERE.iterdir() if p.is_file()}
    candidate, baseline, source_hashes = extract_sources(output)
    environment = {
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": command(["swiftc", "--version"], output).strip(),
        "rounds": rounds, "iterations": iterations,
        "baseline": json.loads((HERE / "baseline.json").read_text()),
        "source_sha256": source_hashes,
        "method": "fresh process per scenario/variant; AB/BA order alternates by round; no parallel timing",
        "path_backend": "SwiftUI.Path" if platform.system() == "Darwin" else "Foundation point collector",
    }
    (output / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    for variant, content in [("baseline", baseline), ("candidate", candidate)]:
        (output / f"{variant}.swift").write_text(content)
        package = build_tests(output, variant, content)
        for configuration in ["debug", "release"]:
            print(f"Testing {variant} {configuration}", flush=True)
            log = command(["swift", "test", "--package-path", package, "--configuration",
                           configuration, "--jobs", "2"], output)
            (output / f"{variant}-{configuration}-tests.txt").write_text(log)
    renamed = baseline.replace("ElasticPlaybackControlBar", "BaselineElasticPlaybackControlBar")
    (output / "baseline-renamed.swift").write_text(renamed)
    swift_flags = ["-swift-version", "6", "-warnings-as-errors"]
    if platform.system() == "Darwin":
        swift_flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    for configuration, optimization in [("debug", ["-Onone", "-g"]),
                                         ("release", ["-O", "-whole-module-optimization"])]:
        binary = output / f"differential-{configuration}"
        command(["swiftc", *swift_flags, *optimization, "-parse-as-library",
                 output / "candidate.swift", output / "baseline-renamed.swift",
                 HERE / "PathSupport.swift", HERE / "Differential.swift", "-o", binary], output)
        print(f"Differential {configuration}", flush=True)
        result = json.loads(command([binary], output))
        (output / f"differential-{configuration}.json").write_text(json.dumps(result, indent=2) + "\n")
    binaries = {}
    if not tests_only:
        for variant in ["baseline", "candidate"]:
            binary = output / f"benchmark-{variant}"
            command(["swiftc", *swift_flags, "-O", "-whole-module-optimization", "-parse-as-library",
                     output / f"{variant}.swift", HERE / "PathSupport.swift",
                     HERE / "Benchmark.swift", "-o", binary], output)
            binaries[variant] = binary
        rows = []
        for round_index in range(rounds):
            order = ["baseline", "candidate"] if round_index % 2 == 0 else ["candidate", "baseline"]
            print(f"Timing round {round_index + 1}/{rounds}: {'/'.join(order)}", flush=True)
            for scenario in SCENARIOS:
                count = max(1, iterations // 10) if scenario.endswith("tracking") else iterations
                pair = []
                for order_index, variant in enumerate(order):
                    row = json.loads(command([binaries[variant], scenario, str(count)], output))
                    row.update(variant=variant, round=round_index, order=order_index)
                    rows.append(row)
                    pair.append(row)
                    with (output / "measurements.jsonl").open("a") as stream:
                        stream.write(json.dumps(row) + "\n")
                if not math.isclose(pair[0]["checksum"], pair[1]["checksum"], rel_tol=1e-9, abs_tol=1e-7):
                    raise ValueError(f"Timed output changed: {scenario}: {pair}")
        # Publish the complete observations together, then summarize the saved
        # file. Interrupted/partial append logs are never a completed receipt.
        temporary = output / "measurements.jsonl.tmp"
        with temporary.open("w") as stream:
            stream.write("".join(json.dumps(row) + "\n" for row in rows))
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(output / "measurements.jsonl")
        rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
        if len(rows) != len(SCENARIOS) * rounds * 2:
            raise ValueError("Incomplete measurement receipt")
        summary = []
        for scenario in SCENARIOS:
            values = {variant: [r["elapsed_ns"] / r["iterations"] / 1_000 for r in rows
                                if r["scenario"] == scenario and r["variant"] == variant]
                      for variant in binaries}
            before, after = [statistics.median(values[v]) for v in ["baseline", "candidate"]]
            summary.append({"scenario": scenario, "baseline_median_us": before,
                            "candidate_median_us": after, "speedup": before / after,
                            "reduction_percent": 100 * (1 - after / before),
                            "baseline_range_us": [min(values["baseline"]), max(values["baseline"])],
                            "candidate_range_us": [min(values["candidate"]), max(values["candidate"])]})
        save_json(output / "summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)
    if harness_hashes != {p.name: sha256(p.read_bytes()) for p in HERE.iterdir() if p.is_file()}:
        raise ValueError("Harness changed while validation was running")
    manifest = {"source_sha256": source_hashes,
                "harness_sha256": harness_hashes,
                "executables_sha256": {p.name: sha256(p.read_bytes())
                                       for p in [*binaries.values(), output / "differential-debug",
                                                 output / "differential-release"]},
                "generated_sources_sha256": {str(p.relative_to(output)): sha256(p.read_bytes())
                                             for p in output.rglob("*.swift") if ".build" not in p.parts}}
    save_json(output / "manifest.json", manifest)
    if not tests_only:
        save_json(output / "receipt-verification.json", verify(output))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tests-only", action="store_true")
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--iterations", type=int, default=1_000)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 100 or not 1 <= args.iterations <= 1_000_000:
        parser.error("rounds must be 1...100 and iterations 1...1,000,000")
    run(args.output.resolve(), args.tests_only, args.rounds, args.iterations)
