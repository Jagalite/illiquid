#!/usr/bin/env python3
"""Compare complete production PlexMatch parsers with paired native timings."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
NAMES = ["MediaNameRecognition", "MediaMetadataHints", "PlexMatchHints",
         "NFOMetadataHints", "MediaSidecarReader"]
SOURCES = [f"Sources/IlliquidCore/MediaLibrary/{name}.swift" for name in NAMES]
TESTS = [f"Tests/IlliquidCoreTests/{name}.swift" for name in
         ["PlexMatchHintsRegressionTests", "PlexMatchReaderRegressionTests", "MediaSidecarTests"]]
VARIANTS = ("baseline", "candidate")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def save(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def run(argv, log: Path, out: Path, timeout=240) -> str:
    env = dict(os.environ)
    for name, suffix in [("CLANG_MODULE_CACHE_PATH", "clang"),
                         ("SWIFTPM_MODULECACHE_OVERRIDE", "swift"),
                         ("XDG_CACHE_HOME", "xdg"), ("TMPDIR", "tmp")]:
        folder = out / "cache" / suffix
        folder.mkdir(parents=True, exist_ok=True)
        env[name] = str(folder)
    # Keep dictionary placement identical in the two separately launched variants.
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    argv = list(map(str, argv))
    result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(json.dumps(argv) + "\n\n" + result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {log}\n{result.stderr[-5000:]}")
    return result.stdout


def fixtures() -> dict:
    header = "title: Parser Café 🎬\nyear: 2019\nseason: 7\ntvdbid: 42\n"
    workloads = []

    def add(name, rows):
        text = header + "".join(f"ep: {token}: {path}\n" for token, path in rows)
        assert len(text.encode()) <= 128 * 1024
        workloads.append({"name": name, "text": text, "paths": [path for _, path in rows]})

    def row(index):
        number = index % 8998 + 1
        tokens = [f"E{number:04}", f"S03E{number:04}", f"SP{number:04}",
                  f"S04E{number:04}-E{number + 1:04}"]
        path = ("Season 2/" if index % 5 == 4 else "") + f"episode-{index:05}.mkv"
        return tokens[index % 4], path

    for count in (0, 1, 24, 1024):
        add(f"mappings-{count}", [row(index) for index in range(count)])
    rows, size = [], len(header.encode())
    while True:
        token, path = row(len(rows))
        extra = len(f"ep: {token}: {path}\n".encode())
        if size + extra > 128 * 1024:
            break
        rows.append((token, path))
        size += extra
    assert size >= 127 * 1024
    add("near-128kib", rows)
    add("unicode-prefixes-24", [(f"ſ03E{i + 1:04}", f"épisode-{i:02}.mkv") for i in range(24)])
    invalid = ["E00000", "E1-S0E2", "SP1-SP2", "S1E2-E1", "S1E1suffix", "E1-E1"]
    add("invalid-ascii-24", [(invalid[i % len(invalid)], f"invalid-{i:02}.mkv") for i in range(24)])
    add("long-invalid-control", [("E" + "0" * 3980, "invalid.mkv")])

    prefixes = ["", "E", "e", "SP", "sp", "Sp", "sP", "S", "P", "EE", "SPE"]
    for season in ["0", "00", "000", "1", "01", "999", "1000"]:
        prefixes.extend([f"S{season}E", f"s{season}e"])
    numbers = ["", "0", "00", "0000", "00000", "1", "01", "2", "9998", "9999", "10000", "+1", "-1"]
    suffixes = ["", "-0", "-1", "-2", "-E2", "-e9999", "-S0E2", "-S00E2",
                "-s1e2", "-S7E2", "-S001E9999", "-S999E9999", "-S1000E2", "-SP2",
                "-E00002", "-", "--2", "-E2-E3", " ", "\t", "suffix"]
    tokens = {prefix + number + suffix
              for prefix, number, suffix in itertools.product(prefixes, numbers, suffixes)}
    tokens.update(["ſP01", "ſ01E02", "S01E01-ſ01E02", "S0E1-S00E2", "SP1-S0E2",
                   "０２", "E٠٢", "S０１E02", "S01E𝟎𝟐", "E1-E２",
                   "E1\u0000", "E1\u007f", "E1\r", "E1\n", "E1\r\n", "E1\v", "E1\f",
                   "E1\u0085", "E1\u2028", "E1\u2029", "E1\u00a0", "E1\u200b",
                   "sP01-s000e0002", "S003e0004-s3E0005", "ſ03E04-ſ03E05", "ſP01-S00E02",
                   "E" + "0" * 3980])
    return {"workloads": workloads, "tokens": sorted(tokens)}


def compare_pair(pair):
    if {row["variant"] for row in pair} != set(VARIANTS):
        raise RuntimeError("Missing variant")
    for field in ("workload", "iterations", "checksum", "input_bytes",
                  "warmup_iterations", "warmup_checksum"):
        if pair[0][field] != pair[1][field]:
            raise RuntimeError(f"Receipt mismatch in {field}")


def summarize(rows, inputs):
    result = []
    for fixture in inputs["workloads"]:
        selected = [row for row in rows if row["workload"] == fixture["name"]]
        times = {v: [row["elapsed_ns"] / row["iterations"] for row in selected if row["variant"] == v]
                 for v in VARIANTS}
        ratios = []
        for round_index in sorted({row["round"] for row in selected}):
            pair = [row for row in selected if row["round"] == round_index]
            compare_pair(pair)
            by_variant = {row["variant"]: row for row in pair}
            ratios.append(by_variant["candidate"]["elapsed_ns"] / by_variant["baseline"]["elapsed_ns"])
        medians = {v: statistics.median(values) for v, values in times.items()}
        result.append({"workload": fixture["name"], "input_bytes": len(fixture["text"].encode()),
                       "directive_count": len(fixture["paths"]), "median_ns": medians,
                       "change_percent": (medians["candidate"] / medians["baseline"] - 1) * 100,
                       "paired_ratios": ratios, "candidate_faster_pairs": sum(x < 1 for x in ratios),
                       "ranges_ns": {v: [min(xs), max(xs)] for v, xs in times.items()}})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-ref", default=BASELINE)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--target-ms", type=float, default=100)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This qualification runs on macOS with the real sidecar reader and Foundation.")
    if args.rounds < 2 or args.rounds % 2 or not math.isfinite(args.target_ms) or not 10 <= args.target_ms <= 1000:
        parser.error("Use even --rounds >= 2 and finite --target-ms in 10...1000")
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Use a fresh output directory; previous evidence is never overwritten")
    out.mkdir(parents=True, exist_ok=True)
    baseline = run(["git", "rev-parse", "--verify", "--end-of-options", args.baseline_ref + "^{commit}"],
                   out / "baseline-ref.log", out).strip()
    candidate = run(["git", "rev-parse", "HEAD"], out / "candidate-ref.log", out).strip()
    swift = run(["xcrun", "--find", "swift"], out / "swift-path.log", out).strip()
    swiftc = run(["xcrun", "--find", "swiftc"], out / "swiftc-path.log", out).strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], out / "sdk.log", out).strip()
    version = run([swiftc, "--version"], out / "compiler.log", out).strip()
    inputs = fixtures()
    save(out / "inputs.json", inputs)
    harness = (HERE / "Harness.swift").read_bytes()
    (out / "Harness.swift").write_bytes(harness)
    (out / "run.py").write_bytes(Path(__file__).read_bytes())
    manifest = {"baseline": baseline, "candidate": candidate, "platform": platform.platform(),
                "machine": platform.machine(), "compiler": version, "sdk": sdk,
                "swiftc_sha256": sha(Path(swiftc).resolve().read_bytes()),
                "harness_sha256": sha(harness), "runner_sha256": sha(Path(__file__).read_bytes()),
                "inputs_sha256": sha((out / "inputs.json").read_bytes()), "sources_sha256": {},
                "rounds": args.rounds, "target_ms": args.target_ms,
                "hashing": "SWIFT_DETERMINISTIC_HASHING=1",
                "method": "Complete production sources; separate optimized module/driver; full output parity; equal-iteration fresh-process balanced AB/BA pairs."}
    packages = {}
    for variant in VARIANTS:
        package = out / "packages" / variant
        packages[variant] = package
        hashes = {}
        for path in SOURCES:
            if variant == "baseline":
                data = subprocess.run(["git", "show", f"{baseline}:{path}"], cwd=ROOT,
                                      check=True, capture_output=True).stdout
            else:
                data = (ROOT / path).read_bytes()
            destination = package / "Sources/IlliquidCore" / Path(path).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            hashes[path] = sha(data)
        manifest["sources_sha256"][variant] = hashes
        for path in TESTS:
            destination = package / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((ROOT / path).read_bytes())
        (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PlexMatchParsingQualification", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
""")
    manifest["tests_sha256"] = {path: sha((ROOT / path).read_bytes()) for path in TESTS}
    changed = [p for p in SOURCES if manifest["sources_sha256"]["baseline"][p] != manifest["sources_sha256"]["candidate"][p]]
    if changed != ["Sources/IlliquidCore/MediaLibrary/PlexMatchHints.swift"]:
        raise RuntimeError(f"Expected only the parser source to differ: {changed}")
    save(out / "manifest.json", manifest)

    test_results = []
    for variant, package in packages.items():
        for configuration in ("debug", "release"):
            log = out / f"tests-{variant}-{configuration}.log"
            output = run([swift, "test", "--package-path", package,
                          "--scratch-path", out / "build" / variant, "--jobs", "2", "--no-parallel",
                          "-c", configuration], log, out)
            counts = re.findall(r"Test run with (\d+) tests?\b[^\n]*\bpassed\b", log.read_text())
            if not counts or int(counts[-1]) <= 0:
                raise RuntimeError(f"No successful nonempty Swift Testing receipt: {log}")
            test_results.append({"variant": variant, "configuration": configuration,
                                 "passed": int(counts[-1]), "log_sha256": sha(log.read_bytes())})
            print(f"PASS {variant} {configuration}: {counts[-1]} tests", flush=True)
    if len({row["passed"] for row in test_results}) != 1:
        raise RuntimeError("Baseline/candidate test counts differ")
    save(out / "tests.json", test_results)

    flags = ["-swift-version", "6", "-O", "-whole-module-optimization", "-enable-testing",
             "-parse-as-library", "-target", platform.machine() + "-apple-macosx26.0",
             "-sdk", sdk, "-module-cache-path", str(out / "cache/modules")]
    binaries = {}
    binary_hashes = {}
    for variant, package in packages.items():
        folder = out / "bin" / variant
        folder.mkdir(parents=True)
        library = folder / "libIlliquidCore.dylib"
        module = folder / "IlliquidCore.swiftmodule"
        run([swiftc, *flags, "-emit-library", "-emit-module", "-module-name", "IlliquidCore",
             "-emit-module-path", module, "-o", library,
             *[package / "Sources/IlliquidCore" / f"{name}.swift" for name in NAMES]],
            out / f"build-{variant}-module.log", out)
        binary = folder / "plexmatch-parsing"
        run([swiftc, *flags, "-I", folder, "-L", folder, "-lIlliquidCore",
             "-Xlinker", "-rpath", "-Xlinker", folder, out / "Harness.swift", "-o", binary],
            out / f"build-{variant}-harness.log", out)
        binaries[variant] = binary
        binary_hashes[variant] = {"library": sha(library.read_bytes()), "driver": sha(binary.read_bytes())}
    manifest["binaries_sha256"] = binary_hashes
    save(out / "manifest.json", manifest)

    verification = {}
    for variant, binary in binaries.items():
        raw = run([binary, "verify", out / "inputs.json"], out / f"verify-{variant}.log", out)
        (out / f"verification-{variant}.json").write_text(raw)
        verification[variant] = json.loads(raw)
    if verification["baseline"] != verification["candidate"]:
        raise RuntimeError("Complete metadata receipts differ")
    save(out / "parity.json", {"equal": True, "token_count": len(inputs["tokens"]),
                              "corpus_parses": len(inputs["tokens"]) * 3,
                              "workload_count": len(inputs["workloads"]),
                              "sha256": {v: sha((out / f"verification-{v}.json").read_bytes()) for v in VARIANTS}})
    print(f"PASS full metadata parity: {len(inputs['tokens']) * 3} corpus parses", flush=True)
    del verification

    def measure(variant, fixture, count, label):
        log = out / "processes" / f"{label}-{fixture['name']}-{variant}.log"
        row = json.loads(run([binaries[variant], "benchmark", out / "inputs.json", fixture["name"], count], log, out))
        if row["iterations"] != count or row["elapsed_ns"] <= 0:
            raise RuntimeError("Invalid timing receipt")
        row["variant"] = variant
        row["process_log_sha256"] = sha(log.read_bytes())
        return row

    counts, pilots = {}, []
    for index, fixture in enumerate(inputs["workloads"]):
        count = 1
        for attempt in range(10):
            order = VARIANTS if (index + attempt) % 2 == 0 else VARIANTS[::-1]
            pair = [measure(v, fixture, count, f"pilot-{attempt}") for v in order]
            compare_pair(pair)
            pilots.extend(pair)
            fastest = min(row["elapsed_ns"] for row in pair)
            if fastest >= args.target_ms * 1_000_000:
                break
            count = max(count + 1, math.ceil(count * args.target_ms * 1_000_000 / fastest * 1.1))
        else:
            raise RuntimeError("Calibration failed")
        counts[fixture["name"]] = count
    save(out / "calibration.json", pilots)
    rows = []
    with (out / "measurements.jsonl").open("w") as receipt:
        for round_index in range(args.rounds):
            for index, fixture in enumerate(inputs["workloads"]):
                order = VARIANTS if (round_index + index) % 2 == 0 else VARIANTS[::-1]
                pair = []
                for variant in order:
                    row = measure(variant, fixture, counts[fixture["name"]], f"round-{round_index}")
                    row.update({"round": round_index, "order": list(order)})
                    rows.append(row)
                    pair.append(row)
                    receipt.write(json.dumps(row, sort_keys=True) + "\n")
                    receipt.flush()
                compare_pair(pair)
            print(f"Completed pair {round_index + 1}/{args.rounds}", flush=True)
    summary = summarize(rows, inputs)
    save(out / "summary.json", summary)
    for item in summary:
        print(f"{item['workload']}: {item['median_ns']['baseline']:.1f} -> "
              f"{item['median_ns']['candidate']:.1f} ns/parse ({item['change_percent']:+.2f}%), "
              f"{item['candidate_faster_pairs']}/{args.rounds} faster pairs", flush=True)


if __name__ == "__main__":
    main()
