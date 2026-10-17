#!/usr/bin/env python3
"""Compare baseline/candidate complete ASS bytes and errors on a generated corpus."""
from __future__ import annotations

import argparse
from itertools import product
from pathlib import Path
import hashlib
import json
import platform
import random
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "68274d1b09dcc866296321a5a8858efc297c4f19"
SOURCE = "Sources/IlliquidNativePlayback/Subtitles/ExternalTextSubtitleConverter.swift"
DRIVER = Path(__file__).with_name("Differential.swift")
SEED = 0x1_11_1_01D


def make_corpus() -> list[dict[str, str]]:
    cases = []


    def add(category, source, fmt):
        cases.append({"id": f"{category}-{len(cases):05d}", "category": category,
                      "format": fmt, "source": source})


    def cue(payload, fmt, newline="\n", identifier=True):
        header = "WEBVTT" + newline * 2 if fmt == "webVTT" else ""
        token = "." if fmt == "webVTT" else ","
        number = "cue-1" + newline if identifier else ""
        return header + number + f"00:00:01{token}005 --> 00:00:03{token}250" + newline + payload


    # All short combinations of ASCII escapes, combining/format scalars and a NUL.
    # No normalization is applied to the generated strings.
    alphabet = ["x", "\\", "{", "}", "\u0301", "\ufe0f", "\u200d", "\x00", "\n"]
    for size in range(5):
        for tokens in product(alphabet, repeat=size):
            payload = "".join(tokens)
            for fmt in ["srt", "webVTT"]:
                add("exhaustive-short-payload", cue(payload, fmt), fmt)

    # Non-ASCII title material is preserved exactly, including decomposed forms.
    scalars = ["\u0301", "\u034f", "\u036f", "\u0488", "\u05b0", "\u093f", "\u0bbe",
               "\u1ab0", "\u20dd", "\u20e3", "\ufe00", "\ufe0f", "\U000e0100",
               "\u200c", "\u200d", "\u200e", "\u2066", "\u2067", "\u2069",
               "é", "e\u0301", "日本語", "👩🏽\u200d💻", "🇺🇸", "\x01", "\x1f", "\x7f",
               "\u0085", "\u2028", "\u2029", "\u00a0", "\ufeff", "\ufffd", "\U0010ffff"]
    for scalar in scalars:
        for special in ["\\", "{", "}", "\\N", "{\\an8}", "\\{\\}"]:
            for payload in [special + scalar, scalar + special, scalar + special + scalar,
                            "A" + scalar + special + "Z", special * 4 + scalar * 4]:
                for fmt in ["srt", "webVTT"]:
                    add("unicode-adjacency", cue(payload, fmt), fmt)

    # Blank lines, mixed CR/LF runs, empty payloads and malformed VTT signatures.
    newlines = ["\n", "\r", "\r\n", "\n\r", "\r\r\n", "\r\n\n", "\n\r\n"]
    payloads = ["", " ", "\t", "\\", "{}", "first\nsecond", "first\n", "\nfirst",
                "first\n\nsecond", "\n\n", "first\rsecond", "first\r\nsecond", "\r\n\r",
                "{\u0301\\\u0301}\u0301\n\u0301\\N", "\x00\n\x00"]
    for newline, payload, fmt, identifier in product(newlines, payloads, ["srt", "webVTT"], [False, True]):
        add("newline-boundaries", cue(payload, fmt, newline, identifier), fmt)
    for signature in ["WEBVTT", "WEBVTT metadata", "WEBVTT\t", "\ufeffWEBVTT", "\ufeff\ufeffWEBVTT",
                      "\ufeff\u0301WEBVTT", "WEBVTT\u0301", "webvtt", "WEBVTT\u00a0", "WEBVTT\x00", ""]:
        for newline in newlines:
            add("vtt-signatures", signature + newline * 2 + "00:01.000 --> 00:02.000" + newline + "{\\N}", "webVTT")

    for fmt in ["srt", "webVTT"]:
        for first in ["NOTE", "NOTE text", "NOTE\ttext", "NOTEworthy", "STYLE", "REGION", " ", "\x00"]:
            for separator in ["\n", "\n\n", "\r", "\r\n"]:
                header = "WEBVTT\n\n" if fmt == "webVTT" else ""
                decimal = "." if fmt == "webVTT" else ","
                body = first + separator + f"00:00:01{decimal}000 --> 00:00:02{decimal}000\n{{\\N}}"
                valid = f"\n\n00:00:03{decimal}000 --> 00:00:04{decimal}000\nLater {{cue}}"
                add("metadata-recovery", header + body + valid, fmt)

    # Parser rejection and recovery must have the same complete result/errors.
    timestamps = ["", "nan", "00:00:01,000", "00:00:01.000", "00:01.000", "00:00:01",
                  "00:00:01,5", "00:00:01,005999", "00:60:00.000", "00:00:60.000",
                  "2147483647:59:59.994", "2147483647:59:59.995", "2147483648:00:00.000",
                  "00:00:01\u0301.000", "00:00:01.0\u030100", "00:00:01.000\x00",
                  "00:00:01.000 align:start", " 00:00:01.000\t", "00:00:01.000 --> garbage",
                  "٩٩:00:01.000", "".join(["9"] * 20000) + ":00:00.000"]
    for fmt in ["srt", "webVTT"]:
        for timestamp in timestamps:
            for endpoint in [0, 1]:
                for recover in [False, True]:
                    token = "." if fmt == "webVTT" else ","
                    endpoints = [f"00:00:00{token}000", f"00:00:03{token}000"]
                    endpoints[endpoint] = timestamp
                    header = "WEBVTT\n\n" if fmt == "webVTT" else ""
                    source = header + " --> ".join(endpoints) + "\n{\u0301\\N}"
                    if recover:
                        source += f"\n\n00:00:04{token}000 --> 00:00:05{token}000\nSecond {{\\cue}}"
                    add("malformed-timestamps", source, fmt)

    # Reproducible realistic and hostile larger strings, plus whole-file mutation.
    rng = random.Random(SEED)
    tokens = ["A", "word ", "\n", "\r", "\r\n", "\\", "{", "}", "é", "e\u0301", "日本語",
              "\u0301", "\ufe0f", "\u200d", "\x00", "👩🏽\u200d💻", " --> ", "WEBVTT", "\n\n"]
    for index in range(1200):
        payload = "".join(rng.choices(tokens, k=rng.randrange(1, 160)))
        fmt = "srt" if index % 2 else "webVTT"
        source = cue(payload, fmt, rng.choice(["\n", "\r", "\r\n"]))
        if index % 3 == 0:
            position = rng.randrange(len(source) + 1)
            source = source[:position] + rng.choice(tokens) + source[position:]
        add("seeded-file-mutations", source, fmt)
    for size in [1, 16, 1024, 32768]:
        for material in ["a", "é日本語", "\\", "{}", "\\{}", "{\u0301\\\ufe0f}"]:
            for fmt in ["srt", "webVTT"]:
                add("long-payloads", cue(material * size, fmt), fmt)
    return cases


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new or empty evidence directory")
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be new or empty")
    compiler = shutil.which("swiftc")
    if compiler is None:
        parser.error("swiftc is required on PATH")
    baseline = subprocess.check_output(["git", "show", f"{BASELINE}:{SOURCE}"], cwd=ROOT)
    candidate = (ROOT / SOURCE).read_bytes()
    marker = b"enum ExternalTextSubtitleConverter {"
    if baseline.count(marker) != 1:
        raise RuntimeError("Expected exactly one baseline converter namespace declaration")
    renamed_baseline = baseline.replace(marker, b"enum BaselineExternalTextSubtitleConverter {", 1)
    output.mkdir(parents=True, exist_ok=True)
    baseline_path = output / "BaselineConverter.swift"
    candidate_path = output / "ExternalTextSubtitleConverter.swift"
    driver_path = output / "Differential.swift"
    baseline_path.write_bytes(renamed_baseline)
    candidate_path.write_bytes(candidate)
    driver_path.write_bytes(DRIVER.read_bytes())
    corpus = make_corpus()
    corpus_data = (json.dumps(corpus, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    corpus_path = output / "cases.json"
    corpus_path.write_bytes(corpus_data)
    flags = ["-O" if args.configuration == "release" else "-Onone",
             "-swift-version", "6", "-warnings-as-errors", "-parse-as-library"]
    if platform.system() == "Darwin":
        flags += ["-target", f"{platform.machine()}-apple-macosx26.0"]
    manifest = {
        "schema": 1, "status": "incomplete",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "platform": platform.platform(), "machine": platform.machine(),
        "baseline_commit": BASELINE, "source_path": SOURCE,
        "checkout_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "baseline_original_sha256": digest(baseline),
        "baseline_compiled_sha256": digest(renamed_baseline),
        "baseline_transformation": "Rename enum ExternalTextSubtitleConverter to BaselineExternalTextSubtitleConverter only",
        "candidate_sha256": digest(candidate), "driver_sha256": digest(DRIVER.read_bytes()),
        "runner_sha256": digest(Path(__file__).read_bytes()),
        "configuration": args.configuration, "compiler_flags": flags,
        "corpus_sha256": digest(corpus_data), "corpus_bytes": len(corpus_data),
        "corpus_cases": len(corpus), "random_seed": SEED, "commands": [],
    }
    manifest_path = output / "manifest.json"

    def save() -> None:
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")

    def run(command: list[str]) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(command, capture_output=True, text=True)
        manifest["commands"].append({"command": command, "returncode": result.returncode,
                                    "stdout": result.stdout, "stderr": result.stderr})
        save()
        if result.returncode:
            raise RuntimeError(f"Verification command failed; see {manifest_path}:\n{result.stderr}")
        return result

    save()
    manifest["swift"] = run([compiler, "--version"]).stdout.strip()
    executable = output / "differential"
    run([compiler, *flags, str(baseline_path), str(candidate_path), str(driver_path), "-o", str(executable)])
    manifest["executable_sha256"] = digest(executable.read_bytes())
    report_path = output / "report.json"
    result = run([str(executable), str(corpus_path), str(report_path)])
    report = json.loads(report_path.read_text())
    if report["cases"] != len(corpus) or report["differences"] != 0:
        raise RuntimeError("Differential did not verify the complete corpus")
    manifest["report_sha256"] = digest(report_path.read_bytes())
    manifest["status"] = "complete"
    save()
    print(result.stdout, end="")


if __name__ == "__main__":
    main()
