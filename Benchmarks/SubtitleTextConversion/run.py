#!/usr/bin/env python3
"""Measure the complete SRT/WebVTT converter in alternating fresh processes."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import shutil
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCE = "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
DRIVER = Path(__file__).with_name("main.swift")
SCENARIOS = ("ascii", "unicode", "multiline", "mixed", "escape-dense", "unicode-escaped")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def timestamp(milliseconds: int, separator: str) -> str:
    seconds, fraction = divmod(milliseconds, 1000)
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}{separator}{fraction:03}"


def fixture(count: int, scenario: str, format_name: str) -> bytes:
    blocks = ["WEBVTT"] if format_name == "webvtt" else []
    separator = "," if format_name == "srt" else "."
    for index in range(count):
        ordinary = f"We should leave before the next train arrives. Caption {index}."
        if scenario == "ascii":
            caption = ordinary
        elif scenario == "unicode":
            caption = f"Café / Cafe\u0301 日本語 한국어 العربية 👩🏽‍🚀 — caption {index}."
        elif scenario == "multiline":
            caption = ordinary + "\nI will meet you at the station."
        elif scenario == "mixed":
            caption = ordinary if index % 10 else f"Open {{chapter {index}}} at C:\\Media\\film.\nLiteral \\N stays text."
        elif scenario == "escape-dense":
            caption = (r"{\an8}\N {literal} C:\Media\ \\ {{}} " * 3) + str(index)
        elif scenario == "unicode-escaped":
            # Foundation's nonliteral matching intentionally leaves some
            # punctuation-plus-combining-mark sequences unescaped. Exercise
            # the compatibility fallback as well as ordinary Unicode escapes.
            caption = f"Café 日本語 {{chapter {index}}} C:\\Media\\film \\\u0301 {{\uFE0F }}\u200D"
        else:
            raise ValueError(scenario)
        start = timestamp(index * 2500 + 1005, separator)
        end = timestamp(index * 2500 + 3000, separator)
        settings = " align:start position:10%" if format_name == "webvtt" else ""
        blocks.append(f"{index + 1}\n{start} --> {end}{settings}\n{caption}")
    return ("\n\n".join(blocks) + "\n").encode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new or empty evidence directory")
    parser.add_argument("--sizes", type=positive_int, nargs="+", default=[50, 1500, 10000])
    parser.add_argument("--scenarios", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    parser.add_argument("--formats", nargs="+", choices=("srt", "webvtt"), default=["srt", "webvtt"])
    parser.add_argument("--repeats", type=positive_int, default=8, help="fresh-process pairs; use an even number")
    parser.add_argument("--rounds", type=positive_int, default=3, help="timed conversions per process after one warmup")
    args = parser.parse_args()
    if any(len(values) != len(set(values)) for values in (args.sizes, args.scenarios, args.formats)):
        parser.error("duplicate workloads are not allowed")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be new or empty")
    compiler = shutil.which("swiftc")
    if compiler is None:
        parser.error("swiftc is required on PATH (Swift 6.1 or newer)")
    baseline_source = subprocess.check_output(["git", "show", f"{BASELINE}:{SOURCE}"], cwd=ROOT)
    candidate_source = (ROOT / SOURCE).read_bytes()
    driver_source = DRIVER.read_bytes()
    runner_source = Path(__file__).read_bytes()
    output.mkdir(parents=True, exist_ok=True)
    flags = ["-O", "-swift-version", "6"]
    if platform.system() == "Darwin":
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    evidence = {
        "schema": 1,
        "status": "incomplete",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "swift": subprocess.check_output([compiler, "--version"], text=True).strip(),
        "baseline_commit": BASELINE,
        "checkout_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_path": SOURCE,
        "source_sha256": {},
        "driver_sha256": digest(driver_source),
        "runner_sha256": digest(runner_source),
        "compiler_flags": flags,
        "commands": [],
        "executables_sha256": {},
        "sizes": args.sizes,
        "scenarios": args.scenarios,
        "formats": args.formats,
        "repeats": args.repeats,
        "rounds": args.rounds,
        "warmup_conversions_per_process": 1,
        "verification": [],
        "runs": [],
        "summary": [],
    }
    results_path = output / "results.json"

    def save() -> None:
        results_path.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")

    def run(command: list[str]) -> str:
        evidence["commands"].append(command)
        save()
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            evidence["failure"] = {"command": command, "returncode": result.returncode,
                                   "stdout": result.stdout, "stderr": result.stderr}
            save()
            raise RuntimeError(f"command failed; see {results_path}:\n{result.stderr}")
        return result.stdout

    executables = {}
    for variant, contents in (("baseline", baseline_source), ("candidate", candidate_source)):
        directory = output / variant
        directory.mkdir()
        source = directory / "ExternalTextSubtitleConverter.swift"
        source.write_bytes(contents)
        driver = directory / "main.swift"
        driver.write_bytes(driver_source)
        executable = directory / "converter"
        evidence["source_sha256"][variant] = digest(contents)
        run([compiler, *flags, str(source), str(driver), "-o", str(executable)])
        evidence["executables_sha256"][variant] = digest(executable.read_bytes())
        executables[variant] = str(executable)

    fixtures = output / "fixtures"
    fixtures.mkdir()
    for count in args.sizes:
        for scenario in args.scenarios:
            for format_name in args.formats:
                case = {"cues": count, "scenario": scenario, "format": format_name}
                name = f"{count}-{scenario}-{format_name}"
                input_path = fixtures / f"{name}.txt"
                input_path.write_bytes(fixture(count, scenario, format_name))
                expected = fixtures / f"{name}-baseline.ass"
                actual = fixtures / f"{name}-candidate.ass"
                run([executables["baseline"], "emit", format_name, str(input_path), str(expected)])
                run([executables["candidate"], "emit", format_name, str(input_path), str(actual)])
                if actual.read_bytes() != expected.read_bytes():
                    raise RuntimeError(f"byte-for-byte conversion mismatch in {name}")
                if sum(line.startswith(b"Dialogue:") for line in expected.read_bytes().splitlines()) != count:
                    raise RuntimeError(f"fixture did not convert every cue in {name}")
                evidence["verification"].append({**case, "input_sha256": digest(input_path.read_bytes()),
                    "output_sha256": digest(expected.read_bytes()), "input_bytes": input_path.stat().st_size,
                    "output_bytes": expected.stat().st_size})
                samples = {"baseline": [], "candidate": []}
                for repeat in range(args.repeats):
                    order = ["baseline", "candidate"] if repeat % 2 == 0 else ["candidate", "baseline"]
                    for position, variant in enumerate(order):
                        row = json.loads(run([executables[variant], "measure", format_name,
                                              str(input_path), str(expected), str(args.rounds)]))
                        if row["verified_rounds"] != args.rounds or len(row["milliseconds"]) != args.rounds:
                            raise RuntimeError("incomplete measurement row")
                        if any(not math.isfinite(value) or value <= 0 for value in row["milliseconds"]):
                            raise RuntimeError("invalid measurement duration")
                        row.update(case, variant=variant, repeat=repeat, pair_position=position,
                                   sequence=len(evidence["runs"]))
                        evidence["runs"].append(row)
                        samples[variant].append(statistics.median(row["milliseconds"]))
                        save()
                before, after = (statistics.median(samples[variant]) for variant in ("baseline", "candidate"))
                summary = {**case, "baseline_median_ms": before, "candidate_median_ms": after,
                           "reduction_percent": 100 * (1 - after / before),
                           "process_median_range_ms": {variant: [min(values), max(values)]
                                                       for variant, values in samples.items()}}
                evidence["summary"].append(summary)
                save()
                print(json.dumps(summary), flush=True)
    if ((ROOT / SOURCE).read_bytes() != candidate_source or DRIVER.read_bytes() != driver_source
            or Path(__file__).read_bytes() != runner_source):
        raise RuntimeError("source, driver, or runner changed during measurement")
    evidence["status"] = "complete"
    save()


if __name__ == "__main__":
    main()
