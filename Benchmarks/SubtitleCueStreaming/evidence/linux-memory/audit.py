#!/usr/bin/env python3
"""Independently audit a complete SubtitleCueStreaming benchmark directory.

Does not import the benchmark runner or execute its binaries. Source strings,
expected memory-workload output, hashes, ordering, and numerical summaries are
checked from the retained files. Missing binaries are reported as unaudited;
missing raw traces or command logs fail the audit.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys


BASELINE_COMMIT = "ea2ff568237e2667f7b1aeee67b11a44ebe95b72"
BASELINE_SOURCE_SHA256 = "2a26e9951ac64921f398fc5f23c5d81c6c319952bfe02d9b2b3a0b4a765fdc28"
CANDIDATE_SOURCE_SHA256 = "54518e8125f510752d8167ebab96eba2dd19dc4263a7da46e1f08c970ab40887"
CONFIGURATIONS = ("baseline-debug", "candidate-debug", "baseline-release", "candidate-release")
TIMING_CASES = ("srt-short", "vtt-short", "srt-crlf", "vtt-crlf", "srt-multiline",
                "srt-dense", "srt-long-line", "invalid-preamble")
MEMORY_CASES = ("srt-short", "vtt-short", "srt-ordinary-2000", "vtt-ordinary-2000",
                "srt-dense-64k", "vtt-dense-64k", "srt-dense-256k", "vtt-dense-256k",
                "vtt-note-64k", "vtt-note-256k", "srt-long-line-4mib", "vtt-long-line-4mib")
TEST_FILES = ("ExternalTextSubtitleConverterTests.swift", "ExternalSubtitleEscapingTests.swift",
              "SubtitleCueStreamingTests.swift")
EXPECTED_TEST_COUNT = 47
METRICS = ("peak_rss_bytes", "peak_rss_before_fixture_bytes",
           "peak_rss_before_conversion_bytes", "peak_rss_growth_bytes")
ASS_HEADER = "\n".join([
    "[Script Info]", "ScriptType: v4.00+", "PlayResX: 1920", "PlayResY: 1080",
    "ScaledBorderAndShadow: yes", "", "[V4+ Styles]",
    "Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding",
    "Style: Default,sans-serif,52,&H00FFFFFF,&H000000FF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,48,48,40,1",
    "", "[Events]", "Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text",
])
MIB = 1024 * 1024


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def describe(values):
    return {"median": median(values), "min": min(values), "max": max(values), "samples": values}


def fnv(format_name, source):
    value = 14695981039346656037
    for byte in (format_name + "\0" + source).encode("utf-8"):
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return format(value, "x")


def input_time(seconds, fraction, srt):
    return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}" + ("," if srt else ".") + fraction


def ass_time(seconds, fraction):
    return f"{seconds // 3600}:{seconds // 60 % 60:02d}:{seconds % 60:02d}.{fraction}"


def event(start, end, payload):
    return f"\nDialogue: 0,{start},{end},Default,,0,0,0,,{payload}"


def expected_memory_fixture(name):
    """Reconstruct the twelve workload inputs and outputs independently in Python."""
    srt = name.startswith("srt-")
    prefix = "" if srt else "WEBVTT\n\n"
    payload_line = "subtitle line 00"
    format_name = "srt" if srt else "webVTT"
    output = ASS_HEADER
    if name in ("srt-short", "vtt-short", "srt-ordinary-2000", "vtt-ordinary-2000"):
        ordinary = name.endswith("ordinary-2000")
        count = 2000 if ordinary else 128
        blocks = []
        events = []
        for cue in range(count):
            timing = input_time(cue * 3, "120", srt) + " --> " + input_time(cue * 3 + 2, "840", srt)
            if ordinary:
                identifier = str(cue + 1)
                payload = f"The first ordinary subtitle for cue {cue}.\nThe second ordinary subtitle line."
            elif srt:
                identifier = str(cue + 1)
                payload = f"A short subtitle for cue {cue}."
            else:
                identifier = f"cue-{cue}"
                timing += " align:start position:10% line:90%"
                payload = f"The first subtitle line for cue {cue}.\nThe second line has café and 東京."
            blocks.append(identifier + "\n" + timing + "\n" + payload)
            events.append(event(ass_time(cue * 3, "12"), ass_time(cue * 3 + 2, "84"), payload.replace("\n", "\\N")))
        return format_name, prefix + "\n\n".join(blocks), output + "".join(events), count
    if "dense-" in name:
        count = 65536 if name.endswith("64k") else 262144
        timing = "1\n00:00:00,000 --> 00:00:02,000\n" if srt else "00:00:00.000 --> 00:00:02.000\n"
        source = prefix + timing + "\n".join([payload_line] * count)
        output += event("0:00:00.00", "0:00:02.00", "\\N".join([payload_line] * count))
        return format_name, source, output, 1
    if name.startswith("vtt-note-"):
        count = 65536 if name.endswith("64k") else 262144
        source = prefix + "NOTE memory fixture\n" + "\n".join([payload_line] * count)
        source += "\n\n00:00:03.000 --> 00:00:04.000\nRetained cue"
        return format_name, source, output + event("0:00:03.00", "0:00:04.00", "Retained cue"), 1
    if name.endswith("long-line-4mib"):
        timing = "1\n00:00:00,000 --> 00:00:02,000\n" if srt else "00:00:00.000 --> 00:00:02.000\n"
        payload = "x" * (4 * MIB)
        return format_name, prefix + timing + payload, output + event("0:00:00.00", "0:00:02.00", payload), 1
    raise AssertionError(f"Unknown memory fixture {name}")


class Audit:
    def __init__(self, root, expected_commit):
        self.root = root
        self.expected_commit = expected_commit
        self.files = {}
        self.warnings = []

    def read(self, name):
        data = (self.root / name).read_bytes()
        self.files[name] = sha(data)
        return data

    def json(self, name):
        return json.loads(self.read(name))

    def jsonl(self, name):
        return [json.loads(line) for line in self.read(name).splitlines() if line]

    def command_log(self, label):
        require(label in self.commands, f"Missing command receipt {label}")
        receipt = self.commands[label]
        require(receipt["exit_code"] == 0, f"Command failed: {label}")
        require(receipt["log"] == label + ".log", f"Unexpected log name: {label}")
        data = self.read(receipt["log"])
        # The runner stores stdout + stderr. Recover the split from their
        # independent hashes; every recorded tool finishes stdout on a line edge.
        candidates = [0, len(data)]
        candidates.extend(match.end() for match in re.finditer(b"\n", data))
        for split in dict.fromkeys(candidates):
            if sha(data[:split]) == receipt["stdout_sha256"] and sha(data[split:]) == receipt["stderr_sha256"]:
                self.checked_logs.add(label)
                return data[:split], data[split:]
        raise AssertionError(f"Cannot validate stdout/stderr hashes for {label}")

    def log_json(self, label):
        out, _ = self.command_log(label)
        return json.loads(out)

    def observation(self, row, mode, reference):
        require(row["schema_version"] == 1 and row["mode"] == mode, f"Wrong observation mode {row.get('case')}")
        require(reference["status"] == "success", "Workload reference is not successful")
        for key in ("fixture_checksum", "input_bytes", "output_bytes"):
            require(row[key] == reference[key], f"Observation/reference mismatch {row['case']} {key}")
        require(row["fixture_count"] == 1, "Unexpected fixture count")
        output = reference["output"].encode("utf-8")
        token = len(output) + (output[-1] if output else 0)
        require(row["cycle_checksum"] == token, "Output checksum token differs")
        multiplier = row["iterations"] if mode == "measure" else 1
        require(row["checksum"] == row["expected_checksum"] == token * multiplier, "Consumed checksum differs")

    def run(self):
        provenance = self.json("provenance.json")
        completion = self.json("completion.json")
        require(completion.get("passed") is True and not completion.get("tests_only"), "Incomplete benchmark")
        require(provenance["baseline_commit"] == BASELINE_COMMIT, "Unexpected baseline commit")
        require(provenance["pairs"] == 8, "Study must have eight pairs")
        if self.expected_commit:
            require(provenance["candidate_commit"] == self.expected_commit, "Unexpected measured commit")
        require(provenance["baseline_sha256"] == BASELINE_SOURCE_SHA256, "Baseline production source differs")
        require(provenance["candidate_sha256"] == CANDIDATE_SOURCE_SHA256, "Candidate production source differs")
        require(completion["timing_rows"] == 128 and completion["memory_rows"] == 192, "Unexpected completion counts")

        commands = self.json("commands.json")
        require(len(commands) == len({r["label"] for r in commands}), "Duplicate command labels")
        self.commands = {r["label"]: r for r in commands}
        self.checked_logs = set()
        command_order = [r["label"] for r in commands]
        for command in commands:
            require(command["exit_code"] == 0, f"Failed command {command['label']}")

        source_hashes = {}
        for name, field in (("baseline.swift", "baseline_sha256"), ("candidate.swift", "candidate_sha256"),
                            ("Driver.swift", "driver_sha256"), ("run.py", "runner_sha256"),
                            ("fresh_process.py", "memory_launcher_sha256"),
                            ("test_memory_launcher.py", "memory_launcher_test_sha256")):
            measured = sha(self.read("sources/" + name))
            require(measured == provenance[field], f"Source snapshot hash differs: {name}")
            source_hashes[name] = measured
        head, _ = self.command_log("head")
        require(head.decode().strip() == provenance["candidate_commit"], "Head command/provenance differs")
        baseline_source, _ = self.command_log("baseline-source")
        require(sha(baseline_source) == BASELINE_SOURCE_SHA256, "Git baseline receipt/source differs")
        compiler, _ = self.command_log("swift-version")
        require(compiler.decode().strip() == provenance["swift"], "Compiler receipt/provenance differs")
        for label in CONFIGURATIONS:
            variant, configuration = label.split("-")
            command = self.commands["build-" + label]["command"]
            require(command[command.index("-swift-version") + 1] == "6" and "-parse-as-library" in command,
                    "Unexpected compiler language mode")
            require("-Onone" in command if configuration == "debug"
                    else "-O" in command and "-whole-module-optimization" in command,
                    "Unexpected optimization flags")
            require(Path(command[-4]).name == variant + ".swift" and Path(command[-3]).name == "Driver.swift"
                    and command[-2] == "-o" and Path(command[-1]).name == label,
                    "Compiler command does not reference the expected source snapshots")
        package_hashes = {}
        for variant in ("baseline", "candidate"):
            prefix = "tests-" + variant + "/"
            production_copy = self.read(prefix + "Sources/IlliquidNativePlayback/ExternalTextSubtitleConverter.swift")
            require(sha(production_copy) == provenance[variant + "_sha256"], "Isolated test package production source differs")
            package_hashes[variant] = {"production_sha256": sha(production_copy),
                                      "manifest_sha256": sha(self.read(prefix + "Package.swift")),
                                      "test_source_sha256": {name: sha(self.read(prefix + "Tests/IlliquidNativePlaybackTests/" + name))
                                                             for name in TEST_FILES}}
        require(package_hashes["baseline"]["manifest_sha256"] == package_hashes["candidate"]["manifest_sha256"],
                "Baseline/candidate package manifests differ")
        require(package_hashes["baseline"]["test_source_sha256"] == package_hashes["candidate"]["test_source_sha256"],
                "Baseline/candidate test sources differ")

        parity = self.json("parity.json")
        require(parity["passed"] is True and parity["case_count"] == 274, "Wrong parity qualification")
        require(parity["configurations"] == list(CONFIGURATIONS), "Parity configurations differ")
        first = self.json("trace-baseline-debug.json")
        require(first["mode"] == "verify" and first["schema_version"] == 1, "Wrong trace schema")
        require(first["case_count"] == len(first["cases"]) == 274, "Wrong trace case count")
        by_id = {row["id"]: row for row in first["cases"]}
        require(len(by_id) == 274, "Duplicate trace IDs")
        case_hashes = []
        successes = 0
        for row in first["cases"]:
            source = row["source"].encode("utf-8")
            require(row["format"] in ("srt", "webVTT"), "Unexpected fixture format")
            require(row["input_bytes"] == len(source), f"Input length differs: {row['id']}")
            require(row["fixture_checksum"] == fnv(row["format"], row["source"]), f"Input FNV differs: {row['id']}")
            receipt = {"id": row["id"], "source_sha256": sha(source), "fixture_checksum": row["fixture_checksum"],
                       "status": row["status"]}
            if row["status"] == "success":
                output = row["output"].encode("utf-8")
                require(row["output_bytes"] == len(output), f"Output length differs: {row['id']}")
                receipt["output_sha256"] = sha(output)
                successes += 1
            else:
                require(row["status"] == "error", "Unknown trace status")
                require(row["error"] in ("missingWebVTTSignature", "noValidCues(srt)", "noValidCues(webVTT)"), "Unknown typed error")
                receipt["error"] = row["error"]
            case_hashes.append(receipt)
        for configuration in CONFIGURATIONS:
            current = first if configuration == "baseline-debug" else self.json("trace-" + configuration + ".json")
            require(current == first, f"Complete input/output/error parity differs: {configuration}")
            require(self.log_json("verify-" + configuration) == first, f"Verify process output/trace differs: {configuration}")
            del current

        catalog = self.json("memory-cases.json")
        require(catalog["mode"] == "list-memory" and catalog["schema_version"] == 1, "Wrong memory catalog mode")
        require(catalog["cases"] == list(MEMORY_CASES), "Memory cases or order differ")
        require(catalog["verification_ids"] == ["workload-" + name for name in MEMORY_CASES], "Memory verification IDs differ")
        require(self.log_json("list-memory") == catalog, "Memory catalog command differs")
        for name in MEMORY_CASES:
            expected_format, expected_source, expected_output, expected_count = expected_memory_fixture(name)
            reference = by_id["workload-" + name]
            require(reference["format"] == expected_format, f"Independent expected format differs: {name}")
            require(reference["source"] == expected_source, f"Independent expected input differs: {name}")
            require(reference["output"] == expected_output, f"Independent expected output differs: {name}")
            require(reference["expected_cue_count"] == expected_count == reference["output"].count("\nDialogue: "),
                    f"Independent expected cue count differs: {name}")

        launcher_out, launcher_err = self.command_log("test-memory-launcher")
        require(b"Ran 2 tests" in launcher_err and re.search(rb"\nOK(?:\s|\()", launcher_err), "Launcher tests did not pass")
        probe = None
        if provenance["platform"].startswith("Linux"):
            probe = json.loads(launcher_out)["memory_launcher_probe"]
            require(probe["held_bytes"] == 128 * MIB, "Wrong contamination control size")
            require(probe["direct_child_peak_bytes"] >= probe["held_bytes"], "Contaminated launch control did not reproduce")
            require(probe["isolated_child_peak_bytes"] > 0, "Invalid isolated probe peak")
            require(probe["direct_child_peak_bytes"] - probe["isolated_child_peak_bytes"] >= 64 * MIB,
                    "Fresh launch did not isolate the contamination control")

        test_results = self.json("tests.json")
        expected_test_order = [("baseline", "debug"), ("baseline", "release"), ("candidate", "debug"), ("candidate", "release")]
        require([(r["variant"], r["configuration"]) for r in test_results] == expected_test_order, "Test configurations differ")
        for result in test_results:
            require(result["passed"] is True and result["test_count"] == EXPECTED_TEST_COUNT, "Wrong focused test result")
            require(result["files"] == list(TEST_FILES), "Unexpected focused test selection")
            out, err = self.command_log(f"tests-{result['variant']}-{result['configuration']}")
            counts = re.findall(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", (out + err).decode())
            require(counts and int(counts[-1]) == EXPECTED_TEST_COUNT, "Focused test log/count differs")

        pilots = self.json("calibration.json")
        calibration_counts = {}
        pilot_labels = []
        for case in TIMING_CASES:
            for variant in ("baseline", "candidate"):
                subset = [r for r in pilots if r["case"] == case and r["variant"] == variant]
                require(1 <= len(subset) <= 8, "Invalid calibration attempt count")
                expected_iterations = 1
                for attempt, row in enumerate(subset):
                    self.observation(row, "measure", by_id["workload-" + case])
                    require(row["iterations"] == expected_iterations and row["warmup_iterations"] == 2, "Calibration iteration path differs")
                    label = f"pilot-{case}-{variant}-{attempt}"
                    pilot_labels.append(label)
                    require(self.log_json(label) == {k: v for k, v in row.items() if k != "variant"}, "Calibration process receipt differs")
                    elapsed = min(row["wall_ns"], row["cpu_ns"])
                    require(elapsed > 0, "Invalid calibration duration")
                    if attempt != len(subset) - 1:
                        require(elapsed < provenance["target_ms"] * 1_000_000, "Unexplained additional calibration")
                        expected_iterations = min(1_000_000, max(expected_iterations + 1,
                            math.ceil(expected_iterations * provenance["target_ms"] * 1_000_000 / elapsed * 1.15)))
                    else:
                        require(elapsed >= provenance["target_ms"] * 1_000_000, "Calibration did not meet target")
                        calibration_counts[(case, variant)] = row["iterations"]
        require([label for label in command_order if label.startswith("pilot-")] == pilot_labels, "Calibration command order/completeness differs")
        require(len(pilot_labels) == len(pilots), "Unreported or duplicate pilot rows")

        timing = self.jsonl("measurements.jsonl")
        memory = self.jsonl("memory.jsonl")
        require(len(timing) == 128 and len(memory) == 192, "Wrong raw observation counts")
        expected_labels = {"measure": [], "memory": []}
        for mode, rows, cases in (("measure", timing, TIMING_CASES), ("memory", memory, MEMORY_CASES)):
            expected_sequence = [(case, pair, variant) for case in cases for pair in range(8)
                                 for variant in (("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline"))]
            for ordinal, (row, expected) in enumerate(zip(rows, expected_sequence)):
                require((row["case"], row["pair"], row["variant"]) == expected and row["ordinal"] == ordinal,
                        f"{mode} AB/BA pair order differs at {ordinal}")
                case, pair, variant = expected
                reference = by_id["workload-" + case]
                self.observation(row, mode, reference)
                label = f"{mode}-{case}-{pair}-{variant}"
                expected_labels[mode].append(label)
                raw = {k: v for k, v in row.items() if k not in ("variant", "pair", "ordinal")}
                require(self.log_json(label) == raw, f"Observation/process receipt differs: {label}")
                command = self.commands[label]["command"]
                if mode == "measure":
                    require(row["iterations"] == calibration_counts[(case, variant)], "Timed iteration count differs from calibration")
                    require(row["warmup_iterations"] == 2, "Wrong timing warmup count")
                    require(min(row["wall_ns"], row["cpu_ns"]) >= 60_000_000, "Timing below qualification floor")
                    require(command[-3:] == ["measure", case, str(row["iterations"])], "Timed command arguments differ")
                    require(Path(command[-4]).name == variant + "-release", "Wrong timed binary")
                else:
                    require(row["conversion_count"] == 1 and row["warmup_iterations"] == 0, "Memory observation was not one cold conversion")
                    require(row["rss_unit"] == "bytes" and "getrusage(RUSAGE_SELF).ru_maxrss" in row["rss_source"], "Wrong RSS metric/units")
                    require(row["expected_cue_count"] == reference["expected_cue_count"], "Memory cue count differs")
                    require(row["peak_rss_bytes"] >= row["peak_rss_before_conversion_bytes"] >= row["peak_rss_before_fixture_bytes"] > 0,
                            "Nonmonotonic or invalid RSS watermarks")
                    require(row["peak_rss_growth_bytes"] == row["peak_rss_bytes"] - row["peak_rss_before_conversion_bytes"], "Incorrect RSS growth")
                    require(len(command) == 6 and command[1] == "-I" and Path(command[2]).name == "fresh_process.py",
                            "Memory command omitted isolated launcher")
                    require(Path(command[3]).name == variant + "-release" and command[4:] == ["memory", case], "Wrong memory binary/arguments")
            require([label for label in command_order if label.startswith(mode + "-")] == expected_labels[mode],
                    f"{mode} command order/completeness differs")

        memory_summary = []
        memory_findings = []
        for case in MEMORY_CASES:
            item = {"case": case, "pairs": 8, "rss_unit": "bytes"}
            for variant in ("baseline", "candidate"):
                subset = [r for r in memory if r["case"] == case and r["variant"] == variant]
                item[variant] = {metric: describe([r[metric] for r in subset]) for metric in METRICS}
                item[variant].update(input_bytes=subset[0]["input_bytes"], output_bytes=subset[0]["output_bytes"])
            changes = []
            for pair in range(8):
                a = next(r for r in memory if r["case"] == case and r["pair"] == pair and r["variant"] == "baseline")
                b = next(r for r in memory if r["case"] == case and r["pair"] == pair and r["variant"] == "candidate")
                changes.append(100 * (b["peak_rss_bytes"] / a["peak_rss_bytes"] - 1))
            item["paired_peak_rss_change_percent"] = describe(changes)
            memory_summary.append(item)
            memory_findings.append({"case": case,
                "baseline_median_peak_mib": item["baseline"]["peak_rss_bytes"]["median"] / MIB,
                "candidate_median_peak_mib": item["candidate"]["peak_rss_bytes"]["median"] / MIB,
                "median_paired_change_percent": median(changes),
                "pairs_lower": sum(x < 0 for x in changes), "pairs_equal": sum(x == 0 for x in changes),
                "pairs_higher": sum(x > 0 for x in changes)})
        require(self.json("memory-summary.json") == memory_summary, "Memory summary does not match independently recomputed values")

        timing_summary = []
        timing_findings = []
        for case in TIMING_CASES:
            item = {"case": case, "pairs": 8}
            finding = {"case": case}
            for variant in ("baseline", "candidate"):
                subset = [r for r in timing if r["case"] == case and r["variant"] == variant]
                item[variant] = {metric + "_per_conversion": describe([r[metric] / r["iterations"] for r in subset])
                                 for metric in ("wall_ns", "cpu_ns")}
                item[variant].update(input_bytes=subset[0]["input_bytes"], output_bytes=subset[0]["output_bytes"], iterations=subset[0]["iterations"])
            for metric in ("wall_ns", "cpu_ns"):
                key = metric + "_per_conversion"
                item[metric + "_median_speedup"] = item["baseline"][key]["median"] / item["candidate"][key]["median"]
                effects = []
                for pair in range(8):
                    a = next(r for r in timing if r["case"] == case and r["pair"] == pair and r["variant"] == "baseline")
                    b = next(r for r in timing if r["case"] == case and r["pair"] == pair and r["variant"] == "candidate")
                    effects.append(100 * ((b[metric] / b["iterations"]) / (a[metric] / a["iterations"]) - 1))
                finding[metric] = {"baseline_median_ms": item["baseline"][key]["median"] / 1e6,
                                   "candidate_median_ms": item["candidate"][key]["median"] / 1e6,
                                   "median_paired_change_percent": median(effects), "pairs_lower": sum(x < 0 for x in effects)}
            subset = [r for r in memory if r["case"] == case]
            if subset:
                item["process_peak_rss_bytes"] = {variant: {
                    "median": median([r["peak_rss_bytes"] for r in subset if r["variant"] == variant]),
                    "samples": [r["peak_rss_bytes"] for r in subset if r["variant"] == variant]}
                    for variant in ("baseline", "candidate")}
            timing_summary.append(item)
            timing_findings.append(finding)
        require(self.json("summary.json") == timing_summary, "Timing summary does not match independently recomputed values")

        binaries = {}
        require(set(completion["binaries"]) == set(CONFIGURATIONS), "Wrong binary hash catalog")
        for label in CONFIGURATIONS:
            binary = self.root / label
            if binary.is_file():
                actual = sha(self.read(label))
                require(actual == completion["binaries"][label], f"Binary hash differs: {label}")
                binaries[label] = {"available": True, "verified_sha256": actual}
            else:
                binaries[label] = {"available": False, "recorded_sha256": completion["binaries"][label]}
        if not all(value["available"] for value in binaries.values()):
            self.warnings.append("Some binaries are not retained in the CI artifact; their recorded hashes could not be independently recomputed.")
        for label in command_order:
            if label not in self.checked_logs:
                self.command_log(label)

        prefixture = [r["peak_rss_before_fixture_bytes"] for r in memory]
        return {"passed": True,
            "measured_candidate_commit": provenance["candidate_commit"],
            "compiler": provenance["swift"], "platform": provenance["platform"],
            "source_hashes": source_hashes, "binaries": binaries,
            "compiler_commands_verified": True, "test_package_hashes": package_hashes,
            "exact_parity": {"cases": 274, "configurations": list(CONFIGURATIONS), "successful_cases": successes,
                             "typed_error_cases": 274 - successes, "independently_reconstructed_memory_cases": 12,
                             "case_hashes": case_hashes},
            "tests": {"configurations": 4, "tests_per_configuration": EXPECTED_TEST_COUNT,
                      "executions": EXPECTED_TEST_COUNT * 4,
                      "launcher_tests": 2, "launcher_probe": probe},
            "timing": {"rows": 128, "calibration_rows": len(pilots), "pairs_per_case": 8,
                       "minimum_wall_ms": min(r["wall_ns"] for r in timing) / 1e6,
                       "minimum_cpu_ms": min(r["cpu_ns"] for r in timing) / 1e6,
                       "recomputed_summary_matches": True, "findings": timing_findings},
            "memory": {"rows": 192, "cases": 12, "pairs_per_case": 8,
                       "ab_ba_order_verified": True, "recomputed_summary_matches": True,
                       "prefixture_peak_min_mib": min(prefixture) / MIB,
                       "prefixture_peak_max_mib": max(prefixture) / MIB,
                       "distinct_prefixture_peaks": len(set(prefixture)),
                       "zero_growth_observations": sum(r["peak_rss_growth_bytes"] == 0 for r in memory),
                       "findings": memory_findings},
            "command_receipts": {"count": len(commands), "stdout_stderr_hashes_verified": len(self.checked_logs),
                                 "all_exits_zero": True, "no_missing_or_unreported_measurements": True},
            "scope": "Whole-process peak RSS including runtime and fixture construction; not isolated heap, retained memory, or player performance.",
            "warnings": self.warnings, "audited_file_sha256": self.files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-commit")
    args = parser.parse_args()
    report = {"audit_schema_version": 1, "audit_script_sha256": sha(Path(__file__).read_bytes())}
    try:
        report.update(Audit(args.directory, args.expected_commit).run())
    except Exception as error:
        report.update(passed=False, error=f"{type(error).__name__}: {error}")
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    concise = {key: report[key] for key in ("passed", "error", "warnings") if key in report}
    if report["passed"]:
        concise.update(memory=report["memory"], command_receipts=report["command_receipts"])
    print(json.dumps(concise, indent=2, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
