#!/usr/bin/env python3
"""Exercise source preparation without invoking Swift."""
import importlib.util
from pathlib import Path
import subprocess
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("storage_runner", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PreparationTests(unittest.TestCase):
    def test_tests_only_uses_current_support_and_historical_focal_provenance(self):
        def current(path):
            return (runner.ROOT / path).read_bytes()

        def historical(path):
            if path != runner.FOCAL_REPOSITORY_PATH:
                raise AssertionError("tests-only loaded historical support")
            return subprocess.check_output(["git", "-C", str(runner.ROOT), "show",
                                            f"{runner.BASELINE}:{path}"])

        baseline, records, candidate, candidate_records = runner.comparison_sources(
            historical, current, True)
        self.assertEqual(baseline[runner.FOCAL], historical(runner.FOCAL_REPOSITORY_PATH))
        self.assertEqual(records[runner.FOCAL]["source_sha256"], runner.sha(historical(runner.FOCAL_REPOSITORY_PATH)))
        for path in baseline.keys() - {runner.FOCAL}:
            self.assertEqual(baseline[path], candidate[path])
            self.assertEqual(records[path], candidate_records[path])

    def test_performance_rejects_support_drift(self):
        def current(path):
            return (runner.ROOT / path).read_bytes()

        def historical(path):
            data = current(path)
            if path == "Sources/IlliquidCore/MediaLibrary/PlexMatchHints.swift":
                return data + b"\n// historical drift\n"
            return data

        with self.assertRaisesRegex(ValueError, "Unrelated support source changed:.*PlexMatchHints"):
            runner.comparison_sources(historical, current, False)


if __name__ == "__main__":
    unittest.main()
