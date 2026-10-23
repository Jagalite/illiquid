#!/usr/bin/env python3
"""Qualify the production recursive media scanner against its frozen original."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASELINE = "7f9ba073394b77a908e0589447c6edc8d10b832c"
EXTRACTOR = ROOT / "Benchmarks/SourceTreeVisibility/run.py"
START, END = "enum SourceRecursiveMediaLoader {", "\nstruct SourceTreeDisplayRow:"
TESTS = ["SourceRecursiveMediaLoaderTests.swift", "SourceMediaOrganizationTests.swift"]
CASES = ["supported_only", "supported_unicode", "mixed_90percent_nonmedia", "directory_heavy",
         "symlink_controls", "explicit_overlap", "metadata"]
PACKAGE = '''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "RecursiveMediaScanQualification", platforms: [.macOS("26.0")],
    products: [.executable(name: "RecursiveMediaScanBenchmark", targets: ["RecursiveMediaScanBenchmark"])],
    targets: [
        .target(name: "IlliquidCore"),
        .target(name: "IlliquidApp", dependencies: ["IlliquidCore"],
                swiftSettings: [.unsafeFlags(["-enable-testing"])]),
        .executableTarget(name: "RecursiveMediaScanBenchmark", dependencies: ["IlliquidCore", "IlliquidApp"]),
        .testTarget(name: "IlliquidAppTests", dependencies: ["IlliquidCore", "IlliquidApp"]),
    ]
)
'''


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def scanner(source):
    text = source.decode()
    if text.count(START) != 1 or text.count(END) != 1 or text.index(END) <= text.index(START):
        raise ValueError("Scanner extraction boundaries changed")
    return text[text.index(START):text.index(END)].encode()


class Runner:
    def __init__(self, args):
        self.args, self.output = args, args.output.resolve()
        if self.output.exists() and any(self.output.iterdir()):
            raise ValueError("Output must be new or empty; previous evidence is not overwritten")
        self.output.mkdir(parents=True, exist_ok=True)
        self.swift = args.swift or shutil.which("swift")
        if not self.swift:
            raise ValueError("Put Swift on PATH or pass --swift /path/to/swift")
        self.env = os.environ.copy()
        cache = self.output / "module-cache"
        cache.mkdir()
        self.env.update(SWIFTPM_MODULECACHE_OVERRIDE=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
        self.packages, self.manifests, self.binaries, self.fixtures = {}, {}, {}, {}
        self.inputs = {path: digest(path.read_bytes()) for path in
                       [HERE / "run.py", HERE / "Driver.swift", EXTRACTOR,
                        HERE / "baseline/manifest.json", HERE / "baseline/SourceRecursiveMediaLoader.swift"]}

    def execute(self, command, label, timeout=900, combined=False):
        command = list(map(str, command))
        began = time.monotonic()
        result = subprocess.run(command, cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=timeout)
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps(dict(label=label, command=command, returncode=result.returncode,
                elapsed_seconds=time.monotonic() - began, stdout=result.stdout, stderr=result.stderr)) + "\n")
        if result.returncode:
            raise RuntimeError(f"{label} failed ({result.returncode}):\n" + (result.stdout + result.stderr)[-12000:])
        return result.stdout + result.stderr if combined else result.stdout

    def prepare(self):
        frozen = json.loads((HERE / "baseline/manifest.json").read_text())
        original = (HERE / "baseline/SourceRecursiveMediaLoader.swift").read_bytes()
        if frozen["revision"] != BASELINE or digest(original) != frozen["snapshot_sha256"]:
            raise ValueError("Frozen scanner revision or hash changed")
        if (frozen["start"], frozen["end"]) != (START, END):
            raise ValueError("Frozen scanner extraction boundary changed")
        # Reuse the existing guarded declaration extractor, not its CLI,
        # historical baseline, staging adapters, or benchmark implementation.
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location("source_tree_extractor", EXTRACTOR)
        extractor = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(extractor)
        current, records = extractor.snapshot(lambda name: (ROOT / name).read_bytes())
        sidebar = "Sources/IlliquidApp/SidebarValues.swift"
        candidate_scanner = scanner(current[sidebar])
        for variant in ["baseline", "candidate"]:
            files = dict(current)
            if variant == "baseline":
                if files[sidebar].count(candidate_scanner) != 1:
                    raise ValueError("Ambiguous scanner substitution")
                files[sidebar] = files[sidebar].replace(candidate_scanner, original, 1)
            files["Sources/RecursiveMediaScanBenchmark/Driver.swift"] = (HERE / "Driver.swift").read_bytes()
            files["Package.swift"] = PACKAGE.encode()
            for name in TESTS:
                files["Tests/IlliquidAppTests/" + name] = (ROOT / "Tests/IlliquidAppTests" / name).read_bytes()
            package = self.output / "packages" / variant
            manifest = dict(variant=variant, baseline=frozen, shared_production=records,
                scanner_sha256=digest(original if variant == "baseline" else candidate_scanner),
                staged={}, adaptations=[])
            for relative, raw in files.items():
                adapted, changes = raw, []
                if platform.system() == "Linux":
                    replacements = {
                        "MediaSidecarReader.swift": (b"import Darwin\n", b"import Glibc\n"),
                        "NFOMetadataHints.swift": (b"import Foundation\n", b"import Foundation\nimport FoundationXML\n"),
                        "SourceMediaOrganizationTests.swift": (
                            b'appendingPathComponent("media-sidecars-" + UUID().uuidString)',
                            b'appendingPathComponent("media-sidecars-" + UUID().uuidString, isDirectory: true)'),
                    }
                    if Path(relative).name in replacements:
                        old, new = replacements[Path(relative).name]
                        if raw.count(old) != 1:
                            raise ValueError(f"Linux adaptation boundary changed: {relative}")
                        adapted = raw.replace(old, new, 1)
                        changes = [dict(original=old.decode(), replacement=new.decode())]
                destination = package / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(adapted)
                manifest["staged"][relative] = dict(source_sha256=digest(raw), compiled_sha256=digest(adapted))
                if changes:
                    manifest["adaptations"].append(dict(file=relative, changes=changes))
            self.packages[variant], self.manifests[variant] = package, manifest
            write_json(self.output / f"{variant}-sources.json", manifest)
        # Every dependency, fixture test and driver is byte-identical between
        # variants; only the complete scanner enum may differ.
        for path in self.packages["baseline"].rglob("*.swift"):
            relative = path.relative_to(self.packages["baseline"])
            left, right = path.read_bytes(), (self.packages["candidate"] / relative).read_bytes()
            if str(relative) == sidebar:
                left, right = left.replace(scanner(left), b"SCANNER", 1), right.replace(scanner(right), b"SCANNER", 1)
            if left != right:
                raise ValueError(f"Unrelated variant difference: {relative}")
        environment = dict(started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            platform=platform.platform(), machine=platform.machine(), python=sys.version,
            swift=self.execute([self.swift, "--version"], "swift-version").strip(),
            head=self.execute(["git", "rev-parse", "HEAD"], "revision").strip(),
            worktree=self.execute(["git", "status", "--short"], "worktree"),
            baseline=BASELINE, driver_hashes={str(p.relative_to(ROOT)): h for p, h in self.inputs.items()},
            pairs=self.args.pairs, iterations=self.args.iterations, scale=self.args.scale, cases=self.args.cases,
            exploratory=self.args.pairs < 8, ordering="AB/BA alternating per fixture; fresh process per member",
            measurement="CLOCK_PROCESS_CPUTIME_ID and DispatchTime around complete synchronous read(); one warm-up per process; input decoding and every full receipt comparison outside both clocks",
            cpu_affinity=sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None)
        if Path("/proc/cpuinfo").exists():
            environment["cpu_model"] = next((line.split(":", 1)[1].strip() for line in
                Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "")
        write_json(self.output / "environment.json", environment)
        self.check_sources()

    def check_sources(self):
        for path, expected in self.inputs.items():
            if digest(path.read_bytes()) != expected:
                raise ValueError(f"Harness input changed during run: {path}")
        for variant, manifest in self.manifests.items():
            for relative, record in manifest["staged"].items():
                if digest((self.packages[variant] / relative).read_bytes()) != record["compiled_sha256"]:
                    raise ValueError(f"Staged source changed: {variant}/{relative}")

    def swift_command(self, variant, action, configuration):
        command = [self.swift, action, "--package-path", self.packages[variant],
            "--scratch-path", self.output / "build" / variant, "--cache-path", self.output / "swiftpm-cache",
            "--config-path", self.output / "swiftpm-config", "--security-path", self.output / "swiftpm-security",
            "--jobs", self.args.jobs, "--configuration", configuration]
        if platform.system() == "Linux":
            command.append("--use-integrated-swift-driver")
        return command

    def test(self):
        runs = []
        for configuration in self.args.configurations:
            for variant in ["baseline", "candidate"]:
                self.check_sources()
                print(f"Testing {variant} ({configuration}): {', '.join(TESTS)}", flush=True)
                output = self.execute(self.swift_command(variant, "test", configuration) +
                    ["--disable-xctest", "--enable-swift-testing", "--no-parallel"], f"tests-{variant}-{configuration}", combined=True)
                (self.output / f"tests-{variant}-{configuration}.txt").write_text(output)
                runs.append(dict(variant=variant, configuration=configuration, passed=True))
        write_json(self.output / "tests.json", dict(suites=TESTS, runs=runs))
        self.check_sources()

    def build(self):
        for variant in ["baseline", "candidate"]:
            print(f"Building optimized {variant} scanner", flush=True)
            command = self.swift_command(variant, "build", "release")
            self.execute(command + ["--product", "RecursiveMediaScanBenchmark"], f"build-{variant}")
            path = self.execute(command + ["--show-bin-path"], f"bin-path-{variant}").strip()
            self.binaries[variant] = Path(path) / "RecursiveMediaScanBenchmark"
            self.manifests[variant]["binary_sha256"] = digest(self.binaries[variant].read_bytes())
            write_json(self.output / f"{variant}-sources.json", self.manifests[variant])
        self.check_sources()

    def make_fixtures(self):
        def file(path, contents=""):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
            return path

        scale = self.args.scale
        for name in self.args.cases:
            directory = self.output / "fixtures" / name
            directory.mkdir(parents=True)
            roots, files, count = [directory], [], None
            if name == "supported_only":
                count = 1000 * scale
                for i in range(count):
                    file(directory / f"Series{i // 50}/Episode{i}.mkv")
            elif name == "supported_unicode":
                count = 1000 * scale
                for i in range(count):
                    folder = ["Séries", "Se\u0301ries", "シリーズ"][(i // 50) % 3] + str(i // 50)
                    title = ["Café", "Cafe\u0301", "日本語"][i % 3] + f" Episode{i}.mkv"
                    file(directory / folder / title)
            elif name == "mixed_90percent_nonmedia":
                count = 200 * scale
                for i in range(2000 * scale):
                    ext = "mkv" if i % 10 == 0 else ["jpg", "txt", "srt", "nfo"][i % 4]
                    file(directory / f"Series{i // 100}/Entry{i}.{ext}")
            elif name == "directory_heavy":
                count = 120 * scale
                for i in range(1200 * scale):
                    folder = directory / f"Series{i // 40}/Subfolder{i}"
                    folder.mkdir(parents=True)
                    if i % 10 == 0:
                        file(folder / "Episode.mkv")
            elif name == "symlink_controls":
                library = directory / "library"
                for i in range(50 * scale):
                    file(library / f"Original{i}.mkv")
                    file(directory / f"targets/Movie{i}.mkv")
                    file(directory / f"targets/Notes{i}.txt")
                    for alias, target in [(f"extensionless{i}", f"../targets/Movie{i}.mkv"),
                        (f"misleading{i}.txt", f"../targets/Movie{i}.mkv"),
                        (f"unsupported{i}.mkv", f"../targets/Notes{i}.txt"),
                        (f"chain{i}", f"misleading{i}.txt")]:
                        (library / alias).symlink_to(target)
                (library / "broken.mkv").symlink_to("absent.mkv")
                (library / "directory-link").symlink_to("../targets", target_is_directory=True)
                for relative in [".hidden/Secret.mkv", "Bundle.app/Contents/Resources/Inside.mkv",
                                 "日本語/Cafe\u0301.MKV", "Kelvin.M\u212aV", "Space # percent %.mp4"]:
                    file(library / relative)
                os.mkfifo(library / "pipe.mkv")
                alias = directory / "selected-root"
                alias.symlink_to("library", target_is_directory=True)
                roots = [alias]
            elif name == "explicit_overlap":
                library = directory / "library"
                media = [file(library / f"Season{i // 10}/Episode{i}.mkv") for i in range(30 * scale)]
                note = file(library / "notes.txt")
                missing = library / "missing.bin"
                roots = [library, library / "Season0", library]
                files = [media[0], media[-1], note, missing, media[0], note, missing]
                count = len(media) + 2
            elif name == "metadata":
                for i in range(20 * scale):
                    movie = directory / f"Movies/Movie{i}/opaque{{edition-Directors Cut}}.1080p.mkv"
                    file(movie)
                    file(movie.with_suffix(".nfo"), f"<movie><title>Sidecar Film {i}</title><year>1999</year><uniqueid type='imdb'>tt{12345+i}</uniqueid></movie>")
                    file(movie.parent / "poster.jpg")
                    episode = directory / f"Show (2020)/Season 01/S01E{i+1:02d}.1080p.mkv"
                    file(episode)
                    file(episode.with_suffix(".nfo"), f"<episodedetails><showtitle>Sidecar Show</showtitle><title>Episode {i+1}</title><season>1</season><episode>{i+1}</episode></episodedetails>")
                file(directory / "Show (2020)/tvshow.nfo", "<tvshow><title>Sidecar Show</title><year>2020</year><uniqueid type='tvdb'>456</uniqueid></tvshow>")
                file(directory / "Show (2020)/Show.2020.01.01.mkv")
                file(directory / "Extras/Movie (2001)-trailer.mp4")
                count = 40 * scale + 2
            spec = dict(name=name, roots=list(map(str, roots)), files=list(map(str, files)),
                readsMetadata=name == "metadata", expectedCount=count)
            path = self.output / "fixture-specs" / (name + ".json")
            write_json(path, spec)
            self.fixtures[name] = path

    def measure(self):
        self.make_fixtures()
        receipts = self.output / "receipts"
        receipts.mkdir()
        rows, summary = [], []
        for name, fixture in self.fixtures.items():
            expected, hashes = None, {}
            for variant in ["baseline", "candidate"]:
                path = receipts / f"{name}-{variant}.json"
                data = json.loads(self.execute([self.binaries[variant], "diagnose", fixture, path, 1], f"diagnose-{name}-{variant}"))
                actual = path.read_bytes()
                if expected is not None and actual != expected:
                    raise ValueError(f"Complete ordered receipt differs: {name}")
                expected, hashes[variant] = actual, digest(actual)
                data.update(variant=variant, receipt_sha256=hashes[variant])
                with (self.output / "diagnostics.jsonl").open("a") as log:
                    log.write(json.dumps(data, sort_keys=True) + "\n")
            for pair in range(self.args.pairs):
                order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
                for position, variant in enumerate(order):
                    path = receipts / f"{name}-{variant}.json"
                    data = json.loads(self.execute([self.binaries[variant], "measure", fixture, path,
                        self.args.iterations], f"measure-{name}-{pair}-{variant}"))
                    if data["case"] != name or data["iterations"] != self.args.iterations:
                        raise ValueError("Unexpected timed workload")
                    for metric in ["cpu_ns", "wall_ns"]:
                        if len(data[metric]) != self.args.iterations or any(type(n) is not int or n <= 0 for n in data[metric]):
                            raise ValueError(f"Invalid duration: {metric}")
                    if digest(path.read_bytes()) != hashes[variant]:
                        raise ValueError("Reference receipt changed during measurements")
                    data.update(variant=variant, pair=pair, process_order=position, receipt_sha256=hashes[variant])
                    rows.append(data)
                    with (self.output / "measurements.jsonl").open("a") as log:
                        log.write(json.dumps(data, sort_keys=True) + "\n")
            cell = dict(case=name, count=data["count"], pairs=self.args.pairs, iterations=self.args.iterations)
            for metric in ["cpu_ns", "wall_ns"]:
                values = {variant: [statistics.mean(r[metric]) / 1e6 for r in rows
                    if r["case"] == name and r["variant"] == variant] for variant in ["baseline", "candidate"]}
                base, candidate = values["baseline"], values["candidate"]
                ratio = statistics.median(c / b for b, c in zip(base, candidate))
                cell[metric.removesuffix("_ns") + "_ms"] = dict(
                    baseline=dict(median=statistics.median(base), min=min(base), max=max(base)),
                    candidate=dict(median=statistics.median(candidate), min=min(candidate), max=max(candidate)),
                    median_paired_candidate_over_baseline=ratio, median_paired_reduction_percent=100 * (1-ratio))
            summary.append(cell)
            write_json(self.output / "summary.json", summary)
            parts = [f"{key[:-3]} {cell[key]['baseline']['median']:.3f}->{cell[key]['candidate']['median']:.3f} ms ({cell[key]['median_paired_reduction_percent']:+.1f}% paired reduction)" for key in ["cpu_ms", "wall_ms"]]
            print(f"{name}: {cell['count']} entries; " + "; ".join(parts), flush=True)
        self.check_sources()
        for variant, binary in self.binaries.items():
            if digest(binary.read_bytes()) != self.manifests[variant]["binary_sha256"]:
                raise ValueError(f"Benchmark binary changed: {variant}")

    def export_evidence(self):
        evidence = self.output / "evidence"
        evidence.mkdir(exist_ok=True)
        for path in self.output.iterdir():
            if path.is_file() and path.suffix in {".json", ".jsonl", ".txt"}:
                shutil.copyfile(path, evidence / path.name)
        for directory in ["receipts", "fixture-specs"]:
            if (self.output / directory).exists():
                shutil.copytree(self.output / directory, evidence / directory, dirs_exist_ok=True)
        for path in self.inputs:
            destination = evidence / "harness" / path.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        if self.packages:
            with tarfile.open(evidence / "staged-sources.tar.gz", "w:gz") as archive:
                for package in self.packages.values():
                    for source in sorted(package.rglob("*")):
                        if source.is_file():
                            archive.add(source, arcname=str(source.relative_to(self.output / "packages")), recursive=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["all", "test", "benchmark", "build", "prepare"], default="all")
    parser.add_argument("--swift")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--pairs", type=int, default=8)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--scale", type=int, default=1)
    parser.add_argument("--case", dest="cases", choices=CASES, action="append")
    parser.add_argument("--configuration", dest="configurations", choices=["debug", "release"], action="append")
    args = parser.parse_args()
    args.cases, args.configurations = args.cases or CASES, args.configurations or ["debug", "release"]
    if min(args.jobs, args.pairs, args.iterations, args.scale) < 1 or args.pairs % 2:
        parser.error("Use positive jobs/iterations/scale and an even positive number of AB/BA pairs")
    runner = Runner(args)
    try:
        runner.prepare()
        if args.mode in {"all", "test"}:
            runner.test()
        if args.mode in {"all", "benchmark", "build"}:
            runner.build()
        if args.mode in {"all", "benchmark"}:
            runner.measure()
    finally:
        runner.export_evidence()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Recursive media scan qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
