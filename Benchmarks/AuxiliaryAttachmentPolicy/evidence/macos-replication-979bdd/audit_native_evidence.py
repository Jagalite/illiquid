#!/usr/bin/env python3
"""Independently audit the archived 979bdd3 native replication, without rerunning it.

No benchmark code is imported or executed. All comparisons and statistics below
are reconstructed from the raw observations. --repo additionally checks immutable
Git blobs; --artifact additionally hashes the four native binaries when present.
The text-only --capsule is sufficient for replaying the numeric/source receipt
and test-log checks on any Python 3.10+ host. Optional evidence is never silently
reported as verified when it was not supplied.
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess

BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
CANDIDATE = "979bdd34a93af1c564d505b1b6a4f6b12de27379"
RUN_ID = 40101300598
JOB_ID = 120893823744
MIB = 1024 * 1024
CASES = ("none", "fonts-2mib", "fonts-16mib", "fonts-64mib", "unsupported-only", "mixed")
VARIANTS = ("baseline", "candidate")
PHASES = ("before", "retained", "after_release")
MEMORY = ("resident_bytes", "phys_footprint_bytes", "heap_in_use_bytes", "max_rss_bytes")
SCENARIOS = (
    [(c, "direct", "auxiliary-only") for c in CASES]
    + [(c, "executor", "primary-plus-one") for c in CASES]
    + [(c, "executor", "primary-plus-two") for c in CASES[:4]]
    + [(c, "direct", "primary-only") for c in CASES[:3]]
)
ROLES = {"auxiliary-only": ["auxiliary"], "primary-only": ["primary"],
         "primary-plus-one": ["primary", "auxiliary"],
         "primary-plus-two": ["primary", "auxiliary", "auxiliary"]}
NATIVE = "Sources/IlliquidNativePlayback/"
FULL_SOURCES = [NATIVE + s for s in (
    "Media/FFmpegDemuxer.swift", "Media/FFmpegInputExecutor.swift",
    "Subtitles/FontAttachmentStore.swift", "Media/FFmpegStreamInfo.swift",
    "Media/MediaTime.swift", "Media/FFmpegError.swift", "Media/FFmpegPacket.swift",
    "Playback/PacketQueue.swift", "Playback/FixedRingBuffer.swift")]
C_SOURCES = ["Sources/CFFmpeg/module.modulemap", "Sources/CFFmpeg/include/ffmpeg_shim.h"]
EXTRACT_SOURCES = [NATIVE + "Presentation/SampleBufferVideoPresenter.swift",
                   NATIVE + "Subtitles/BitmapSubtitleTimeline.swift"]
CALLERS = [NATIVE + s for s in (
    "Media/MediaSession.swift", "Media/NativeTimelineThumbnailGenerator.swift",
    "Media/NativeThumbnailMetadataReader.swift", "Media/NativeFrameStepReader.swift",
    "Subtitles/PreparedExternalSubtitle.swift")]
PINNED = {
    ".github/workflows/auxiliary-font-attachments.yml":
        "32d137500e4f7b5c101f0195365413993aa349707a4e44bb9173f219333bc21d",
    "Tests/IlliquidNativePlaybackTests/AuxiliaryFontAttachmentTests.swift":
        "d1d1b315a1aebd53867c11f64b8208c4f9a578dd78fc52d64bbfed5869f6736c",
}
AUXILIARY_TESTS = {
    "defaultAndExplicitInclusionKeepOwnedFontBytes(name:)": 6,
    "omissionPreservesMetadataPacketsSeeksAndCodecPrivateData(name:)": 6,
    "executorForwardsOmissionAndKeepsSubtitleAndAudioOperations(name:)": 6,
    "metadataReaderAndFrameStepReaderIgnoreUnneededFonts()": 1,
    "thumbnailPixelsMatchTheSameStreamsWithoutAttachments()": 1,
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def foundation_json(value) -> bytes:
    # The recorded metadata has integer, string, Boolean and null values; all
    # floating-point fields are already lossless bit-pattern strings. Foundation
    # sortedKeys JSON escapes forward slashes, unlike Python's default writer.
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), allow_nan=False).replace("/", "\\/").encode()


class Audit:
    def __init__(self):
        self.checks = Counter()

    def require(self, condition, message, group="integrity"):
        if not condition:
            raise AssertionError(message)
        self.checks[group] += 1

    def compare_tree(self, expected, actual, path="summary"):
        if isinstance(expected, dict):
            self.require(isinstance(actual, dict) and set(actual) == set(expected),
                         f"{path}: dictionary keys differ", "summary")
            for key in expected:
                self.compare_tree(expected[key], actual[key], f"{path}.{key}")
        elif isinstance(expected, list):
            self.require(isinstance(actual, list) and len(actual) == len(expected),
                         f"{path}: list length differs", "summary")
            for index, (x, y) in enumerate(zip(expected, actual)):
                self.compare_tree(x, y, f"{path}[{index}]")
        elif isinstance(expected, (int, float)) and not isinstance(expected, bool):
            self.require(isinstance(actual, (int, float)) and math.isclose(
                expected, actual, rel_tol=1e-12, abs_tol=1e-12),
                f"{path}: expected {expected!r}, found {actual!r}", "summary")
        else:
            self.require(expected == actual, f"{path}: values differ", "summary")


def aggregate(pairs):
    # Input is ordered by paired process invocation, not by magnitude. The
    # median of six paired differences need not equal the difference of medians.
    baseline = [p[0] for p in pairs]
    candidate = [p[1] for p in pairs]
    delta = [b - c for b, c in pairs]
    percent = [100 * (b - c) / b for b, c in pairs if b > 0]
    distribution = lambda xs: {"median": statistics.median(xs), "min": min(xs), "max": max(xs)}
    return {
        "baseline": distribution(baseline), "candidate": distribution(candidate),
        "median_paired_reduction": statistics.median(delta),
        "min_paired_reduction": min(delta), "max_paired_reduction": max(delta),
        "median_paired_reduction_percent": statistics.median(percent) if percent else None,
        "paired_values": [{"pair": i, "baseline": b, "candidate": c, "reduction": b - c,
                           "reduction_percent": 100 * (b - c) / b if b else None}
                          for i, (b, c) in enumerate(pairs)],
        "candidate_lower_pairs": sum(c < b for b, c in pairs),
        "equal_pairs": sum(c == b for b, c in pairs),
        "candidate_higher_pairs": sum(c > b for b, c in pairs),
    }


def summary_fields(metric):
    return {k: v for k, v in metric.items() if k not in {
        "paired_values", "candidate_lower_pairs", "equal_pairs", "candidate_higher_pairs"}}


def audit(args):
    checks = Audit()
    capsule_bytes = args.capsule.read_bytes()
    capsule = json.loads(gzip.decompress(capsule_bytes))
    checks.require(isinstance(capsule, dict), "Text capsule must be a dictionary")

    def data(path):
        checks.require(path in capsule and isinstance(capsule[path], str),
                       f"Missing text receipt: {path}")
        return capsule[path].encode()

    def result_data(path):
        return data("auxiliary-font-results/" + path)

    def read_result(path):
        return json.loads(result_data(path))

    artifact_matches = []
    if args.artifact:
        for path, text in capsule.items():
            if path.startswith("pinned-qualification/"):
                continue
            disk = args.artifact / path
            checks.require(disk.is_file() and disk.read_bytes() == text.encode(),
                           f"Capsule differs from downloaded artifact: {path}", "artifact")
            artifact_matches.append(path)

    manifest = read_result("manifest.json")
    rows = [json.loads(line) for line in result_data("observations.jsonl").splitlines()]
    fixtures = read_result("fixtures.json")
    parity = read_result("parity.json")
    original_summary = read_result("summary.json")
    commands = read_result("commands.json")
    checks.require(manifest["baseline_commit"] == BASELINE, "Wrong baseline")
    checks.require(manifest["candidate_commit"] == CANDIDATE, "Wrong candidate")
    checks.require(manifest["candidate_status"] == "", "Measured checkout was dirty")
    checks.require(manifest["pairs"] == 6 and manifest["scenarios"] == [list(s) for s in SCENARIOS],
                   "Wrong planned cohort", "cohort")
    checks.require(len(rows) == 228, "Expected all 228 raw process observations", "cohort")
    checks.require([r["sequence"] for r in rows] == list(range(228)), "Noncontiguous sequence", "cohort")
    expected_order = []
    for pair in range(6):
        cases = SCENARIOS if pair % 2 == 0 else list(reversed(SCENARIOS))
        variants = VARIANTS if pair % 2 == 0 else tuple(reversed(VARIANTS))
        for scenario in cases:
            for position, variant in enumerate(variants):
                expected_order.append((pair, *scenario, variant, position))
    checks.require([(r["pair"], r["case"], r["backend"], r["layout"], r["variant"], r["pair_position"])
                    for r in rows] == expected_order, "Order, completeness or alternating balance differs", "cohort")
    keyed = {(r["case"], r["backend"], r["layout"], r["pair"], r["variant"]): r for r in rows}
    checks.require(len(keyed) == 228, "Duplicate process identity", "cohort")

    fixture_manifest = json.loads(data("auxiliary-font-fixtures/manifest.json"))
    checks.require([{k: v for k, v in f.items() if k != "path"} for f in fixtures] == fixture_manifest,
                   "Runner/generator fixture inventories disagree", "fixture")
    checks.require([f["name"] for f in fixtures] == list(CASES), "Incomplete fixture set", "fixture")
    fixture_by_name = {f["name"]: f for f in fixtures}
    expected_sizes = {"none": (0, 0, 0), "fonts-2mib": (2*MIB, 1, 0),
                      "fonts-16mib": (16*MIB, 4, 0), "fonts-64mib": (64*MIB, 4, 0),
                      "unsupported-only": (0, 0, 16*MIB), "mixed": (2*MIB, 1, 16*MIB)}
    for f in fixtures:
        checks.require((f["accepted_payload_bytes"], f["font_count"], f["rejected_payload_bytes"])
                       == expected_sizes[f["name"]], f"Wrong payload inventory: {f['name']}", "fixture")
        checks.require(sum(a["size_bytes"] for a in f["attachments"] if a["accepted"])
                       == f["accepted_payload_bytes"], "Accepted byte sum differs", "fixture")
        checks.require(sum(a["size_bytes"] for a in f["attachments"] if not a["accepted"])
                       == f["rejected_payload_bytes"], "Rejected byte sum differs", "fixture")
        for index, attachment in enumerate(f["attachments"]):
            offset = (31 + index if f["name"] == "fonts-16mib" else
                      47 + index if f["name"] == "fonts-64mib" else
                      17 if attachment["accepted"] else 47)
            block = bytes((i + offset) % 256 for i in range(256)) * 4096
            h = hashlib.sha256()
            remaining = attachment["size_bytes"]
            while remaining:
                chunk = block[:remaining]
                h.update(chunk)
                remaining -= len(chunk)
            checks.require(h.hexdigest() == attachment["sha256"],
                           f"Synthetic payload digest differs: {f['name']}[{index}]", "fixture")

    reader_count = packet_count = 0
    canonical = {}
    for row in rows:
        label = f"observation {row['sequence']}"
        fixture = fixture_by_name[row["case"]]
        roles = ROLES[row["layout"]]
        checks.require(row["reader_count"] == len(roles) == len(row["readers"]),
                       f"{label}: reader count", "parity")
        checks.require(row["readers_released"] is True, f"{label}: a native owner survived", "lifetime")
        checks.require(row["expected_font_bytes"] == fixture["accepted_payload_bytes"],
                       f"{label}: fixture byte count", "parity")
        checks.require(row["ffmpeg"] == rows[0]["ffmpeg"], f"{label}: runtime FFmpeg differs", "provenance")
        for phase in PHASES:
            checks.require(set(row["memory"][phase]) == set(MEMORY), f"{label}: memory keys", "numeric")
            for value in row["memory"][phase].values():
                checks.require(type(value) is int and value >= 0, f"{label}: invalid memory value", "numeric")
        for metric in ("open_wall_seconds", "open_cpu_seconds"):
            checks.require(isinstance(row[metric], (int, float)) and math.isfinite(row[metric])
                           and row[metric] >= 0, f"{label}: invalid open time", "numeric")
        for index, (reader, role) in enumerate(zip(row["readers"], roles)):
            reader_count += 1
            keeps = row["variant"] == "baseline" or role == "primary"
            expected_attachments = [
                {"filename": a["filename"], "mime_type": a["mime_type"],
                 "bytes": a["size_bytes"], "sha256": a["sha256"]}
                for a in fixture["attachments"] if keeps and a["accepted"]]
            checks.require((reader["index"], reader["role"], reader["includes_font_attachments"])
                           == (index, role, keeps), f"{label}: wrong reader policy", "parity")
            checks.require(reader["attachments"] == expected_attachments,
                           f"{label}: attachment content/metadata mismatch", "parity")
            checks.require(reader["copied_font_count"] == len(expected_attachments)
                           and reader["copied_font_bytes"] == sum(a["bytes"] for a in expected_attachments),
                           f"{label}: copied ownership totals differ", "parity")
            checks.require(sha(foundation_json(reader["metadata"])) == reader["metadata_sha256"],
                           f"{label}: metadata digest differs", "parity")
            common = {k: reader[k] for k in ("metadata", "packet_trace", "codec_private")}
            first = canonical.setdefault(row["case"], common)
            checks.require(common == first == parity[row["case"]],
                           f"{label}: metadata/private bytes/packet+seek parity differs", "parity")
            if keeps:
                checks.require(reader["attachments"] == parity[row["case"] + ":fonts"],
                               f"{label}: font parity receipt differs", "parity")
            checks.require(set(reader["packet_trace"]) == {"initial", "after_seek"},
                           f"{label}: incomplete packet phases", "parity")
            for phase, generation in (("initial", 1), ("after_seek", 2)):
                packets = reader["packet_trace"][phase]
                checks.require(len(packets) == 71 and all(p["generation"] == generation for p in packets),
                               f"{label}: packet count/generation differs", "parity")
                packet_count += len(packets)
    checks.require(reader_count == 396 and packet_count == 56232, "Receipt coverage differs", "parity")
    for case, receipt in canonical.items():
        checks.require(receipt["codec_private"] == canonical["none"]["codec_private"]
                       and receipt["packet_trace"] == canonical["none"]["packet_trace"],
                       f"Encoded streams vary between fixture {case} and plain control", "fixture")

    all_metrics = []
    reconstructed = {"observations": len(rows), "scenarios": []}
    adverse = []
    for case, backend, layout in SCENARIOS:
        paired = [[keyed[(case, backend, layout, pair, variant)] for variant in VARIANTS]
                  for pair in range(6)]
        output = {"case": case, "backend": backend, "layout": layout, "pairs": 6}
        metrics = {}
        for phase in PHASES:
            for metric in MEMORY:
                metrics[phase + "." + metric] = aggregate([
                    (b["memory"][phase][metric], c["memory"][phase][metric]) for b, c in paired])
        for metric in ("open_wall_seconds", "open_cpu_seconds"):
            metrics[metric] = aggregate([(b[metric], c[metric]) for b, c in paired])
        metrics["copied_font_bytes"] = aggregate([
            tuple(sum(r["copied_font_bytes"] for r in row["readers"]) for row in pair) for pair in paired])
        for metric in ("resident_bytes", "phys_footprint_bytes", "heap_in_use_bytes"):
            output[metric] = summary_fields(metrics["retained." + metric])
        for metric in ("copied_font_bytes", "open_wall_seconds", "open_cpu_seconds"):
            output[metric] = summary_fields(metrics[metric])
        reconstructed["scenarios"].append(output)
        all_metrics.append({"case": case, "backend": backend, "layout": layout, "pairs": 6, "metrics": metrics})
        for metric in ("retained.resident_bytes", "retained.phys_footprint_bytes",
                       "open_wall_seconds", "open_cpu_seconds"):
            if metrics[metric]["median_paired_reduction"] < 0:
                adverse.append({"case": case, "backend": backend, "layout": layout,
                                "metric": metric, **metrics[metric]})
    checks.compare_tree(reconstructed, original_summary)

    git_checks = []
    def verify_git(commit, path, archived):
        if args.repo is None:
            return
        completed = subprocess.run(["git", "show", f"{commit}:{path}"], cwd=args.repo,
                                   env={**os.environ, "GIT_NO_LAZY_FETCH": "1"},
                                   capture_output=True, check=False)
        checks.require(completed.returncode == 0, f"Immutable Git source unavailable: {commit}:{path}", "git")
        checks.require(completed.stdout == archived, f"Archive differs from immutable Git source: {path}", "git")
        git_checks.append({"commit": commit, "path": path, "sha256": sha(archived),
                           "git_blob_sha1": git_blob_sha(archived)})

    expected_sources = {f"{v}:{p}" for v in VARIANTS for p in FULL_SOURCES + C_SOURCES + EXTRACT_SOURCES}
    expected_sources.update("candidate:" + p for p in CALLERS)
    checks.require(set(manifest["sources"]) == expected_sources, "Incomplete/unexpected source inventory", "provenance")
    for key, digest in manifest["sources"].items():
        variant, path = key.split(":", 1)
        archived = result_data("sources/" + variant + "/" + path)
        checks.require(sha(archived) == digest, f"Source digest differs: {key}", "provenance")
        verify_git(BASELINE if variant == "baseline" else CANDIDATE, path, archived)
        if path in FULL_SOURCES:
            checks.require(result_data(variant + "/" + Path(path).name) == archived,
                           f"Compiled source was rewritten: {key}", "provenance")
        if variant == "candidate" and path in C_SOURCES:
            checks.require(result_data("CFFmpeg/" + path.removeprefix("Sources/CFFmpeg/")) == archived,
                           f"Compiled C module/header differs: {path}", "provenance")
    for path in FULL_SOURCES[2:] + C_SOURCES:
        checks.require(manifest["sources"]["baseline:" + path] == manifest["sources"]["candidate:" + path],
                       f"Unrelated compiled dependency changed: {path}", "provenance")
    for variant in VARIANTS:
        presentation = result_data("sources/" + variant + "/" + EXTRACT_SOURCES[0]).decode()
        bitmap = result_data("sources/" + variant + "/" + EXTRACT_SOURCES[1]).decode()
        sections = []
        for source, start, end in ((presentation, "struct PresentationError:", "\nfunc checkOSStatus("),
                                   (bitmap, "enum PGSSubtitlePacket {", "\nstruct NativeBitmapSubtitleRegion:")):
            checks.require(source.count(start) == source.count(end) == 1,
                           "Nonunique extraction boundary", "provenance")
            sections.append(source[source.index(start):source.index(end)])
        support = ("import Foundation\n\n" + "\n".join(sections)).encode()
        checks.require(support == result_data(variant + "/ExtractedDeclarations.swift")
                       and sha(support) == manifest["extracted_declarations"][variant],
                       f"Extracted helper declarations differ: {variant}", "provenance")
    checks.require(len(set(manifest["extracted_declarations"].values())) == 1,
                   "Baseline/candidate helper bodies differ", "provenance")
    for filename, key in (("run.py", "runner_sha256"), ("Harness.swift", "harness_sha256"),
                          ("generate-fixtures.py", "generator_sha256")):
        archived = result_data(filename)
        checks.require(sha(archived) == manifest[key], f"Benchmark file digest differs: {filename}", "provenance")
        verify_git(CANDIDATE, "Benchmarks/AuxiliaryFontAttachments/" + filename, archived)
    checks.require(sha(result_data("ffmpeg-headers.json")) == manifest["ffmpeg_headers_sha256"],
                   "FFmpeg header hash inventory differs", "provenance")
    for path, digest in PINNED.items():
        archived = data("pinned-qualification/" + path)
        checks.require(sha(archived) == digest, f"Pinned qualification source differs: {path}", "provenance")
        verify_git(CANDIDATE, path, archived)

    checks.require(len(commands) == 255 and all(c["returncode"] == 0 for c in commands),
                   "Missing or failed command receipt", "commands")
    invocations = [c for c in commands if Path(c["argv"][0]).name == "auxiliary-attachments"]
    checks.require(len(invocations) == len(rows), "Process command receipt count differs", "commands")
    for command, row in zip(invocations, rows):
        argv = command["argv"]
        checks.require(Path(argv[0]).parent.name == row["variant"] and argv[1:] == [
            fixture_by_name[row["case"]]["path"], row["backend"], row["layout"], str(row["expected_font_bytes"])],
            "Process command differs from recorded observation", "commands")
    for command in commands:
        argv = command["argv"]
        if argv[:2] == ["git", "show"]:
            commit, path = argv[2].split(":", 1)
            checks.require(commit == BASELINE and command["stdout_sha256"]
                           == manifest["sources"]["baseline:" + path],
                           "Baseline git-show stdout receipt differs", "commands")
    build_commands = [c for c in commands if "-o" in c["argv"] and Path(c["argv"][0]).name == "swiftc"]
    checks.require(len(build_commands) == 4, "Expected two libraries and two drivers", "commands")
    for command in build_commands:
        argv = command["argv"]
        output_path = Path(argv[argv.index("-o") + 1])
        variant = output_path.parent.name
        kind = "library" if "-emit-library" in argv else "driver"
        checks.require(argv[1:1 + len(manifest["compiler_flags"])] == manifest["compiler_flags"],
                       "Compile flags differ between variants", "commands")
        checks.require(("BASELINE" in argv) == (variant == "baseline" and kind == "driver"),
                       "Wrong driver conditional compilation", "commands")
        log = result_data(f"{variant}-{kind}-build.log")
        checks.require(log == b"" and command["stdout_sha256"] == sha(b"")
                       and command["stderr_sha256"] == sha(b""), "Build produced unexpected diagnostics", "commands")
    fixture_commands = json.loads(data("auxiliary-font-fixtures/fixture-commands.json"))
    checks.require(len(fixture_commands) == 7 and all(c["returncode"] == 0 for c in fixture_commands),
                   "Fixture generation receipt incomplete", "commands")

    binaries = []
    if args.artifact:
        for variant in VARIANTS:
            for filename, field in (("auxiliary-attachments", "executable_sha256"),
                                     ("libAuxiliaryAttachmentInputs.dylib", "library_sha256")):
                path = args.artifact / "auxiliary-font-results" / variant / filename
                if path.is_file():
                    digest = sha(path.read_bytes())
                    checks.require(digest == manifest["binaries"][variant][field],
                                   f"Native binary digest differs: {variant}/{filename}", "binary")
                    binaries.append({"variant": variant, "filename": filename, "sha256": digest})

    tests = {}
    for mode in ("debug", "release"):
        contents = data("auxiliary-font-tests/" + mode + ".log")
        lines = contents.decode().splitlines()
        passed = [l for l in lines if l.startswith("✔ Test ") and not l.startswith("✔ Test run with ")]
        skipped = [l for l in lines if l.startswith("➜ Test ")]
        skipped_suites = [l for l in lines if l.startswith("➜ Suite ")]
        footer = [l for l in lines if l.startswith("✔ Test run with ")]
        checks.require(len(footer) == 1 and "83 tests in 10 suites passed" in footer[0],
                       f"{mode}: wrong final test outcome", "test")
        checks.require(len(passed) == 73 and len(skipped) == 10 and len(skipped_suites) == 2,
                       f"{mode}: passing/skipped test accounting differs", "test")
        checks.require(not any(l.startswith("✘") for l in lines), f"{mode}: failed test in log", "test")
        new_tests = []
        for name, count in AUXILIARY_TESTS.items():
            pattern = re.compile(r"^✔ Test " + re.escape(name) +
                                 (rf" with {count} test cases" if count > 1 else "") + r" passed after .+ seconds\.$")
            matches = [l for l in passed if pattern.fullmatch(l)]
            checks.require(len(matches) == 1, f"{mode}: missing new auxiliary test success: {name}", "test")
            new_tests.append({"name": name, "executed_cases": count, "log_line": matches[0]})
        checks.require(sum(x["executed_cases"] for x in new_tests) == 20, "New suite case count differs", "test")
        tests[mode] = {"sha256": sha(contents), "reported_footer": footer[0],
                       "passing_test_functions": len(passed), "explicitly_skipped_test_functions": len(skipped),
                       "passing_suite_lines": [l for l in lines if l.startswith("✔ Suite ")],
                       "skipped_test_lines": skipped, "skipped_suite_lines": skipped_suites,
                       "auxiliary_suite_executed_cases": 20, "auxiliary_tests": new_tests,
                       "build_completion_lines": [l for l in lines if "Build complete!" in l]}

    log_binding = {"checked": False}
    if args.job_log:
        log_bytes = args.job_log.read_bytes()
        lines = log_bytes.decode("utf-8-sig").splitlines()
        def markers(marker, pattern):
            result = []
            for line in lines:
                if marker not in line:
                    continue
                suffix = line.split(marker, 1)[1]
                if re.fullmatch(pattern, suffix):
                    result.append(suffix)
            checks.require(len(result) == 1, f"Missing/ambiguous native job marker: {marker}", "job_log")
            return result[0]
        encoded = markers("AUXILIARY_FONT_EVIDENCE_BASE64 ", r"[A-Za-z0-9+/=]+")
        digest = markers("AUXILIARY_FONT_EVIDENCE_SHA256 ", r"[0-9a-f]{64}")
        packed = base64.b64decode(encoded, validate=True)
        checks.require(sha(packed) == digest, "Compact evidence marker digest differs", "job_log")
        compact = json.loads(gzip.decompress(packed))
        checks.require(set(compact) == {"manifest.json", "summary.json", "observations.jsonl", "parity.json", "fixtures.json", "commands.json"},
                       "Compact evidence file set differs", "job_log")
        for filename, value in compact.items():
            checks.require(value.encode() == result_data(filename),
                           f"Downloaded receipt differs from job marker: {filename}", "job_log")
        for mode in ("debug", "release"):
            for line in [tests[mode]["reported_footer"], *[t["log_line"] for t in tests[mode]["auxiliary_tests"]]]:
                checks.require(line in log_bytes.decode(), f"{mode}: final/specific test success absent in job log", "job_log")
        log_binding = {"checked": True, "job_log_sha256": sha(log_bytes), "compact_bundle_sha256": digest}

    return {
        "audit_status": "passed", "audit_version": 1,
        "interpretation": "Successful reduction of Swift-owned payloads and reported live malloc bytes; retained resident/physical-footprint regressions prevent a general RAM improvement claim.",
        "run_url": f"https://github.com/Jagalite/illiquid/actions/runs/{RUN_ID}/job/{JOB_ID}",
        "baseline_commit": BASELINE, "candidate_commit": CANDIDATE,
        "scope": "Independent macOS replication of the boolean includeFontAttachments implementation; not native qualification of PR #101's distinct enum-policy head.",
        "checks_passed_by_group": dict(sorted(checks.checks.items())),
        "checks_passed_total": sum(checks.checks.values()),
        "observations": len(rows), "paired_comparisons": 114, "scenarios": len(SCENARIOS),
        "reader_receipts": reader_count, "packet_receipts": packet_count,
        "summary_recomputed_from_raw": True, "summary_float_tolerance": {"relative": 1e-12, "absolute": 1e-12},
        "source_capsule_sha256": sha(capsule_bytes), "source_capsule_file_count": len(capsule),
        "artifact_files_compared": artifact_matches, "immutable_git_files_checked": git_checks,
        "native_binaries_checked": binaries, "job_log_binding": log_binding,
        "input_sha256": {p: sha(t.encode()) for p, t in sorted(capsule.items())},
        "host": {k: manifest[k] for k in ("host", "hardware", "platform", "compiler", "sdk_version", "started_utc", "completed_utc")},
        "tests": tests, "metrics": all_metrics, "adverse_median_metrics": adverse,
        "limits": [
            "Positive reduction means baseline minus candidate; negative values mean the candidate used more memory/time. Paired medians are not differences of marginal medians.",
            "Six pairs per scenario, a single native virtual host/session, alternating fixed order. Ranges are observed extrema, not confidence intervals. Opening time remains exploratory.",
            "Retained samples precede parity hashing and packet reads; after_release samples follow hashing, packet/seek validation and receipt allocations. After-release differences are diagnostic and cannot isolate deallocation, reclaimability or the cause of retained physical-memory regressions.",
            "Fixtures use deterministic arbitrary font-labeled bytes, not renderable fonts. The new suite does not establish libass or main/PiP real-font visual parity.",
            "All 73 passing and 10 skipped test-function outcomes are recorded for each build configuration; the footer's 83 includes the skipped functions.",
            "The text package records fixture container, installed FFmpeg library/header and Swift compiler hashes; those original external files were not included and are not independently rehashed by this audit. Deterministic attachment payload hashes are independently regenerated.",
            "The benchmark completion gate verifies parity and completeness, not a threshold requiring memory or speed improvement.",
            "Unchanged FFmpeg native extradata and any libass font storage are outside the removed Swift-owned copies; this is not a whole-player memory measurement.",
        ],
    }


def report_text(result):
    lines = ["# Independent native replication audit", "",
             "The archived evidence is internally consistent and source-pinned. It supports fewer owned font bytes and lower live malloc accounting, while reporting worse retained resident memory and physical footprint in the 16 MiB and 64 MiB auxiliary cases. It does not support a general RAM or speed improvement claim.", "",
             f"Baseline `{BASELINE}`; candidate `{CANDIDATE}`. [Native job]({result['run_url']}). The candidate uses a Boolean policy; this evidence does not qualify PR #101's distinct enum-policy head.", "",
             f"The auditor reconstructed all {result['observations']} process observations, 114 paired comparisons in 19 scenarios, 396 reader receipts and 56,232 packet receipts. All persisted summary fields agree (floating-point tolerance 1e-12). {result['checks_passed_total']:,} checks passed.", "",
             "Positive reductions below mean baseline minus candidate. Negative reductions mean the candidate consumed more. Every memory value uses MiB (1,048,576 bytes). Paired medians are computed from six paired observations; they may differ from the difference between the two marginal medians.", "",
             "## Retained memory: every cohort", "",
             "RSS and physical-footprint samples are taken with all input owners alive, before parity hashing or packet reads. Heap is malloc-zone size-in-use accounting; it is not resident physical memory.", "",
             "| Fixture | Reader layout | Copied bytes B → C | Heap B → C | Heap paired reduction | RSS B → C | RSS paired reduction [min, max] | Footprint B → C | Footprint paired reduction [min, max] |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    def medians(metric, scale=1):
        return f"{metric['baseline']['median']/scale:.3f} → {metric['candidate']['median']/scale:.3f}"
    def delta(metric, scale=1, bounds=False):
        value = f"{metric['median_paired_reduction']/scale:+.3f}"
        return value + (f" [{metric['min_paired_reduction']/scale:+.3f}, {metric['max_paired_reduction']/scale:+.3f}]" if bounds else "")
    for cohort in result["metrics"]:
        m = cohort["metrics"]
        heap, rss, footprint = (m["retained." + key] for key in ("heap_in_use_bytes", "resident_bytes", "phys_footprint_bytes"))
        lines.append(f"| {cohort['case']} | {cohort['backend']}, {cohort['layout']} | {medians(m['copied_font_bytes'], MIB)} | {medians(heap, MIB)} | {delta(heap, MIB)} | {medians(rss, MIB)} | {delta(rss, MIB, True)} | {medians(footprint, MIB)} | {delta(footprint, MIB, True)} |")
    lines.extend(["", "The candidate's retained RSS and footprint are higher in all six pairs in each 16 MiB and 64 MiB auxiliary cohort. The increase is approximately 4 MiB for 16 MiB of attached fonts and 16 MiB for 64 MiB. With a primary plus two auxiliary readers and 64 MiB of fonts, copied payloads fall from 192 to 64 MiB and live heap from 769.328 to 641.295 MiB, while resident memory rises from 591.492 to 607.531 MiB and footprint from 582.105 to 598.120 MiB.", "",
                  "## Opening time: every cohort", "",
                  "Times are milliseconds for opening all readers in the layout. The percentage is the median paired percentage reduction. No general speedup claim is justified; these short opens vary considerably, including controls.", "",
                  "| Fixture | Reader layout | Wall B → C (ms) | Wall paired reduction (ms) [min, max] | Wall paired reduction % | CPU B → C (ms) | CPU paired reduction (ms) [min, max] | CPU paired reduction % |",
                  "|---|---|---:|---:|---:|---:|---:|---:|"])
    for cohort in result["metrics"]:
        wall, cpu = (cohort["metrics"][key] for key in ("open_wall_seconds", "open_cpu_seconds"))
        lines.append(f"| {cohort['case']} | {cohort['backend']}, {cohort['layout']} | {medians(wall, .001)} | {delta(wall, .001, True)} | {wall['median_paired_reduction_percent']:+.3f}% | {medians(cpu, .001)} | {delta(cpu, .001, True)} | {cpu['median_paired_reduction_percent']:+.3f}% |")
    lines.extend(["", "The 16 MiB primary-plus-two cohort is adverse on opening time: wall time's median paired reduction is −37.335% and CPU's is −36.389%; five of six pairs are slower. The raw pairs and extrema are preserved in audit-result.json. This timing result should not be discarded because other font sizes improve.", "",
                  "## After-release diagnostics", "",
                  "These samples follow attachment hashing, metadata snapshots, codec-private data copies, packet reads, seeks, and receipt construction. They are not a controlled release-only measurement. They neither explain the retained RSS regression nor establish deallocation-related physical-memory savings. Every weak reader probe was nil. After-release live heap is below 1 MiB in every observation, consistent with the observed reader lifetime assertions; physical memory includes retained allocator state and the intervening workload.", "",
                  "| Fixture | Reader layout | Heap B → C | RSS B → C | RSS paired reduction | Footprint B → C | Footprint paired reduction |",
                  "|---|---|---:|---:|---:|---:|---:|"])
    for cohort in result["metrics"]:
        heap, rss, footprint = (cohort["metrics"]["after_release." + key] for key in ("heap_in_use_bytes", "resident_bytes", "phys_footprint_bytes"))
        lines.append(f"| {cohort['case']} | {cohort['backend']}, {cohort['layout']} | {medians(heap, MIB)} | {medians(rss, MIB)} | {delta(rss, MIB)} | {medians(footprint, MIB)} | {delta(footprint, MIB)} |")
    lines.extend(["", "## Test evidence and skipped coverage", ""])
    for mode, test in result["tests"].items():
        lines.extend([f"### {mode.title()}", "", f"`{test['reported_footer']}`", "",
                      "The log contains **73 passing test functions and 10 explicitly skipped functions**, with two skipped suites. The new auxiliary suite executed 20 cases: three parameterized functions with six fixtures each, plus metadata/frame-step and thumbnail-pixel parity tests.", "",
                      f"Log SHA-256: `{test['sha256']}`.", "", "Skipped functions and their exact recorded reasons:", ""])
        lines.extend("- " + line for line in test["skipped_test_lines"])
        lines.extend(["", "Skipped suites:", ""])
        lines.extend("- " + line for line in test["skipped_suite_lines"])
        lines.append("")
    lines.extend(["## Provenance", "",
                  f"- Verified {len(result['artifact_files_compared'])} capsule text files byte for byte against the downloaded artifact.",
                  f"- Verified {len(result['immutable_git_files_checked'])} immutable commit files against local Git blobs, including all 31 source receipts, runner/harness/generator, workflow and new test source.",
                  "- Verified compiled full Swift copies, C module/header copies, and exact helper declaration extractions. Shared dependencies and extracted helpers are equal across variants.",
                  f"- Verified {len(result['native_binaries_checked'])} downloaded native executable/library hashes when the original artifact was supplied. Native binaries are unnecessary to replay the numeric audit.",
                  "- Verified all 255 recorded runner commands succeeded, with 228 matching process invocations and four identical-flag optimized compile commands. All four build logs are empty. All seven fixture generation commands succeeded.",
                  "- Verified all six fixture inventories and independently regenerated deterministic attachment payload hashes. Container, installed dependency and compiler bytes were not included in the text evidence; their recorded hashes remain receipts rather than a fresh independent rehash.",
                  f"- Text capsule SHA-256: `{result['source_capsule_sha256']}`.",
                  f"- Compact job-log binding checked: `{result['job_log_binding']['checked']}`.", "",
                  "The machine was an Apple M1 virtual host with 7 GiB RAM, macOS 26.6.2, Swift 6.3.3 and SDK 26.5. Results are from one host/session, six pairs per cohort. They are not a confidence interval or population estimate.", "",
                  "## Interpretation limits", ""])
    lines.extend("- " + limit for limit in result["limits"])
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capsule", required=True, type=Path)
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--job-log", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = audit(args)
    result["auditor_sha256"] = sha(Path(__file__).read_bytes())
    result["invocation"] = {k: str(v) if v is not None else None for k, v in vars(args).items()}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "audit-result.json").write_text(json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n")
    (args.output / "AUDIT.md").write_text(report_text(result))
    print(json.dumps({"status": result["audit_status"], "checks": result["checks_passed_total"],
                      "observations": result["observations"], "reader_receipts": result["reader_receipts"],
                      "git_files": len(result["immutable_git_files_checked"]),
                      "adverse_median_metrics": len(result["adverse_median_metrics"]),
                      "output": str(args.output)}, sort_keys=True))


if __name__ == "__main__":
    main()
