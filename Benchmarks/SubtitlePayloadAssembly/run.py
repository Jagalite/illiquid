#!/usr/bin/env python3
"""Measure payload assembly against current-main parsing and escaping.

Reuse the existing whole-converter runner and its byte-parity, source-hash,
separate-module, calibration, and paired-process checks. Only the fixture driver
and frozen baseline directory are selected here; historical experiments retain
their original defaults.
"""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNNER = HERE.parent / "ExternalSubtitleConversion" / "run.py"


def main() -> None:
    spec = spec_from_file_location("external_subtitle_conversion_benchmark", RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load the shared benchmark runner: {RUNNER}")
    runner = module_from_spec(spec)
    spec.loader.exec_module(runner)
    runner.HERE = HERE
    runner.main()


if __name__ == "__main__":
    main()
