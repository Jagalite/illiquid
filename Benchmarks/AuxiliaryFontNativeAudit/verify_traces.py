#!/usr/bin/env python3
"""Independently audit the retained traces from native run 40101084730.

Uses only Python's standard library. --repository additionally invokes Git to
compare saved source bytes with the two recorded revisions. This audits saved
evidence; it does not run the macOS binaries, decode media, or qualify playback.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import zipfile


BASELINE = "6f70cd2446fc6ef38d4e5a0fbf96f91b2234e635"
PROTOTYPE = "4e64b3d2b6098536c61710dca2354442c718961c"
ARCHIVE_SHA256 = "1b1ebc11ec33c6f9b57d28d86d811c0e0d4c5e6b7a952364ababfec0ff070583"
VARIANTS = ("baseline", "candidate")
APIS = ("direct", "executor")
POLICIES = ("default", "explicit", "auxiliary")
MIB = 1_048_576
CASES = {
    "none": [],
    "fonts-2mib": [("font-small.TTF", 2 * MIB, 0)],
    "fonts-16mib": [("font-0.TTF", 16 * MIB, 1)],
    "fonts-64mib": [(f"font-{i}.TTF", 16 * MIB, i + 1) for i in range(4)],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON object key: {key}")
        result[key] = value
    return result


def parse_json(data):
    def invalid_constant(value):
        raise ValueError(f"Non-finite JSON value: {value}")
    return json.loads(data, object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def canonical(data):
    return json.dumps(data, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True, allow_nan=False).encode("utf-8")


def differing_path(expected, actual, path="$"):
    if type(expected) is not type(actual):
        return path + " (type)"
    if isinstance(expected, dict):
        if set(expected) != set(actual):
            return path + " (keys)"
        for key in sorted(expected):
            result = differing_path(expected[key], actual[key], f"{path}.{key}")
            if result:
                return result
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            return path + " (length)"
        for index, (left, right) in enumerate(zip(expected, actual)):
            result = differing_path(left, right, f"{path}[{index}]")
            if result:
                return result
    elif expected != actual:
        return path
    return None


def same(expected, actual, message):
    difference = differing_path(expected, actual)
    require(difference is None, f"{message}: {difference}")


def synthetic_font_hash(size, seed):
    # The independent fixture specification is a repeating 256-byte sequence
    # beginning at seed, wrapping at 256. No generator module is imported/run.
    pattern = bytes((seed + offset) & 255 for offset in range(256))
    digest = hashlib.sha256()
    for _ in range(size // len(pattern)):
        digest.update(pattern)
    digest.update(pattern[:size % len(pattern)])
    return digest.hexdigest()


def declaration(source, marker):
    """Recover one of the three simple saved Swift declarations verbatim."""
    require(source.count(marker) == 1, f"Expected exactly one declaration {marker}")
    start = source.index(marker)
    index = source.index("{", start)
    depth = 0
    quote = False
    line_comment = False
    block_comments = 0
    while index < len(source):
        pair = source[index:index + 2]
        char = source[index]
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comments:
            if pair == "/*":
                block_comments += 1
                index += 1
            elif pair == "*/":
                block_comments -= 1
                index += 1
        elif quote:
            if char == "\\":
                index += 1
            elif char == '"':
                quote = False
        elif pair == "//":
            line_comment = True
            index += 1
        elif pair == "/*":
            block_comments = 1
            index += 1
        elif char == '"':
            quote = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
        index += 1
    raise ValueError(f"Unterminated declaration {marker}")


def audit(args):
    root = args.artifact_root.resolve()
    files_used = set()

    def read(relative):
        relative = PurePosixPath(relative)
        require(not relative.is_absolute() and ".." not in relative.parts,
                f"Unsafe artifact path: {relative}")
        path = root.joinpath(*relative.parts)
        require(path.is_file() and path.resolve().is_relative_to(root),
                f"Missing artifact file: {relative}")
        files_used.add(str(relative))
        return path.read_bytes()

    def obj(relative):
        return parse_json(read(relative))

    def result_read(relative):
        return read("auxiliary-font-results/" + relative)

    def result_obj(relative):
        return parse_json(result_read(relative))

    manifest = result_obj("manifest.json")
    require(manifest["baseline_revision"] == BASELINE, "Unexpected baseline revision")
    require(manifest["candidate_worktree_head"] == PROTOTYPE, "Unexpected prototype revision")
    require(manifest["candidate_worktree_status"] == "", "Measured prototype checkout was dirty")
    fixture_manifest = obj("auxiliary-font-fixtures/manifest.json")
    same(fixture_manifest, result_obj("fixture-manifest.snapshot.json"), "Fixture snapshot")
    fixtures = {row["name"]: row for row in fixture_manifest}
    require(len(fixtures) == len(fixture_manifest) and set(fixtures) == set(CASES),
            "Unexpected or duplicate measured fixtures")
    expanded_fixtures = result_obj("fixtures.json")
    require(len(expanded_fixtures) == len(fixtures), "Expanded fixture count")
    fixture_paths = {}
    for row in expanded_fixtures:
        reduced = dict(row)
        fixture_paths[row["name"]] = reduced.pop("path")
        same(fixtures[row["name"]], reduced, "Expanded fixture metadata")

    commands = [parse_json(line) for line in result_read("commands.jsonl").splitlines()]
    by_label = {command["label"]: command for command in commands}
    require(len(by_label) == len(commands) == 439, "Expected 439 unique component commands")
    for command in commands:
        label = command["label"]
        require(command["returncode"] == 0, f"Component command failed: {label}")
        require(command["seconds"] >= 0, f"Negative command duration: {label}")
        for stream in ("stdout", "stderr"):
            require(sha(result_read(command[stream])) == command[stream + "_sha256"],
                    f"Command log checksum: {label}/{stream}")

    synthetic_fonts = {}
    trace_receipts = []
    parity = result_obj("parity.json")
    parity_by_case = {row["case"]: row for row in parity}
    require(len(parity) == len(parity_by_case) == len(CASES), "Parity case count")
    checked_traces = 0
    packet_observations = 0
    omitted_arrays = 0
    expected_verify_labels = set()
    for case, shape in CASES.items():
        expected_fonts = []
        for name, size, seed in shape:
            key = f"{name}:{size}:{seed}"
            synthetic_fonts[key] = synthetic_font_hash(size, seed)
            expected_fonts.append({
                "bytes": size, "filename": name,
                "mime_type": "application/x-truetype-font",
                "sha256": synthetic_fonts[key], "supported_font": True,
            })
        same(expected_fonts, fixtures[case]["attachments"], f"Independent synthetic fonts/{case}")
        font_bytes = sum(size for _, size, _ in shape)
        require(fixtures[case]["accepted_payload_bytes"] == font_bytes, f"Font bytes/{case}")
        outputs = {}
        for variant in VARIANTS:
            label = f"verify-{case}-{variant}"
            expected_verify_labels.add(label)
            command = by_label[label]
            recorded_root = manifest["protocol"]["output"]
            binary = manifest["binaries"][variant]["executable"]
            same([f"{recorded_root}/{binary}", "verify", fixture_paths[case],
                  "default", "1", "1", str(font_bytes)], command["argv"],
                 f"Verification invocation/{label}")
            outputs[variant] = result_obj(command["stdout"])
            outer = dict(outputs[variant])
            del outer["traces"]
            same({"accepted_payload_bytes": font_bytes, "avcodec_version": 4070502,
                  "avformat_version": 4066406, "avutil_version": 3938918,
                  "ffmpeg_version": "8.1.2", "inputs": 1, "iterations": 1,
                  "loads_fonts": True, "mode": "verify", "policy": "default"},
                 outer, f"Verification envelope/{label}")
            require(set(outputs[variant]["traces"]) == set(APIS), f"API matrix/{label}")

        reference = outputs["baseline"]["traces"]["direct"]["default"]
        require(set(reference) == {"metadata", "codecs", "initial_packets", "seek_packets",
                                   "active_subtitle_packets"}, f"Trace shape/{case}")
        same(expected_fonts, reference["metadata"]["attachments"], f"Default fonts/{case}")
        require(len(reference["metadata"]["streams"]) == 3 + len(shape), f"Streams/{case}")
        require(len(reference["codecs"]) == 3 + len(shape), f"Codec count/{case}")
        normalized = copy.deepcopy(reference)
        normalized["metadata"]["attachments"] = []
        normalized_hash = sha(canonical(normalized))
        for variant in VARIANTS:
            for api in APIS:
                require(set(outputs[variant]["traces"][api]) == set(POLICIES),
                        f"Policy matrix/{case}/{variant}/{api}")
                for policy in POLICIES:
                    trace = outputs[variant]["traces"][api][policy]
                    omitted = variant == "candidate" and policy == "auxiliary"
                    expected = normalized if omitted else reference
                    same(expected, trace, f"Complete trace/{case}/{variant}/{api}/{policy}")
                    for index, font in enumerate(expected_fonts, start=3):
                        codec = trace["codecs"][index]
                        stream = trace["metadata"]["streams"][index]
                        require(stream["kind"] == "attachment" and stream["index"] == index,
                                f"Native attachment stream survives/{case}/{index}")
                        require(codec["index"] == index and codec["extradata_bytes"] == font["bytes"]
                                and codec["extradata_sha256"] == font["sha256"]
                                and codec["private_data_sha256"] == font["sha256"],
                                f"Native attachment codec-private bytes survive/{case}/{index}")
                    checked_traces += 1
                    omitted_arrays += int(omitted)
                    packet_observations += sum(len(trace[k]) for k in
                                               ("initial_packets", "seek_packets", "active_subtitle_packets"))
        counts = {key: len(reference[key]) for key in
                  ("initial_packets", "seek_packets", "active_subtitle_packets")}
        require(counts == {"initial_packets": 47, "seek_packets": 47,
                           "active_subtitle_packets": 1}, f"Nonempty packet fixture/{case}")
        expected_parity = {
            "case": case, **counts, "comparisons": 12,
            "complete_nonattachment_trace_sha256": normalized_hash,
            "font_payload_sha256_matches_manifest": True,
            "status": "equal apart from the expected empty auxiliary Swift font array",
        }
        same(expected_parity, parity_by_case[case], f"Recomputed parity report/{case}")
        trace_receipts.append({"case": case, "traces": 12, **counts,
                               "nonattachment_trace_sha256": normalized_hash,
                               "font_payload_bytes_per_including_input": font_bytes})
    require({label for label in by_label if label.startswith("verify-")} == expected_verify_labels,
            "Unexpected or missing verification commands")
    actual_trace_files = {str(path.relative_to(root / "auxiliary-font-results"))
                          for path in (root / "auxiliary-font-results/logs").glob("verify-*.stdout")}
    require(actual_trace_files == {by_label[label]["stdout"] for label in expected_verify_labels},
            "Unexpected or missing raw verification trace files")

    source_bytes = {}
    git_checks = 0
    for key, receipt in manifest["sources"].items():
        variant, repo_path = key.split(":", 1)
        require(variant in VARIANTS, f"Unexpected source variant: {key}")
        data = result_read(f"sources/{variant}/{repo_path}")
        require(len(data) == receipt["bytes"] and sha(data) == receipt["sha256"],
                f"Saved production source receipt: {key}")
        source_bytes[key] = data
        if args.repository:
            revision = BASELINE if variant == "baseline" else PROTOTYPE
            original = subprocess.run(["git", "-C", str(args.repository), "show",
                                       f"{revision}:{repo_path}"], check=True, capture_output=True).stdout
            require(original == data, f"Pinned Git source differs: {key}")
            git_checks += 1
    require(len(source_bytes) == 26, "Expected 26 saved production sources")
    paths = {key.split(":", 1)[1] for key in source_bytes}
    changed = sorted(path for path in paths
                     if source_bytes[f"baseline:{path}"] != source_bytes[f"candidate:{path}"])
    same(sorted(manifest["allowed_production_differences"]), changed, "Production source change inventory")
    compiled_checks = 0
    for variant in VARIANTS:
        for relative, expected_hash in manifest["compiled_sources"][variant].items():
            data = result_read(relative)
            require(sha(data) == expected_hash, f"Compiled source checksum: {relative}")
            if PurePosixPath(relative).name == "ExtractedDeclarations.swift":
                presenter = source_bytes[f"{variant}:Sources/IlliquidNativePlayback/Presentation/SampleBufferVideoPresenter.swift"].decode()
                subtitles = source_bytes[f"{variant}:Sources/IlliquidNativePlayback/Subtitles/BitmapSubtitleTimeline.swift"].decode()
                pieces = [declaration(presenter, "struct PresentationError: LocalizedError {"),
                          declaration(subtitles, "enum PGSSubtitlePacket {"),
                          declaration(subtitles, "enum DVBSubtitlePacket {")]
                expected = ("import Foundation\n\n" + "\n\n".join(pieces) + "\n").encode()
                require(data == expected, f"Extracted declarations differ from complete source: {variant}")
            else:
                matching = [key for key in source_bytes
                            if key.startswith(variant + ":") and PurePosixPath(key).name == PurePosixPath(relative).name]
                require(len(matching) == 1 and data == source_bytes[matching[0]],
                        f"Compiled source not identical to saved production source: {relative}")
            compiled_checks += 1
    require(compiled_checks == 20, "Expected 20 compiled-source files")

    driver_files = {
        "Benchmarks/AttachmentAdmission/run.py": "admission-source-helper.py",
        "Benchmarks/AuxiliaryFontAttachments/Harness.swift": "Harness.swift",
        "Benchmarks/AuxiliaryFontAttachments/MemoryProbe.h": "MemoryProbe.h",
        "Benchmarks/AuxiliaryFontAttachments/generate-fixtures.py": "generate-fixtures.py",
        "Benchmarks/AuxiliaryFontAttachments/run.py": "run.py",
    }
    require(set(manifest["drivers"]) == set(driver_files), "Driver inventory")
    for repo_path, saved_path in driver_files.items():
        data = result_read(saved_path)
        require(sha(data) == manifest["drivers"][repo_path], f"Saved driver checksum: {saved_path}")
        if args.repository:
            original = subprocess.run(["git", "-C", str(args.repository), "show",
                                       f"{PROTOTYPE}:{repo_path}"], check=True, capture_output=True).stdout
            require(original == data, f"Pinned Git driver differs: {repo_path}")
            git_checks += 1
    for path in ("include/ffmpeg_shim.h", "module.modulemap"):
        require(result_read(f"CFFmpeg/{path}") == source_bytes[f"candidate:Sources/CFFmpeg/{path}"],
                f"Compiled CFFmpeg module mismatch: {path}")
    require(result_read("MemoryProbe.h") == result_read("CAuxiliaryMemory/MemoryProbe.h"),
            "Memory probe module differs from driver")
    require(result_read("CAuxiliaryMemory/module.modulemap").strip()
            == b'module CAuxiliaryMemory [system] { header "MemoryProbe.h" export * }',
            "Unexpected memory probe module map")

    binary_receipts = {}
    for variant in VARIANTS:
        for product in ("executable", "library"):
            receipt = manifest["binaries"][variant]
            relative = receipt[product]
            actual = sha(result_read(relative))
            require(actual == receipt[product + "_sha256"], f"Binary checksum: {relative}")
            binary_receipts[relative] = actual
            linkage = by_label[f"{variant}-{product}-linkage"]
            require(result_read(linkage["stdout"]).decode() == receipt[product + "_linkage"],
                    f"Linkage log mismatch: {relative}")
        for kind in ("library", "driver"):
            argv = by_label[f"{variant}-{kind}-build"]["argv"]
            prefix = [manifest["compiler_path"], *manifest["compiler_flags"]]
            require(argv[:len(prefix)] == prefix, f"Common compiler flags: {variant}/{kind}")
            swift_sources = [arg for arg in argv if arg.endswith(".swift")]
            expected_paths = list(manifest["compiled_sources"][variant]) if kind == "library" else ["Harness.swift"]
            expected_sources = [manifest["protocol"]["output"] + "/" + path for path in expected_paths]
            require(sorted(swift_sources) == sorted(expected_sources), f"Compilation input inventory: {variant}/{kind}")
            require(("CANDIDATE" in argv) == (variant == "candidate" and kind == "driver"),
                    f"Wrong conditional driver variant: {variant}/{kind}")
            product = "library" if kind == "library" else "executable"
            require(argv[argv.index("-o") + 1] == manifest["protocol"]["output"] + "/"
                    + manifest["binaries"][variant][product], f"Compilation output: {variant}/{kind}")

    generator_receipt = obj("auxiliary-font-fixtures/generator-receipt.json")
    require(generator_receipt["generator_sha256"] == sha(result_read("generate-fixtures.py")),
            "Fixture generator receipt")
    fixture_commands = obj("auxiliary-font-fixtures/fixture-commands.json")
    require(len(fixture_commands) == 6 and all(row["returncode"] == 0 for row in fixture_commands),
            "Fixture generation commands")
    bundled_font_checked = False
    if args.repository:
        font = subprocess.run(["git", "-C", str(args.repository), "show",
                               f"{PROTOTYPE}:{generator_receipt['font_source']}"],
                              check=True, capture_output=True).stdout
        require(sha(font) == generator_receipt["bundled_font_sha256"], "Bundled real-font checksum")
        bundled_font_checked = True
        git_checks += 1

    native_log = read("auxiliary-font-tests/native-tests.log").decode()
    host = read("auxiliary-font-tests/host.txt").decode()
    require(PROTOTYPE in host and manifest["compiler"] in host, "Native host/source receipt")
    failures = re.findall(r"Tests/IlliquidNativePlaybackTests/(AuxiliaryFont(?:Attachment|Playback)Tests\.swift):(\d+):\d+: note: expanded code originates here", native_log)
    same([("AuxiliaryFontAttachmentTests.swift", "53"), ("AuxiliaryFontPlaybackTests.swift", "47")],
         failures, "Native test compiler failure locations")
    failure_message = "error: call can throw, but it is not marked with 'try' and the error is not handled"
    require(native_log.count("macro expansion #require:2:3: " + failure_message) == 2,
            "Expected two macro-expansion compiler failures")
    require("error: fatalError" in native_log, "Native test build did not report failure")
    require(not re.search(r"Test Suite .*started|Test run started|Test run with .*passed|Executed \d+ tests", native_log),
            "Unexpected native test execution; reevaluate qualification status")

    archive_receipt = {"checked": False}
    if args.archive:
        archive_bytes = args.archive.read_bytes()
        require(sha(archive_bytes) == ARCHIVE_SHA256, "Original archive SHA-256 mismatch")
        with zipfile.ZipFile(args.archive) as archive:
            entries = [entry for entry in archive.infolist() if not entry.is_dir()]
            names = [entry.filename for entry in entries]
            require(len(names) == len(set(names)), "Duplicate archive member")
            for entry in entries:
                require(archive.read(entry) == read(entry.filename), f"Extracted archive member: {entry.filename}")
        archive_receipt = {"checked": True, "sha256": ARCHIVE_SHA256,
                           "bytes": len(archive_bytes), "verified_members": len(entries)}

    return {
        "status": "passed", "workflow_run_id": 40101084730,
        "scope": "Independent verification of saved component traces, source/binary provenance, and recorded command outcomes",
        "baseline_revision": BASELINE, "measured_prototype_revision": PROTOTYPE,
        "trace_files": 8, "complete_traces_checked": checked_traces,
        "packet_hash_records_compared": packet_observations,
        "candidate_auxiliary_arrays_verified_empty": omitted_arrays,
        "parity_records_recomputed": len(trace_receipts), "cases": trace_receipts,
        "synthetic_font_hashes_recomputed": synthetic_fonts,
        "component_commands": {"count": len(commands), "successful": len(commands),
                               "stdout_and_stderr_checksums_verified": 2 * len(commands)},
        "fixture_generation_commands": {"count": len(fixture_commands), "successful": len(fixture_commands)},
        "provenance": {"saved_production_sources_checked": len(source_bytes),
                       "compiled_sources_checked": compiled_checks, "drivers_checked": len(driver_files),
                       "changed_measured_sources": changed, "binary_sha256": binary_receipts,
                       "pinned_git_file_checks": git_checks, "bundled_real_font_git_hash_checked": bundled_font_checked},
        "native_integration": {
            "qualified": False, "result": "test compilation failed before test execution",
            "failure_files": [{"file": name, "line": int(line)} for name, line in failures],
            "diagnostic": "Throwing copyCodecParameters call inside #require lacks an inner try",
            "process_exit_code_in_retained_artifact": None,
            "note": "commands.jsonl covers the successful component benchmark only; the separate native test log contains two compiler errors and fatalError, with no executed-test receipt",
            "native_log_sha256": sha(native_log.encode()),
        },
        "archive": archive_receipt,
        "limitations": [
            "Packet and codec payload SHA-256 receipts are compared; raw packet/container bytes are not present in this artifact.",
            "Synthetic font payload hashes are independently regenerated from their byte-pattern specification; full Matroska container hashes cannot be regenerated deterministically from receipts alone.",
            "The valid bundled-font integration fixture was generated, but its native rendering tests did not run because compilation failed.",
            "The macOS compiler, SDK, and external FFmpeg library/header bytes are not included; their recorded hashes cannot be reverified from this artifact.",
            "This script does not execute native binaries or prove rendering/playback parity, lower peak RSS, or qualification of a later production commit.",
        ],
        "required_artifact_files": sorted(files_used),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", "--artifact-root", dest="artifact_root", type=Path, required=True,
                        help="Extracted directory containing auxiliary-font-results, fixtures, and tests")
    parser.add_argument("--repository", type=Path,
                        help="Optional Git checkout containing both pinned revisions")
    parser.add_argument("--archive", type=Path,
                        help="Optional original auxiliary-font-native-40101084730.zip")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = audit(args)
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        result = {"status": "failed", "error": str(error), "native_integration_qualified": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: result[key] for key in
                      ("status", "complete_traces_checked", "packet_hash_records_compared", "error")
                      if key in result}, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
