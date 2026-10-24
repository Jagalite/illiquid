#!/usr/bin/env python3
"""Measure one real subtitle conversion per fresh process, with exact byte parity.

Run serially on an idle host. Peak RSS includes runtime startup and input loading;
the Swift driver captures it before writing the output or serializing results.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
VARIANTS = ("baseline", "candidate")
LIMIT = 32 * 1024 * 1024
COUNTS = {"2000": 2_000, "50000": 50_000, "200000": 200_000,
          "long-payload": 2_000, "unicode-long-payload": 2_000,
          "crlf": 50_000, "malformed": 50_000, "blank-heavy": 1}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def exact_file_equal(left: Path, right: Path) -> bool:
    with left.open("rb") as a, right.open("rb") as b:
        while True:
            first, second = a.read(64 * 1024), b.read(64 * 1024)
            if first != second:
                return False
            if not first:
                return True


def run(command: list[str], output: Path, log: Path) -> str:
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(output / "module-cache"))
    result = subprocess.run(command, capture_output=True, text=True, env=env, cwd=ROOT)
    log.write_text(json.dumps(command) + "\n" + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{result.stderr[-3000:]}")
    return result.stdout


def fixtures(cases: list[str], output: Path) -> dict:
    folder = output / "fixtures"
    folder.mkdir()
    manifest = {}
    for name in cases:
        format_name, kind = name.split("-", 1)
        path = folder / f"{name}.{format_name}"
        newline = "\r\n" if kind == "crlf" else "\n"
        decimal = "," if format_name == "srt" else "."
        with path.open("wb") as stream:
            if format_name == "vtt":
                stream.write(("WEBVTT" + newline * 2).encode())
            if kind == "blank-heavy":
                for _ in range(32):
                    stream.write(b"\n" * (64 * 1024))
            for index in range(COUNTS[kind]):
                seconds = index * 2
                start = f"{seconds // 3600:02}:{seconds // 60 % 60:02}:{seconds % 60:02}{decimal}000"
                end = f"{seconds // 3600:02}:{seconds // 60 % 60:02}:{seconds % 60 + 1:02}{decimal}000"
                timing = f"{start} --> {end}" if kind != "malformed" else "invalid --> invalid"
                text = "Plain caption " + str(index)
                if kind == "long-payload":
                    text += " " + "payload " * 1024
                elif kind == "unicode-long-payload":
                    atom = "字幕 e\u0301 👾 {\\move} "
                    text += " " + atom * (8192 // len(atom.encode("utf-8")))
                block = f"{index + 1}{newline}{timing}{newline}{text}{newline}{newline}"
                stream.write(block.encode("utf-8"))
        size = path.stat().st_size
        if size > LIMIT:
            raise ValueError(f"Input exceeds production 32 MiB bound: {name}")
        manifest[name] = {"format": format_name, "cues": COUNTS[kind], "kind": kind,
                          "input_bytes": size, "input_sha256": file_sha(path),
                          "file": str(path.relative_to(output)),
                          "expected_error": f"noValidCues({'srt' if format_name == 'srt' else 'webVTT'})"
                          if kind == "malformed" else None}
    write_json(output / "fixtures.json", manifest)
    return manifest


def build(args: argparse.Namespace, output: Path) -> dict[str, Path]:
    pinned = json.loads((HERE / "baseline/manifest.json").read_text())
    baseline = (HERE / "baseline/ExternalTextSubtitleConverter.swift").read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(baseline)).encode() + b"\0" + baseline).hexdigest()
    if sha(baseline) != pinned["sha256"] or blob != pinned["git_blob"]:
        raise ValueError("Frozen baseline differs from manifest")
    compiler = os.path.abspath(shutil.which(args.swiftc) or args.swiftc)
    version = run([compiler, "--version"], output, output / "compiler.log").strip()
    flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-warnings-as-errors",
             "-module-cache-path", str(output / "module-cache")]
    if platform.system() == "Darwin":
        # Direct swiftc invocations do not inherit SwiftPM's SDK selection.
        # Use the SDK belonging to the selected Xcode (DEVELOPER_DIR).
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                  output, output / "sdk.log").strip()
        flags += ["-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0"]
    manifest = {"created_utc": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
                "machine": platform.machine(), "compiler": version, "compiler_path": compiler,
                "compiler_sha256": file_sha(Path(compiler)), "flags": flags,
                "runner_sha256": file_sha(Path(__file__)), "driver_sha256": file_sha(HERE / "Driver.swift"),
                "baseline": pinned, "variants": {},
                "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None}
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    shutil.copyfile(HERE / "Driver.swift", output / "Driver.swift")
    binaries = {}
    for variant in VARIANTS:
        folder = output / variant
        folder.mkdir()
        original = HERE / "baseline/ExternalTextSubtitleConverter.swift" if variant == "baseline" else SOURCE
        source = folder / "ExternalTextSubtitleConverter.swift"
        shutil.copyfile(original, source)
        library = folder / ("libIlliquidNativePlayback." + ("dylib" if platform.system() == "Darwin" else "so"))
        module = folder / "IlliquidNativePlayback.swiftmodule"
        module_command = [compiler, *flags, "-parse-as-library", "-emit-library", "-emit-module",
                          "-enable-testing", "-module-name", "IlliquidNativePlayback",
                          "-emit-module-path", str(module), str(source), "-o", str(library)]
        run(module_command, output, folder / "build-module.log")
        binary = folder / "converter-memory"
        driver_command = [compiler, *flags, "-parse-as-library", "-I", str(folder), "-L", str(folder),
                          "-lIlliquidNativePlayback", "-Xlinker", "-rpath", "-Xlinker", str(folder),
                          str(output / "Driver.swift"), "-o", str(binary)]
        run(driver_command, output, folder / "build-driver.log")
        manifest["variants"][variant] = {"source_sha256": file_sha(source),
            "source_path": str(original.relative_to(ROOT)), "library_sha256": file_sha(library),
            "module_sha256": file_sha(module), "binary_sha256": file_sha(binary),
            "module_command": module_command, "driver_command": driver_command}
        binaries[variant] = binary
    write_json(output / "manifest.json", manifest)
    return binaries


def summarize(output: Path) -> list[dict]:
    config = json.loads((output / "benchmark.json").read_text())
    fixtures_manifest = json.loads((output / "fixtures.json").read_text())
    rows = [json.loads(line) for line in (output / "measurements.jsonl").read_text().splitlines()]
    expected = []
    for round_index in range(config["rounds"]):
        order = VARIANTS if round_index % 2 == 0 else VARIANTS[::-1]
        cases = config["cases"] if round_index % 2 == 0 else config["cases"][::-1]
        expected.extend((round_index, case, variant, position) for case in cases
                        for position, variant in enumerate(order))
    if len(rows) != len(expected):
        raise ValueError("Incomplete measurement cohort")
    receipts = {}
    for index, (row, identity) in enumerate(zip(rows, expected)):
        if (row["round"], row["case"], row["variant"], row["pair_position"]) != identity or row["sequence"] != index:
            raise ValueError("Unexpected measurement ordering")
        fixture = fixtures_manifest[row["case"]]
        if row["input_bytes"] != fixture["input_bytes"] or row.get("error") != fixture["expected_error"]:
            raise ValueError("Incorrect input or error receipt")
        if any(row[metric] <= 0 for metric in ("elapsed_ns", "cpu_ns", "peak_rss_bytes", "preconversion_peak_rss_bytes")):
            raise ValueError("Nonpositive measurement")
        if row["peak_rss_bytes"] < row["preconversion_peak_rss_bytes"]:
            raise ValueError("Process high-water RSS decreased")
        receipt = (row.get("output_bytes"), row.get("output_sha256"), row.get("error"))
        if row["case"] in receipts and receipts[row["case"]] != receipt:
            raise ValueError("Output/error receipt differs between measurements")
        receipts[row["case"]] = receipt
    summaries = []
    for name in config["cases"]:
        selected = [row for row in rows if row["case"] == name]
        summary = {"case": name, "pairs": config["rounds"], "input_bytes": fixtures_manifest[name]["input_bytes"],
                   "output_bytes": receipts[name][0], "output_sha256": receipts[name][1], "error": receipts[name][2]}
        for metric in ("peak_rss_bytes", "elapsed_ns", "cpu_ns", "preconversion_peak_rss_bytes"):
            values = {variant: [row[metric] for row in selected if row["variant"] == variant] for variant in VARIANTS}
            paired_ratios, paired_differences = [], []
            for round_index in range(config["rounds"]):
                pair = {row["variant"]: row[metric] for row in selected if row["round"] == round_index}
                paired_ratios.append(pair["candidate"] / pair["baseline"])
                paired_differences.append(pair["candidate"] - pair["baseline"])
            summary[metric] = {variant: {"median": statistics.median(items), "min": min(items), "max": max(items)}
                               for variant, items in values.items()}
            summary[metric].update({"paired_candidate_over_baseline": paired_ratios,
                "paired_candidate_minus_baseline": paired_differences,
                "median_paired_change_percent": (statistics.median(paired_ratios) - 1) * 100,
                "median_paired_difference": statistics.median(paired_differences)})
        summaries.append(summary)
    write_json(output / "summary.json", summaries)
    print(f"PASS {len(rows)} observations; all output/error receipts match", flush=True)
    for row in summaries:
        print(f"{row['case']}: peak RSS {row['peak_rss_bytes']['median_paired_change_percent']:+.1f}%; "
              f"wall {row['elapsed_ns']['median_paired_change_percent']:+.1f}%", flush=True)
    return summaries


def measure(args: argparse.Namespace, output: Path, binaries: dict[str, Path], fixture_manifest: dict) -> None:
    cases = list(fixture_manifest)
    write_json(output / "benchmark.json", {"cases": cases, "rounds": args.rounds,
        "protocol": "One conversion per fresh process, no warm conversion; adjacent AB/BA pairs, reversed cases each round; all samples retained.",
        "rss_scope": "Whole process peak including runtime and input loading; sampled before output encoding/writing and JSON."})
    logs, generated = output / "processes", output / "outputs"
    logs.mkdir()
    generated.mkdir()
    with (output / "measurements.jsonl").open("w") as stream:
        sequence = 0
        for round_index in range(args.rounds):
            order = VARIANTS if round_index % 2 == 0 else VARIANTS[::-1]
            traversal = cases if round_index % 2 == 0 else cases[::-1]
            for name in traversal:
                fixture = fixture_manifest[name]
                pair = {}
                paths = {}
                for position, variant in enumerate(order):
                    prefix = f"{round_index:02}-{name}-{variant}"
                    target = generated / f"{variant}.ass"
                    paths[variant] = target
                    raw = run([str(binaries[variant]), fixture["format"], str(output / fixture["file"]), str(target)],
                              output, logs / f"{prefix}.log")
                    (logs / f"{prefix}.json").write_text(raw)
                    row = json.loads(raw)
                    if row.get("error") != fixture["expected_error"] or row["input_bytes"] != fixture["input_bytes"]:
                        raise ValueError(f"Unexpected conversion result: {prefix}")
                    if row.get("error") is None:
                        if not 0 < target.stat().st_size <= LIMIT or target.stat().st_size != row["output_bytes"]:
                            raise ValueError(f"Invalid output size: {prefix}")
                        row["output_sha256"] = file_sha(target)
                    elif target.exists():
                        raise ValueError(f"Error case produced an output: {prefix}")
                    row.update({"case": name, "round": round_index, "variant": variant,
                                "pair_position": position, "sequence": sequence})
                    pair[variant] = row
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
                    stream.flush()
                    sequence += 1
                if fixture["expected_error"] is None:
                    if not exact_file_equal(paths["baseline"], paths["candidate"]):
                        raise ValueError(f"Exact output bytes differ: {name}, round {round_index}")
                    if round_index == 0:
                        with paths["baseline"].open("rb") as source, (generated / f"{name}.ass.gz").open("wb") as destination:
                            with gzip.GzipFile(fileobj=destination, mode="wb", mtime=0, filename="") as compressed:
                                shutil.copyfileobj(source, compressed)
                    for path in paths.values():
                        path.unlink()
            print(f"Finished paired round {round_index + 1}/{args.rounds}", flush=True)
    summarize(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("benchmark", "summarize"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--case", action="append", help="Repeat to select cases; default all sixteen")
    args = parser.parse_args()
    output = args.output.resolve()
    if args.mode == "summarize":
        summarize(output)
        return
    if args.rounds < 2 or args.rounds % 2:
        parser.error("--rounds must be even and at least two")
    available = [f"{format_name}-{kind}" for format_name in ("srt", "vtt") for kind in COUNTS]
    cases = args.case or available
    if len(set(cases)) != len(cases) or any(case not in available for case in cases):
        parser.error(f"--case must name unique cases from: {', '.join(available)}")
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    manifest = fixtures(cases, output)
    binaries = build(args, output)
    measure(args, output, binaries, manifest)


if __name__ == "__main__":
    main()
