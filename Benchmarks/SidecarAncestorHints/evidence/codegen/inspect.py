#!/usr/bin/env python3
"""Inspect existing optimized modules; this script does not compile or run them."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


SYMBOL = (
    "$s12IlliquidCore18MediaSidecarReaderC9recognize_6within17checkCancellation"
    "AA010RecognizedC4NameV20FoundationEssentials3URLV_AKyyKXEtKF"
)
PLAN = "AncestorPathPlan"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv):
    return subprocess.check_output(argv, text=True)


def inspect(research_root, label, run, variant):
    binary = research_root / run / "build" / variant / "module/libIlliquidCore.so"
    evidence = research_root / run / "evidence"
    assembly_command = [
        "objdump", "-d", "--no-show-raw-insn", "--disassemble=" + SYMBOL, str(binary)
    ]
    symbols_command = ["nm", "-S", str(binary)]
    assembly = command(assembly_command)
    symbols = command(symbols_command)
    instructions = [
        line for line in assembly.splitlines()
        if re.match(r"^\s*[0-9a-f]+:\s+\S", line)
    ]
    assert instructions, label
    symbol_line = next(line for line in symbols.splitlines() if line.endswith(" " + SYMBOL))
    frame = next(re.search(r"sub\s+\$(0x[0-9a-f]+),%rsp", line)
                 for line in instructions if re.search(r"sub\s+\$(0x[0-9a-f]+),%rsp", line))
    memcpy_sites = []
    allocation_sites = []
    for index, line in enumerate(instructions):
        if "call" in line and "memcpy@plt" in line:
            entry = {"call": line.strip(), "preceding": instructions[max(0, index - 7):index]}
            # All variants share a final value copy before applying the hints.
            if index == max(i for i, item in enumerate(instructions) if "memcpy@plt" in item):
                entry["following"] = instructions[index + 1:index + 36]
            memcpy_sites.append(entry)
        if "call" in line and "swift_allocObject@plt" in line:
            allocation_sites.append({
                "call": line.strip(),
                "preceding": instructions[max(0, index - 7):index],
            })
    source_receipt_path = evidence / (variant + "-sources.json")
    source_receipt = json.loads(source_receipt_path.read_text())
    binary_receipt = json.loads((evidence / "binaries.json").read_text())
    binary_hash = sha256(binary)
    assert binary_hash == binary_receipt[variant]["library"], (label, "binary hash mismatch")
    return {
        "binary": str(binary),
        "binary_sha256": binary_hash,
        "source_receipt": str(source_receipt_path),
        "source_receipt_sha256": sha256(source_receipt_path),
        "reader_source": source_receipt["production"]["MediaSidecarReader.swift"],
        "inspection_commands": [assembly_command, symbols_command],
        "recognize_symbol": symbol_line,
        "recognize_code_bytes": int(symbol_line.split()[1], 16),
        "static_instruction_count": len(instructions),
        "stack_frame_subtraction_bytes": int(frame.group(1), 16),
        "stack_frame_subtraction_hex": frame.group(1),
        "memcpy_call_site_count": len(memcpy_sites),
        "memcpy_call_sites": memcpy_sites,
        "plan_helper_call_sites": [
            line.strip() for line in instructions if "call" in line and PLAN in line
        ],
        "plan_symbols": [line for line in symbols.splitlines() if PLAN in line],
        "object_allocation_call_sites": allocation_sites,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--research-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "receipt.json")
    args = parser.parse_args()
    research_root = args.research_root.resolve()
    inputs = {
        "baseline": ("reference-tests", "baseline"),
        "candidate_a_value_plan": ("linux-full", "candidate"),
        "candidate_b_reference_plan": ("reference-tests", "candidate"),
    }
    receipt = {
        "scope": "Static inspection of existing Linux x86_64 release modules; no builds or timing runs.",
        "limitations": [
            "Instruction and call-site counts are static, not dynamic execution counts.",
            "Stack subtraction excludes saved registers and callees' frames.",
            "Code-generation changes do not establish the cause or size of a timing difference.",
            "The reference-plan allocation requests 184 bytes; allocator overhead is not measured.",
        ],
        "symbol": SYMBOL,
        "objdump_version": command(["objdump", "--version"]).splitlines()[0],
        "nm_version": command(["nm", "--version"]).splitlines()[0],
        "variants": {
            label: inspect(research_root, label, run, variant)
            for label, (run, variant) in inputs.items()
        },
    }
    earlier_baseline = research_root / "linux-full/build/baseline/module/libIlliquidCore.so"
    receipt["baseline_library_matches_candidate_a_run"] = (
        sha256(earlier_baseline) == receipt["variants"]["baseline"]["binary_sha256"]
    )
    baseline_assembly = command(receipt["variants"]["baseline"]["inspection_commands"][0])
    earlier_assembly = command([
        "objdump", "-d", "--no-show-raw-insn", "--disassemble=" + SYMBOL, str(earlier_baseline)
    ])
    instruction_lines = lambda text: [
        line for line in text.splitlines() if re.match(r"^\s*[0-9a-f]+:\s+\S", line)
    ]
    receipt["baseline_recognize_disassembly_matches_candidate_a_run"] = (
        instruction_lines(baseline_assembly) == instruction_lines(earlier_assembly)
    )
    earlier_sources = json.loads((research_root / "linux-full/evidence/baseline-sources.json").read_text())
    receipt["baseline_production_source_hashes_match_candidate_a_run"] = (
        earlier_sources["production"]
        == json.loads(Path(receipt["variants"]["baseline"]["source_receipt"]).read_text())["production"]
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    for label, variant in receipt["variants"].items():
        print(label, json.dumps({key: variant[key] for key in (
            "static_instruction_count", "stack_frame_subtraction_bytes",
            "memcpy_call_site_count", "binary_sha256"
        )}))
    print("receipt:", args.output)


if __name__ == "__main__":
    main()
