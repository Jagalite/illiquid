#!/usr/bin/env python3
"""Independently audit attachment benchmark data without running native code.

Usage: python3 Benchmarks/AttachmentAdmission/audit-results.py \
    --results PATH --repo PATH

Required evidence: manifest.json, observations.jsonl, summary.json,
calibration.json, parity.json, fixtures.json. The repository must contain both
measured commits. Production and compiled source hashes are reconstructed from
those commits; copied source snapshots and native binaries are optional.
Available files are checked and omissions are reported explicitly. This script
prints its audit as JSON and does not modify the evidence or repository.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import subprocess

VARIANTS = ("baseline", "candidate")
MODES = ("projection", "setup")
METRICS = ("wall_seconds", "cpu_seconds", "process_max_rss_bytes")
RECEIPT_KEYS = ("snapshot", "input_attachments", "accepted_payload_bytes",
                "rejected_payload_bytes", "accepted_attachment_count",
                "checksum_per_iteration", "ffmpeg_version", "avformat_version",
                "avcodec_version", "avutil_version")
BENCHMARK = "Benchmarks/AttachmentAdmission/"
DEMUXER = "Sources/IlliquidNativePlayback/Media/FFmpegDemuxer.swift"
PRESENTATION = "Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"
BITMAP = "Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def matching(actual, expected) -> bool:
    if actual is None or expected is None:
        return actual is expected
    return math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-15)


def declaration(text: str, start: str, end: str) -> str:
    require(text.count(start) == 1 and text.count(end) == 1, "Source extraction markers changed")
    begin, finish = text.index(start), text.index(end)
    require(begin < finish, "Source extraction markers are out of order")
    result = text[begin:finish]
    require(result.count("{") == result.count("}"), "Source extraction has unbalanced braces")
    return result


class Audit:
    def __init__(self, results: Path, repo: Path):
        self.root = results.resolve(strict=True)
        self.repo = repo.resolve(strict=True)
        self.verified_files = []
        self.omitted = []
        self.manifest = self.load("manifest.json")
        self.sources = {}

    def load(self, name):
        return json.loads((self.root / name).read_text())

    def optional_file(self, path: Path, expected_hash: str, description: str):
        if path.is_file():
            require(digest(path.read_bytes()) == expected_hash, f"File hash mismatch: {description}")
            self.verified_files.append(description)
        else:
            self.omitted.append(description)

    def git_source(self, revision: str, path: str) -> bytes:
        require(re.fullmatch(r"[0-9a-f]{40,64}", revision), "Expected a pinned Git commit hash")
        result = subprocess.run(["git", "show", f"{revision}:{path}"], cwd=self.repo,
                                capture_output=True)
        require(result.returncode == 0,
                f"Cannot read {revision}:{path}; fetch the measured commits before auditing")
        return result.stdout

    def audit_sources(self):
        m = self.manifest
        require(m["candidate_worktree_status"] == "", "Measured candidate worktree was not clean")
        for key, receipt in m["sources"].items():
            variant, path = key.split(":", 1)
            require(variant in VARIANTS, "Unexpected source variant")
            data = self.git_source(m[f"{variant}_revision"], path)
            require(digest(data) == receipt["sha256"] and len(data) == receipt["bytes"],
                    f"Pinned production source hash mismatch: {key}")
            self.sources[key] = data
            self.optional_file(self.root / "sources" / variant / path, receipt["sha256"],
                               f"optional source snapshot: {key}")
        require(set(m["compiled_sources"]) == set(VARIANTS), "Missing compiled-source variant")
        for variant, files in m["compiled_sources"].items():
            for relative, receipt in files.items():
                name = Path(relative).name
                require(Path(relative).parts[0] == variant and ".." not in Path(relative).parts,
                        "Unexpected compiled-source path")
                if name == "ExtractedDeclarations.swift":
                    error = declaration(self.sources[f"{variant}:{PRESENTATION}"].decode(),
                                        "struct PresentationError:", "\nfunc checkOSStatus(")
                    packets = declaration(self.sources[f"{variant}:{BITMAP}"].decode(),
                                          "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")
                    expected = ("import Foundation\n\n" + error + "\n" + packets).encode()
                else:
                    matches = [value for key, value in self.sources.items()
                               if key.startswith(variant + ":") and Path(key.split(":", 1)[1]).name == name]
                    require(len(matches) == 1, f"Ambiguous compiled source: {relative}")
                    expected = matches[0]
                    if name == "FFmpegDemuxer.swift":
                        marker = b"    private static func makeMediaInfo("
                        require(expected.count(marker) == 1, "Projection access marker changed")
                        expected = expected.replace(marker, b"    static func makeMediaInfo(", 1)
                require(digest(expected) == receipt, f"Reconstructed compiled-source mismatch: {relative}")
                self.optional_file(self.root / relative, receipt, f"optional compiled source: {relative}")
        for filename, receipt_key, snapshot in [
            ("run.py", "runner_sha256", "runner.snapshot.py"),
            ("Harness.swift", "harness_sha256", "Harness.swift"),
        ]:
            expected = self.git_source(m["candidate_revision"], BENCHMARK + filename)
            require(digest(expected) == m[receipt_key], f"Measured {filename} differs from pinned Git source")
            self.optional_file(self.root / snapshot, m[receipt_key], f"optional {filename} snapshot")
        for variant in VARIANTS:
            for filename, key in [("libAttachmentProjection.dylib", "library_sha256"),
                                  ("attachment-benchmark", "executable_sha256")]:
                self.optional_file(self.root / variant / filename, m["binaries"][variant][key],
                                   f"native binary: {variant}/{filename}")
        self.optional_file(Path(m["compiler_path"]), m["compiler_sha256"], "native compiler executable")
        for name, library in m["native_libraries"].items():
            self.optional_file(Path(library["path"]), library["sha256"], f"native FFmpeg library: {name}")
        headers = self.root / "ffmpeg-headers.json"
        self.optional_file(headers, m["ffmpeg_headers_manifest_sha256"], "FFmpeg header hash manifest")
        if headers.is_file():
            entries = json.loads(headers.read_text())
            available = 0
            for name, expected in entries.items():
                path = Path(m["ffmpeg_prefix"]) / "include" / name
                if path.is_file():
                    require(digest(path.read_bytes()) == expected, f"Native FFmpeg header mismatch: {name}")
                    available += 1
            if available:
                self.verified_files.append(f"native FFmpeg header contents: {available}/{len(entries)}")
            if available != len(entries):
                self.omitted.append(f"native FFmpeg header contents: {len(entries) - available}/{len(entries)}")

    def audit(self):
        self.audit_sources()
        m = self.manifest
        summary = self.load("summary.json")
        parity = self.load("parity.json")
        calibrations = self.load("calibration.json")
        fixtures = self.load("fixtures.json")
        observations = [json.loads(line) for line in (self.root / "observations.jsonl").read_text().splitlines()]
        measured = [r for r in observations if r["stage"] == "measurement"]
        pairs = m["protocol"]["pairs"]
        cases = {f["name"] for f in fixtures}
        require(len(cases) == len(fixtures) and pairs > 0 and pairs % 2 == 0, "Invalid fixture/pair inventory")
        expected_rows = len(cases) * len(MODES) * pairs * len(VARIANTS)
        require(len(measured) == summary["timed_observations"] == expected_rows, "Incomplete measured matrix")
        require(summary["cases"] == len(cases) and summary["pairs"] == pairs and summary["modes"] == list(MODES),
                "Summary/protocol dimensions differ")
        require(summary["status"] == "complete", "Benchmark did not complete")
        require(set(parity) == cases, "Missing or extra parity case")
        for row in observations:
            require(row["stage"] in ("calibration", "measurement") and row["case"] in cases
                    and row["mode"] in MODES and row["variant"] in VARIANTS, "Unexpected observation identity")
            require(row["iterations"] > 0, "Invalid iteration count")
            require({key: row[key] for key in RECEIPT_KEYS} == parity[row["case"]], "Full output parity mismatch")
            require(int(row["checksum"]) == (int(row["checksum_per_iteration"]) * row["iterations"]) % (1 << 64),
                    "Consumed result checksum mismatch")
            require(math.isfinite(row["wall_seconds"]) and row["wall_seconds"] > 0
                    and math.isfinite(row["cpu_seconds"]) and row["cpu_seconds"] >= 0, "Invalid timing value")
            require(row["process_max_rss_bytes"] >= row["process_max_rss_before_bytes"] > 0, "Invalid peak RSS")
        for fixture in fixtures:
            receipt = parity[fixture["name"]]
            for key in ("accepted_payload_bytes", "rejected_payload_bytes"):
                require(fixture[key] == receipt[key], "Fixture manifest/payload receipt mismatch")
            accepted = sum(a["bytes"] for a in receipt["input_attachments"] if a["supported_font"])
            rejected = sum(a["bytes"] for a in receipt["input_attachments"] if not a["supported_font"])
            output = receipt["snapshot"]["attachments"]
            require(accepted == fixture["accepted_payload_bytes"] and rejected == fixture["rejected_payload_bytes"],
                    "Input attachment classification/byte totals differ")
            require(sum(a["bytes"] for a in output) == accepted
                    and len(output) == receipt["accepted_attachment_count"]
                    == sum(a["supported_font"] for a in receipt["input_attachments"]),
                    "Returned attachment inventory differs")
            for attachment in output:
                # The fixture generator repeats bytes 0...255. These are labeled
                # font payloads for admission testing, not valid font-file parsing.
                count = attachment["bytes"]
                pattern = bytes(range(256)) * (count // 256) + bytes(range(count % 256))
                require(attachment["supported_font"] and digest(pattern) == attachment["sha256"],
                        "Accepted payload differs from deterministic fixture bytes")
            if fixture["name"] == "cover-png":
                require(not output and any(s["kind"] == "video" and s["codec_name"] == "png"
                        and s["disposition"] & 1024 for s in receipt["snapshot"]["streams"]), "Cover-image control changed")
            paths = [self.root / "fixtures" / fixture["filename"],
                     self.root.parent / "attachment-fixtures" / fixture["filename"], Path(fixture["path"])]
            available = next((path for path in paths if path.is_file()), None)
            if available:
                require(available.stat().st_size == fixture["size_bytes"], "Fixture file size differs")
                self.optional_file(available, fixture["sha256"], f"native fixture: {fixture['name']}")
            else:
                self.omitted.append(f"native fixture bytes: {fixture['name']}")

        expected_cells = {(case, mode) for case in cases for mode in MODES}
        require(Counter((s["case"], s["mode"]) for s in summary["results"]) == Counter(expected_cells),
                "Missing or duplicate summary cell")
        results = []
        for reported in summary["results"]:
            case, mode = reported["case"], reported["mode"]
            require(reported["pairs"] == pairs and all(reported[key] == parity[case][key]
                    for key in ("accepted_payload_bytes", "rejected_payload_bytes")), "Summary cell dimensions/payload totals differ")
            rows = [r for r in measured if r["case"] == case and r["mode"] == mode]
            expected = Counter({(pair, variant): 1 for pair in range(pairs) for variant in VARIANTS})
            require(Counter((r["pair"], r["variant"]) for r in rows) == expected, "Missing or duplicate measurement")
            require(len({r["iterations"] for r in rows}) == 1, "Paired workloads have unequal iterations")
            for row in rows:
                order = VARIANTS if row["pair"] % 2 == 0 else tuple(reversed(VARIANTS))
                require(row["order_index"] == order.index(row["variant"]), "AB/BA ordering mismatch")
            recomputed = {"case": case, "mode": mode, "iterations": rows[0]["iterations"]}
            for metric in METRICS:
                differences = []
                for pair in range(pairs):
                    values = {r["variant"]: r[metric] for r in rows if r["pair"] == pair}
                    differences.append(100 * (values["candidate"] / values["baseline"] - 1)
                                       if values["baseline"] > 0 else None)
                valid = [x for x in differences if x is not None]
                median = statistics.median(valid) if valid else None
                medians = {variant: statistics.median(r[metric] / (r["iterations"] if metric.endswith("seconds") else 1)
                                                      for r in rows if r["variant"] == variant) for variant in VARIANTS}
                published = reported[metric]
                require(len(published["paired_percent_changes"]) == pairs
                        and all(matching(a, b) for a, b in zip(differences, published["paired_percent_changes"])),
                        f"Paired differences disagree: {case}/{mode}/{metric}")
                require(matching(median, published["paired_median_percent_change"])
                        and all(matching(medians[v], published[v + "_median"]) for v in VARIANTS)
                        and sum(x < 0 for x in valid) == published["candidate_lower_pairs"],
                        f"Summary statistics disagree: {case}/{mode}/{metric}")
                recomputed[metric] = {**medians, "paired_percent_changes": differences,
                                      "paired_median_percent_change": median, "candidate_lower_pairs": sum(x < 0 for x in valid)}
            for variant in VARIANTS:
                wall = [r["wall_seconds"] for r in rows if r["variant"] == variant]
                published = reported["sample_wall_seconds"][variant]
                require(matching(min(wall), published["minimum"]) and matching(max(wall), published["maximum"])
                        and sum(x < .005 for x in wall) == published["observations_below_5ms"], "Sample duration summary disagrees")
            results.append(recomputed)

        require(Counter((c["case"], c["mode"]) for c in calibrations) == Counter(expected_cells),
                "Missing or duplicate calibration cell")
        for calibration in calibrations:
            rows = [r for r in observations if r["stage"] == "calibration"
                    and (r["case"], r["mode"]) == (calibration["case"], calibration["mode"])]
            require(len(rows) == calibration["trials"] and rows, "Calibration count disagrees")
            attempts = max(r["attempt"] for r in rows) + 1
            require(Counter((r["attempt"], r["variant"]) for r in rows)
                    == Counter({(i, v): 1 for i in range(attempts) for v in VARIANTS}), "Incomplete calibration attempt")
            final = [r for r in rows if r["attempt"] == attempts - 1]
            require(all(r["iterations"] == calibration["iterations"] for r in final)
                    and all(matching(r["wall_seconds"] * 1000, calibration["last_wall_ms"][r["variant"]]) for r in final),
                    "Final calibration metadata disagrees")
            require(calibration["target_ms"] == m["protocol"]["target_ms"]
                    and calibration["max_sample_ms"] == m["protocol"]["max_sample_ms"]
                    and (min(r["wall_seconds"] for r in final) >= calibration["target_ms"] / 1000) == calibration["target_reached"],
                    "Calibration target receipt disagrees")
            timed_iterations = {r["iterations"] for r in measured
                                if (r["case"], r["mode"]) == (calibration["case"], calibration["mode"])}
            require(timed_iterations == {calibration["iterations"]}, "Measured work differs from calibrated iterations")
        commands = self.root / "commands.json"
        if commands.is_file():
            require(all(c["returncode"] == 0 for c in json.loads(commands.read_text())), "A recorded command failed")
            self.verified_files.append("command exit-code receipts")
        else:
            self.omitted.append("command exit-code receipts")
        return {"status": "pass", "baseline_revision": m["baseline_revision"],
                "candidate_revision": m["candidate_revision"], "pairs": pairs,
                "production_source_hashes_reconstructed": len(self.sources),
                "compiled_source_hashes_reconstructed": sum(len(x) for x in m["compiled_sources"].values()),
                "observations": len(observations), "measured_observations": len(measured),
                "shortest_measured_sample_ms": min(r["wall_seconds"] for r in measured) * 1000,
                "observations_below_5ms": sum(r["wall_seconds"] < .005 for r in measured),
                "calibrations_below_target": [{"case": c["case"], "mode": c["mode"]} for c in calibrations if not c["target_reached"]],
                "verified_available_files": self.verified_files,
                "omitted_content_not_independently_rehashed": self.omitted,
                "results": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(Audit(args.results, args.repo).audit(), sort_keys=True, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
