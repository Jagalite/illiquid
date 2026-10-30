#!/usr/bin/env python3
"""Noncompiling controls for explicit integration comparison selection and CLI gates."""
from pathlib import Path
import subprocess
import sys
import unittest
import regression

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


class RegressionControls(unittest.TestCase):
    def setUp(self):
        self.focal = "MediaNameRecognition.swift"
        self.original = {name: (HERE / "baseline" / name).read_bytes()
                         for name in (self.focal, "MediaMetadataHints.swift")}
        self.candidate = {name: (ROOT / "Sources/IlliquidCore/MediaLibrary" / name).read_bytes()
                          for name in self.original}

    def test_frozen_focal_and_identical_current_support(self):
        selected, receipt = regression.select_sources(self.original, self.candidate, self.focal)
        self.assertEqual(selected[self.focal], self.original[self.focal])
        self.assertNotEqual(selected[self.focal], self.candidate[self.focal])
        self.assertEqual(selected["MediaMetadataHints.swift"], self.candidate["MediaMetadataHints.swift"])
        self.assertFalse(receipt["timing_allowed"])

    def test_reject_baseline_replacement(self):
        changed = dict(self.original, **{self.focal: self.candidate[self.focal]})
        with self.assertRaisesRegex(ValueError, "Frozen focal"):
            regression.select_sources(changed, self.candidate, self.focal)

    def test_reject_noop_focal(self):
        changed = dict(self.candidate, **{self.focal: self.original[self.focal]})
        with self.assertRaisesRegex(ValueError, "no-op"):
            regression.select_sources(self.original, changed, self.focal)

    def test_reject_unreviewed_focal_change(self):
        changed = dict(self.candidate, **{self.focal: self.candidate[self.focal] + b"\n// drift\n"})
        with self.assertRaisesRegex(ValueError, "exact reviewed pin"):
            regression.select_sources(self.original, changed, self.focal)

    def test_reject_changed_allowlisted_support(self):
        changed = dict(self.candidate, **{"MediaMetadataHints.swift": b"unreviewed"})
        with self.assertRaisesRegex(ValueError, "Unreviewed unrelated"):
            regression.select_sources(self.original, changed, self.focal)

    def test_reject_unlisted_support_change(self):
        original = dict(self.original, other=b"original")
        changed = dict(self.candidate, other=b"changed")
        with self.assertRaisesRegex(ValueError, "Unreviewed unrelated"):
            regression.select_sources(original, changed, self.focal)

    def test_reject_inventory_change(self):
        with self.assertRaisesRegex(ValueError, "inventories"):
            regression.select_sources(self.original, dict(self.candidate, extra=b"extra"), self.focal)

    def test_mode_constraints(self):
        regression.validate_mode(False, False)
        regression.validate_mode(True, True)
        for correctness, skipped, summary in [(False, False, False), (True, True, False), (True, False, True)]:
            with self.assertRaises(ValueError):
                regression.validate_mode(True, correctness, skip_tests=skipped, summarize_only=summary)

    def test_actual_runners_reject_timing_before_compilation(self):
        for script in [HERE / "run.py", ROOT / "Benchmarks/MediaDisplayNameProjection/run.py"]:
            result = subprocess.run([sys.executable, str(script), "--current-source-regression",
                                     "--output", "/unused-regression-control-output"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("timing, skipped tests and summary replay are forbidden", result.stderr)


if __name__ == "__main__":
    unittest.main()
