#!/usr/bin/env python3
"""Compare native PCM presentation ownership against the exact pre-change revision."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
PRESENTER = "Sources/IlliquidNativePlayback/Presentation/SampleBufferAudioPresenter.swift"
HELPER = "Sources/IlliquidNativePlayback/Presentation/AudioPCMBlockBuffer.swift"
DECODER = "Sources/IlliquidNativePlayback/Media/AudioDecoder.swift"
VIDEO = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
SCENARIOS = [
    "mono-inline", "stereo-small", "stereo-1024", "surround6-1024", "surround8-1024",
    "stereo-4096", "surround8-4096", "stereo-silence", "surround8-silence",
    "surround8-delay-stress",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def section(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"Production extraction anchors changed: {start!r}, {end!r}")
    first, last = source.index(start), source.index(end)
    if last <= first:
        raise RuntimeError("Reversed production extraction anchors")
    return source[first:last].rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=6)
    parser.add_argument("--target-ms", type=int, default=80)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Native macOS and CoreMedia are required")
    if not 2 <= args.pairs <= 12 or args.pairs % 2 or not 20 <= args.target_ms <= 500:
        parser.error("pairs must be even in 2...12; target-ms must be in 20...500")
    if Path("/Volumes/seed1/Projects/kyoto/kyoto.py").exists():
        parser.error("Kyoto is available: coordinate these builds through the shared queue")
    print("Kyoto is unavailable on this host; compiling serially in an isolated output directory.", flush=True)
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        parser.error("Use a new or empty output directory to preserve earlier evidence")
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CLANG_MODULE_CACHE_PATH"] = str(out / "module-cache")
    commands = []

    def run(argv, log=None, timeout=600):
        command = [str(value) for value in argv]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=timeout)
        commands.append({"argv": command, "returncode": result.returncode})
        write_json(out / "commands.json", commands)
        if log:
            log.write_text(json.dumps(command) + "\n\n" + result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {command!r}\n{result.stdout[-2000:]}\n{result.stderr[-6000:]}")
        return result.stdout

    swiftc = run(["xcrun", "--find", "swiftc"]).strip()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
    environment = {
        "platform": platform.platform(), "architecture": platform.machine(),
        "macos": run(["sw_vers"]).strip(), "compiler": run([swiftc, "--version"]).strip(),
        "cpu": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(), "sdk": sdk,
        "developer_dir": env.get("DEVELOPER_DIR"),
        "scope": "Native CoreMedia PCM sample-buffer construction and destruction, not live playback",
    }
    write_json(out / "environment.json", environment)
    manifest = {
        "baseline_revision": BASELINE,
        "candidate_revision": run(["git", "rev-parse", "HEAD"]).strip(),
        "working_tree": run(["git", "status", "--short"]),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "github_run_id": env.get("GITHUB_RUN_ID"), "github_run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "harness_sha256": digest((HERE / "Harness.swift").read_bytes()),
        "pairs": args.pairs, "target_ms": args.target_ms, "sources": {},
    }
    flags = ["-swift-version", "6", "-parse-as-library", "-warnings-as-errors",
             "-module-cache-path", out / "module-cache",
             "-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk]
    binaries = {}
    verification = {}
    for variant in ["baseline", "candidate"]:
        folder = out / variant
        sources_dir = folder / "sources"
        sources_dir.mkdir(parents=True)
        sources = {
            path: run(["git", "show", f"{BASELINE}:{path}"]) if variant == "baseline"
            else (ROOT / path).read_text() for path in [PRESENTER, DECODER, VIDEO]
        }
        method = section(sources[PRESENTER], "    static func makeSampleBuffer(", "    func flush()")
        frame = section(sources[DECODER], "struct NativeDecodedAudioFrame: Sendable {",
                        "\nextension NativeDecodedAudioFrame {")
        error_anchor = "struct PresentationError: LocalizedError {"
        if sources[VIDEO].count(error_anchor) != 1:
            raise RuntimeError("PresentationError anchor changed")
        errors = sources[VIDEO][sources[VIDEO].index(error_anchor):]
        staged = {
            "Presenter.swift": "import AudioToolbox\nimport CoreMedia\nimport Foundation\n\n"
                               + "enum SampleBufferAudioPresenter {\n" + method + "}\n",
            "Frame.swift": "import CoreMedia\nimport Foundation\n\n" + frame,
            "Errors.swift": "import AudioToolbox\nimport Foundation\n\n" + errors,
        }
        if variant == "candidate":
            sources[HELPER] = (ROOT / HELPER).read_text()
            staged["AudioPCMBlockBuffer.swift"] = sources[HELPER]
        for name, source in staged.items():
            (sources_dir / name).write_text(source)
        manifest["sources"][variant] = {
            "input_sha256": {path: digest(source.encode()) for path, source in sources.items()},
            "staged_sha256": {path: digest(source.encode()) for path, source in staged.items()},
            "binaries": {},
        }
        for configuration in ["debug", "release"]:
            binary = folder / f"pcm-{configuration}"
            optimization = ["-Onone"] if configuration == "debug" else ["-O", "-whole-module-optimization"]
            run([swiftc, *flags, *optimization, *sorted(sources_dir.glob("*.swift")),
                 HERE / "Harness.swift", "-o", binary], folder / f"compile-{configuration}.log")
            manifest["sources"][variant]["binaries"][configuration] = digest(binary.read_bytes())
            receipt = json.loads(run([binary, "--verify"], folder / f"verify-{configuration}.log"))
            if receipt.get("passed") is not True or len(receipt.get("cases", [])) != 72:
                raise RuntimeError("Incomplete native verification")
            verification[f"{variant}-{configuration}"] = receipt
            if configuration == "release":
                binaries[variant] = binary
    write_json(out / "manifest.json", manifest)
    if any(value != verification["baseline-debug"] for value in verification.values()):
        raise RuntimeError("Debug/release baseline/candidate PCM or metadata receipts differ")
    write_json(out / "verification.json", {
        "passed": True, "cases_per_binary": 72, "configurations": list(verification),
        "receipt": verification["candidate-release"],
    })
    print("72 exact PCM/timing cases agree in all four native binaries.", flush=True)

    memory = {}
    for name in SCENARIOS:
        if name == "mono-inline":
            continue  # Borrowed inline Data addresses are not stable allocation identities.
        memory[name] = {
            variant: json.loads(run([binary, "--retained", name]))
            for variant, binary in binaries.items()
        }
        baseline, candidate = memory[name]["baseline"], memory[name]["candidate"]
        if (baseline["logical_pcm_bytes"] != candidate["logical_pcm_bytes"]
                or baseline["distinct_output_payloads"] != baseline["buffers"]
                or baseline["additional_output_payload_bytes"] != baseline["logical_pcm_bytes"]
                or candidate["additional_output_payload_bytes"] != 0
                or candidate["distinct_output_payloads"] != candidate["distinct_source_payloads"]):
            write_json(out / "memory.json", memory)
            raise RuntimeError(f"PCM storage-sharing mechanism did not qualify: {name}")
    write_json(out / "memory.json", memory)
    print("Heap PCM shares its source bytes; shared silence retains one payload per batch.", flush=True)

    rows, summary, calibration = [], [], {}
    for name in SCENARIOS:
        trial = {variant: json.loads(run([binary, "--time", name, "100"]))
                 for variant, binary in binaries.items()}
        slowest = max(value["wall_ns"] for value in trial.values())
        iterations = max(1, min(1_000_000, int(100 * args.target_ms * 1_000_000 / slowest)))
        calibration[name] = {"iterations": iterations, "trial": trial}
        write_json(out / "calibration.json", calibration)
        ratios, cpu_ratios, current = [], [], []
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            paired = {}
            for position, variant in enumerate(order):
                row = json.loads(run([binaries[variant], "--time", name, str(iterations)]))
                if (row.get("scenario") != name or row.get("iterations") != iterations
                        or row.get("wall_ns", 0) <= 0 or row.get("cpu_ns", 0) <= 0
                        or row.get("operations", 0) <= 0):
                    raise RuntimeError("Invalid timing receipt")
                row.update(variant=variant, pair=pair, position=position)
                paired[variant] = row
                current.append(row)
                rows.append(row)
                with (out / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")
            if any(paired["baseline"][key] != paired["candidate"][key] for key in ["checksum", "operations"]):
                raise RuntimeError("Timed output consumption differs")
            ratios.append(paired["candidate"]["wall_ns"] / paired["baseline"]["wall_ns"])
            cpu_ratios.append(paired["candidate"]["cpu_ns"] / paired["baseline"]["cpu_ns"])
        item = {
            "scenario": name, "pairs": args.pairs, "iterations": iterations,
            "wall_reduction_percent": 100 * (1 - statistics.median(ratios)),
            "cpu_reduction_percent": 100 * (1 - statistics.median(cpu_ratios)),
            "paired_wall_ratios": ratios,
        }
        for variant in binaries:
            values = [row["wall_ns"] / row["operations"] for row in current if row["variant"] == variant]
            item[variant + "_ns_per_buffer"] = {
                "median": statistics.median(values), "min": min(values), "max": max(values),
            }
        summary.append(item)
        write_json(out / "summary.json", summary)
        print(f"{name}: wall {item['wall_reduction_percent']:.1f}%, CPU {item['cpu_reduction_percent']:.1f}%", flush=True)
    write_json(out / "completion.json", {
        "completed_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "compiled": True, "exact_pcm_and_timing_parity": True,
        "storage_sharing_qualified": True, "observations": len(rows),
        "benchmark_complete": True, "live_playback_qualified": False,
        "timing_acceptance": "Review common-frame results against README criteria; no flaky timing gate",
    })


if __name__ == "__main__":
    main()
