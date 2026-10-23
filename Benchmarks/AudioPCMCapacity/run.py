#!/usr/bin/env python3
"""Exact-source PCM allocation comparison; native macOS measurements qualify the change."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

BASELINE = "af1c1add701e49b355448cf8983eaed1e7623108"
DECODER = "Sources/IlliquidNativePlayback/Media/AudioDecoder.swift"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def file_digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def sections(source):
    convert_start = source.index("        let bytesPerSample = MemoryLayout<Float>.size", source.index("let capacity = illiquid_audio_resampler_output_capacity"))
    convert_end = source.index("        let convertedSamples: Int32", convert_start)
    drain_start = source.index("            guard capacity > 0 else { break }", source.index("    private func drainResampler"))
    drain_start = source.index("\n", drain_start) + 1
    drain_end = source.index("            let count = data.withUnsafeMutableBytes", drain_start)
    sanitizer = source[source.index("struct AudioSampleSanitizationResult:"):source.index("struct AudioDecoderNoProgressError:")]
    return {"convert": source[convert_start:convert_end], "drain": source[drain_start:drain_end], "sanitizer": sanitizer}


def cases():
    output = []
    for path in ("convert", "drain"):
        # Controls cross inline storage, empty output, and an intentionally extreme shrink.
        shapes = [(1, 1, 1), (2, 1, 1), (2, 32, 0), (8, 8192, 1)]
        shapes += [(ch, samples + extra, samples) for ch in (2, 6, 8)
                   for samples in (1024, 8192) for extra in (0, 32)]
        for channels, capacity, actual in shapes:
            output.append({"id": f"{path}-c{channels}-cap{capacity}-out{actual}", "path": path,
                           "channels": channels, "capacity_samples": capacity, "actual_samples": actual})
    return output


def stats(values):
    return {"median": statistics.median(values), "minimum": min(values), "maximum": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=float, default=120)
    parser.add_argument("--frames", type=int, default=48)
    parser.add_argument("--case", action="append", help="Run only these exact case IDs (smoke checks).")
    args = parser.parse_args()
    if args.pairs < 2 or args.pairs % 2 or args.target_ms <= 0 or args.frames < 1:
        parser.error("pairs must be positive and even (>=2), target-ms and frames positive")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        parser.error("output must be empty to prevent mixing receipts from different runs")
    commands = []

    def write(name, value):
        (out / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def command(argv, parse=False):
        started = time.monotonic()
        result = subprocess.run([str(x) for x in argv], cwd=ROOT, text=True, capture_output=True)
        record = {"argv": [str(x) for x in argv], "returncode": result.returncode,
                  "duration_seconds": time.monotonic() - started,
                  "stdout": result.stdout, "stderr": result.stderr}
        commands.append(record)
        write("commands.json", commands)
        if result.returncode:
            raise RuntimeError(json.dumps(record, indent=2))
        return json.loads(result.stdout) if parse else result.stdout

    current = (ROOT / DECODER).read_text()
    baseline = command(["git", "show", f"{BASELINE}:{DECODER}"])
    source = {"baseline": baseline, "candidate": current}
    extracted = {variant: sections(text) for variant, text in source.items()}
    assert extracted["baseline"]["sanitizer"] == extracted["candidate"]["sanitizer"], "sanitizer changed"
    all_cases = cases()
    selected = [case for case in all_cases if not args.case or case["id"] in args.case]
    if not selected or (args.case and len(selected) != len(set(args.case))):
        parser.error("unknown or empty case selection")
    manifest = {"baseline": BASELINE, "candidate_head": command(["git", "rev-parse", "HEAD"]).strip(),
                "candidate_status": command(["git", "status", "--short"]),
                "platform": platform.platform(), "machine": platform.machine(),
                "swift": command(["swiftc", "--version"]), "cases": selected,
                "pairs": args.pairs, "target_ms": args.target_ms, "retained_frames": args.frames,
                "heap_metric": "malloc_zone_statistics.size_in_use" if platform.system() == "Darwin" else "mallinfo2.uordblks+hblkhd",
                "timing_scope": "allocation, finite PCM write, shrink, production sanitizer and release; excludes codec/resampler",
                "source_hashes": {}, "binary_hashes": {},
                "clang": command(["clang", "--version"]),
                "harness_hashes": {name: digest((HERE / name).read_text()) for name in ("run.py", "Driver.swift", "probe.c")}}
    compiler = Path(shutil.which("swiftc")).resolve()
    if platform.system() == "Darwin":
        compiler = Path(command(["xcrun", "--find", "swiftc"]).strip()).resolve()
        manifest["native_environment"] = {"os": command(["sw_vers"]),
            "xcode": command(["xcodebuild", "-version"]),
            "hardware": command(["sysctl", "hw.model", "hw.memsize", "hw.ncpu", "machdep.cpu.brand_string"]),
            "sdk_path": command(["xcrun", "--show-sdk-path"]).strip(),
            "sdk_version": command(["xcrun", "--show-sdk-version"]).strip()}
    manifest["swiftc_resolved"] = str(compiler)
    manifest["swiftc_sha256"] = file_digest(compiler)
    binaries = {}
    for variant, text in source.items():
        directory = out / variant
        directory.mkdir(exist_ok=True)
        (directory / "AudioDecoder.swift.txt").write_text(text)
        part = extracted[variant]
        generated = ("import Foundation\n" + part["sanitizer"] +
                     "\n@inline(never) func allocateConvert(_ capacity: Int32, _ outputChannels: Int) -> Data {\n" +
                     part["convert"] + "    return data\n}\n" +
                     "\n@inline(never) func allocateDrain(_ capacity: Int32, _ metadata: DrainMetadata) -> Data {\n" +
                     part["drain"] + "    return data\n}\n")
        (directory / "Extracted.swift").write_text(generated)
        (directory / "main.swift").write_text((HERE / "Driver.swift").read_text())
        manifest["source_hashes"][variant] = {"decoder": digest(text), "extracted": digest(generated),
                                                **{key: digest(value) for key, value in part.items()}}
        command(["clang", "-O2", "-c", HERE / "probe.c", "-o", directory / "probe.o"])
        for config, flags in (("debug", ["-Onone"]), ("release", ["-O"])):
            binary = directory / f"probe-{config}"
            command(["swiftc", "-swift-version", "6", *flags, directory / "Extracted.swift",
                     directory / "main.swift", directory / "probe.o", "-o", binary])
            binaries[(variant, config)] = binary
            manifest["binary_hashes"][f"{variant}-{config}"] = file_digest(binary)
    write("manifest.json", manifest)

    def invoke(variant, config, mode, case, iterations=1):
        return command([binaries[(variant, config)], mode, case["path"], case["capacity_samples"],
                        case["channels"], case["actual_samples"], iterations, args.frames], parse=True)

    parity = []
    for case in selected:
        receipts = {f"{variant}-{config}": invoke(variant, config, "verify", case)
                    for variant in source for config in ("debug", "release")}
        assert all(receipt == receipts["baseline-debug"] for receipt in receipts.values()), case["id"]
        parity.append({"case": case["id"], "equal": True, "receipts": receipts})
    write("parity.json", {"all_equal": True, "cases": parity})
    print(f"Full-byte debug/release parity passed for {len(selected)} cases", flush=True)

    raw, calibration = [], []
    for case in selected:
        trial = {variant: invoke(variant, "release", "measure", case, 64) for variant in source}
        ns = statistics.mean(result["wall_ns_per_call"] for result in trial.values())
        iterations = max(32, min(2_000_000, int(args.target_ms * 1_000_000 / max(ns, 1))))
        calibration.append({"case": case["id"], "iterations": iterations, "trials": trial})
        write("calibration.json", calibration)
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for position, variant in enumerate(order):
                measurement = invoke(variant, "release", "measure", case, iterations)
                row = {"case": case["id"], "pair": pair, "position": position, "variant": variant, **measurement}
                raw.append(row)
                with (out / "measurements.jsonl").open("a") as handle:
                    handle.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"Measured {case['id']} ({args.pairs} balanced pairs)", flush=True)

    summary = {"cases": [], "scope": manifest["timing_scope"], "heap_metric": manifest["heap_metric"]}
    keys = ("retained_heap_delta_bytes", "released_heap_delta_bytes", "wall_ns_per_call", "cpu_ns_per_call")
    for case in selected:
        rows = {variant: [row for row in raw if row["case"] == case["id"] and row["variant"] == variant] for variant in source}
        result = {**case, "variants": {variant: {key: stats([row[key] for row in group]) for key in keys} for variant, group in rows.items()}, "paired": {}}
        for key in keys:
            before = [row[key] for row in rows["baseline"]]
            after = [row[key] for row in rows["candidate"]]
            result["paired"][key] = {"candidate_wins": sum(b > a for b, a in zip(before, after)),
                                     "bytes_or_ns_saved": stats([b - a for b, a in zip(before, after)])}
            if all(b != 0 for b in before):
                result["paired"][key]["percent_change"] = stats([(a / b - 1) * 100 for b, a in zip(before, after)])
        summary["cases"].append(result)
    write("summary.json", summary)
    write("completion.json", {"success": True, "parity_cases": len(parity), "measurements": len(raw)})
    print(json.dumps({"success": True, "cases": len(selected), "measurements": len(raw)}), flush=True)


if __name__ == "__main__":
    main()
