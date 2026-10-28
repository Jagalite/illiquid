#!/usr/bin/env python3
"""Compare complete production subtitle association before/after borrowed fuzzy prefixes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
SOURCES = [
    "Sources/IlliquidCore/Playlist/ExternalSubtitleMatcher.swift",
    "Sources/IlliquidCore/Utilities/MediaFileSupport.swift",
    "Sources/IlliquidCore/Utilities/NaturalFilenameOrdering.swift",
]
TESTS = [
    "Tests/IlliquidCoreTests/ExternalSubtitleMatcherTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleMatcherEmptyTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleTokenizationTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleQualifierStorageTests.swift",
    "Tests/IlliquidCoreTests/ExternalSubtitleCandidateTraversalTests.swift",
]
LANGUAGES = ["de", "en", "es", "fr", "ja", "pt", "ru", "zh"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def fixtures():
    cases = []

    def add(name, media, subtitles, assignments=None, timed=True, fuzzy_scores=0):
        expected = {name: [] for name in media}
        expected.update(assignments or {})
        cases.append(dict(name=name, media=media, subtitles=subtitles, expected=expected,
                          timed=timed, expected_fuzzy_scores=fuzzy_scores))

    def fuzzy(name, count, languages, prefix="Example.Series", unique=False, qualified=True, timed=True):
        stems = [f"{prefix}.Episode.{i:06d}" for i in range(count)]
        if unique:
            stems[1:] = [f"{prefix}.Episode.Season.{i:06d}" for i in range(1, count)]
        suffix = ".1080p.WEB-DL.x265" if qualified else ""
        media = [stem + suffix + ".mkv" for stem in stems]
        subtitles = [prefix + "." + lang + ".srt" for lang in languages]
        assignments = {media[0]: subtitles} if unique or count == 1 else {}
        add(name, media, list(reversed(subtitles)), assignments,
            fuzzy_scores=count * len(languages), timed=timed)

    fuzzy("fuzzy_1_1", 1, ["en"])
    fuzzy("fuzzy_16_1", 16, ["en"])
    fuzzy("fuzzy_256_1", 256, ["en"])
    fuzzy("fuzzy_4096_1", 4096, ["en"])
    fuzzy("fuzzy_256_8", 256, LANGUAGES)
    fuzzy("fuzzy_4096_8", 4096, LANGUAGES)
    fuzzy("fuzzy_long_256_8", 256, LANGUAGES,
          prefix="ExtraordinaryChronicles.of.the.Northern.Realms")
    fuzzy("fuzzy_unicode_256_8", 256, LANGUAGES, prefix="Café.東京.Épisode")
    fuzzy("fuzzy_unique_256_8", 256, LANGUAGES, unique=True)
    for count in [256, 4096]:
        stems = [f"Example.Series.Episode.{i:06d}" for i in range(count)]
        media = [stem + ".1080p.WEB-DL.x265.mkv" for stem in stems]
        subtitles = [stem + ".en.srt" for stem in stems]
        add(f"exact_{count}", media, list(reversed(subtitles)),
            {m: [s] for m, s in zip(media, subtitles)})
    media = [f"Example.Series.Episode.{i:06d}.mkv" for i in range(256)]
    add("unrelated_256", media, [f"Unrelated.{i:06d}.en.srt" for i in range(256)])
    add("empty_256", media, [])

    # Follow-up cases are opt-in for timing, but always included in full
    # independent output verification. Preserve the original default cohort.
    fuzzy("plain_prefix_256_8", 256, LANGUAGES, qualified=False, timed=False)

    def ancestor(name, count, languages, prefix="Example.Series", qualified=False):
        stems = [f"{prefix}.Episode.{i:06d}" for i in range(count)]
        suffix = ".1080p.WEB-DL.x265" if qualified else ""
        media = [stem + suffix + ".mkv" for stem in stems]
        assignments = {
            media[i]: [stem + ".Extended." + language + ".srt" for language in languages]
            for i, stem in enumerate(stems)
        }
        subtitles = [subtitle for values in assignments.values() for subtitle in values]
        add(name, media, list(reversed(subtitles)), assignments, timed=False,
            fuzzy_scores=count * len(languages))

    for count in [1, 16, 256, 4096]:
        ancestor(f"ancestor_plain_{count}_1", count, ["en"])
    ancestor("ancestor_plain_256_8", 256, LANGUAGES)
    ancestor("ancestor_long_plain_256_8", 256, LANGUAGES,
             prefix="ExtraordinaryChronicles.of.the.Northern.Realms")
    ancestor("ancestor_unicode_plain_256_8", 256, LANGUAGES, prefix="Café.東京.Épisode")
    ancestor("ancestor_qualified_256_8", 256, LANGUAGES, qualified=True)
    ancestor("ancestor_long_qualified_256_8", 256, LANGUAGES,
             prefix="ExtraordinaryChronicles.of.the.Northern.Realms", qualified=True)
    plain_media = [f"Example.Series.Episode.{i:06d}.mkv" for i in range(256)]
    plain_subtitles = [name.removesuffix(".mkv") + ".en.srt" for name in plain_media]
    add("exact_plain_256", plain_media, list(reversed(plain_subtitles)),
        {media: [subtitle] for media, subtitle in zip(plain_media, plain_subtitles)}, timed=False)

    # Independent behavior oracles outside timing complement the unchanged
    # regression suites, including both directions of fuzzy prefix matching.
    add("edge_fuzzy_ancestor", ["Documentary.Film.mkv", "Documentary.Film.Remastered.mkv"],
        ["Documentary.Film.Extended.en.srt"],
        {"Documentary.Film.mkv": ["Documentary.Film.Extended.en.srt"]}, timed=False)
    add("edge_short_prefix_rejected", ["Cat.Episode.One.mkv"], ["Cat.en.srt"], timed=False)
    add("edge_four_character_prefix", ["Film.Episode.One.mkv"], ["Film.en.srt"],
        {"Film.Episode.One.mkv": ["Film.en.srt"]}, timed=False)
    add("edge_release_specific", ["Movie.1080p.mkv", "Movie.2160p.mp4"],
        ["Movie.en.srt", "Movie.2160p.en.srt"],
        {"Movie.2160p.mp4": ["Movie.2160p.en.srt"]}, timed=False)
    add("edge_title_language", ["The.Last.of.mkv", "The.Last.of.Us.1080p.mkv"],
        ["THE.LAST.OF.US.eng.srt"],
        {"The.Last.of.Us.1080p.mkv": ["THE.LAST.OF.US.eng.srt"]}, timed=False)
    add("edge_duplicates", ["Feature.mkv", "Feature.mkv", "Readme.txt"],
        ["Feature.fr.srt", "Feature.en.srt", "Feature.en.srt"],
        {"Feature.mkv": ["Feature.en.srt", "Feature.en.srt", "Feature.fr.srt"]}, timed=False)
    return cases


def ratio_summary(values):
    # Descriptive paired bootstrap interval; a single shared CI machine is not
    # a representative hardware population. Keep raw observations for review.
    rng = random.Random(20261028)
    boot = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(5000))
    return {"median": statistics.median(values), "min": min(values), "max": max(values),
            "bootstrap_95_percent": [boot[124], boot[4874]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=16)
    parser.add_argument("--target-ms", type=int, default=250)
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--baseline-ref", default=BASELINE,
                        help="Baseline commit; defaults to the original prefix-copy study")
    parser.add_argument("--case", action="append", dest="selected_cases",
                        help="Time this case (repeatable); all output fixtures are still verified")
    args = parser.parse_args()
    if args.pairs < 4 or args.pairs % 2 or args.target_ms <= 0:
        parser.error("pairs must be even and >= 4; target-ms must be positive")
    swift = shutil.which("swift")
    if swift is None:
        parser.error("Swift 6.1 or newer is required")
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("Use a new or empty output directory")
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["SWIFT_DETERMINISTIC_HASHING"] = "1"
    commands = []

    def command(argv, log=None, timeout=600):
        argv = [str(arg) for arg in argv]
        result = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=timeout)
        commands.append({"argv": argv, "returncode": result.returncode})
        write_json(output / "commands.json", commands)
        if log:
            (output / log).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Command failed: {argv}\n{result.stdout[-3000:]}\n{result.stderr[-9000:]}")
        return result.stdout

    baseline_commit = command(["git", "rev-parse", "--verify",
                               args.baseline_ref + "^{commit}"]).strip()
    manifest = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": baseline_commit,
        "candidate_commit": command(["git", "rev-parse", "HEAD"]).strip(),
        "candidate_status": command(["git", "status", "--porcelain=v1"]),
        "platform": platform.platform(), "machine": platform.machine(),
        "compiler": command([swift, "--version"]).strip(),
        "pairs": args.pairs, "target_cpu_ms": args.target_ms,
        "hashing": "SWIFT_DETERMINISTIC_HASHING=1",
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "driver_sha256": digest((HERE / "Driver.swift").read_bytes()),
        "sources": {}, "tests": {}, "binaries": {},
        "protocol": "fresh process per sample; balanced AB/BA; separately compiled production module; full association, result consumption and destruction",
        "qualification": "isolated production component; no app startup, UI, decoding, playback, RSS or allocation-count claim",
    }
    source_data = {}
    for path in SOURCES:
        baseline = command(["git", "show", f"{baseline_commit}:{path}"]).encode()
        candidate = (ROOT / path).read_bytes()
        source_data[path] = {"baseline": baseline, "candidate": candidate}
        manifest["sources"][path] = {
            variant: {"sha256": digest(data),
                      "git_blob": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()}
            for variant, data in source_data[path].items()
        }
    patch = "".join(
        "".join(difflib.unified_diff(values["baseline"].decode().splitlines(True),
                                    values["candidate"].decode().splitlines(True),
                                    fromfile="baseline/" + path, tofile="candidate/" + path))
        for path, values in source_data.items()
    )
    (output / "production.diff").write_text(patch)
    for path in TESTS:
        manifest["tests"][path] = digest((ROOT / path).read_bytes())
    cases = fixtures()
    by_name = {case["name"]: case for case in cases}
    if args.selected_cases:
        if len(set(args.selected_cases)) != len(args.selected_cases):
            parser.error("--case names must be unique")
        if any(name not in by_name for name in args.selected_cases):
            parser.error("Unknown --case; available cases: " + ", ".join(by_name))
        timed_specs = [by_name[name] for name in args.selected_cases]
    else:
        timed_specs = [case for case in cases if case["timed"]]
    manifest["timed_cases"] = [case["name"] for case in timed_specs]
    cases_path = output / "cases.json"
    write_json(cases_path, cases)
    manifest["cases_sha256"] = digest(cases_path.read_bytes())
    write_json(output / "manifest.json", manifest)
    shutil.copyfile(__file__, output / "runner.snapshot.py")
    shutil.copyfile(HERE / "Driver.swift", output / "driver.snapshot.swift")
    binaries = {}
    tests = []
    for variant in ["baseline", "candidate"]:
        package = output / variant
        for directory in ["Sources/IlliquidCore", "Sources/Driver", "Tests/IlliquidCoreTests"]:
            (package / directory).mkdir(parents=True, exist_ok=True)
        for path in SOURCES:
            (package / "Sources/IlliquidCore" / Path(path).name).write_bytes(source_data[path][variant])
        for path in TESTS:
            shutil.copyfile(ROOT / path, package / "Tests/IlliquidCoreTests" / Path(path).name)
        shutil.copyfile(HERE / "Driver.swift", package / "Sources/Driver/Driver.swift")
        (package / "Package.swift").write_text("""// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "SubtitleFuzzyPrefix", platforms: [.macOS("26.0")], targets: [
    .target(name: "IlliquidCore"),
    .executableTarget(name: "Driver", dependencies: ["IlliquidCore"]),
    .testTarget(name: "IlliquidCoreTests", dependencies: ["IlliquidCore"])
])
""")
        flags = ["--package-path", package, "--jobs", "2", "-Xswiftc", "-warnings-as-errors",
                 "--cache-path", output / "cache", "--config-path", output / "config",
                 "--security-path", output / "security"]
        # Isolated CI runners have no Kyoto installation or shared .build.
        # All builds in this runner are serialized.
        if not args.skip_tests:
            for config in ["debug", "release"]:
                print(f"Testing {variant} {config}", flush=True)
                log = f"tests-{variant}-{config}.log"
                command([swift, "test", *flags, "-c", config], log=log)
                tests.append({"variant": variant, "configuration": config, "status": "passed",
                              "log": log, "log_sha256": digest((output / log).read_bytes())})
                write_json(output / "tests.json", tests)
        command([swift, "build", *flags, "-c", "release", "--product", "Driver"],
                log=f"build-{variant}.log")
        bin_dir = Path(command([swift, "build", "--package-path", package,
                                "-c", "release", "--show-bin-path"]).strip())
        binaries[variant] = bin_dir / "Driver"
        manifest["binaries"][variant] = digest(binaries[variant].read_bytes())
        write_json(output / "manifest.json", manifest)

    verified = {}
    for variant in binaries:
        verified[variant] = json.loads(command([binaries[variant], cases_path, "--verify"],
                                               log=f"verify-{variant}.json"))
    if verified["baseline"] != verified["candidate"]:
        raise ValueError("Verification reports differ")
    write_json(output / "parity.json", {"status": "passed", "cases": len(cases),
                                       "input_orders": 2, "records": verified["candidate"]})

    def timed(variant, case, iterations):
        row = json.loads(command([binaries[variant], cases_path, case, iterations, 3], timeout=180))
        if row["checksum"] != row["expectedChecksum"]:
            raise ValueError("Timing checksum mismatch")
        return row

    observations = []
    calibrations = []
    for spec in timed_specs:
        case = spec["name"]
        pilot = {variant: timed(variant, case, 1) for variant in binaries}
        slowest = max(row["cpuNsPerAssociation"] for row in pilot.values())
        iterations = max(5, min(100000, math.ceil(args.target_ms * 1e6 / slowest)))
        calibrations.append({"case": case, "iterations": iterations, "pilots": pilot})
        write_json(output / "calibration.json", calibrations)
        print(f"Measuring {case}: {iterations} full associations per sample", flush=True)
        for pair in range(args.pairs):
            order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
            for position, variant in enumerate(order):
                row = timed(variant, case, iterations)
                row.update(variant=variant, pair=pair, position=position)
                observations.append(row)
                with (output / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps(row, sort_keys=True) + "\n")

    summary = {"pairs": args.pairs, "cases": []}
    for spec in timed_specs:
        case = spec["name"]
        rows = {variant: [r for r in observations if r["name"] == case and r["variant"] == variant]
                for variant in binaries}
        entry = {"name": case, "media_count": len(spec["media"]),
                 "subtitle_count": len(spec["subtitles"]),
                 "expected_fuzzy_scores": spec["expected_fuzzy_scores"]}
        for metric in ["cpuNsPerAssociation", "wallNsPerAssociation"]:
            entry[metric] = {
                "baseline_median": statistics.median(r[metric] for r in rows["baseline"]),
                "candidate_median": statistics.median(r[metric] for r in rows["candidate"]),
                "paired_ratio": ratio_summary([c[metric] / b[metric]
                    for b, c in zip(rows["baseline"], rows["candidate"])]),
            }
        summary["cases"].append(entry)
    write_json(output / "summary.json", summary)
    write_json(output / "completion.json", {"status": "passed", "tests_run": len(tests),
        "parity_cases": len(cases), "samples": len(observations),
        "finished_utc": datetime.now(timezone.utc).isoformat()})
    print(json.dumps(summary, indent=2, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
