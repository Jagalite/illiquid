"""Fail-closed source rewriting and correctness/timing separation (no Swift execution)."""
import argparse
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run as harness


class HarnessTests(unittest.TestCase):
    def setUp(self):
        local = harness.HERE / ".build"
        local.mkdir(exist_ok=True)
        self.work = tempfile.TemporaryDirectory(dir=local)
        self.addCleanup(self.work.cleanup)
        self.output = Path(self.work.name)

    def test_original_ordered_corpus_generator_is_pinned(self):
        driver = (harness.HERE / "Driver.swift").read_bytes()
        block = driver[driver.index(b"private let scenarios ="):driver.index(b"\nprivate func emit(")]
        self.assertEqual(hashlib.sha256(block).hexdigest(), harness.CORPUS_GENERATOR_SHA256)

    def test_adapter_rejects_missing_or_ambiguous_expression(self):
        for source in [b"no path expression", b"path.deletingLastPathComponent\n" * 2,
                       b"path.deletingLastPathComponent + other.deletingLastPathComponent"]:
            with self.subTest(source=source), self.assertRaisesRegex(RuntimeError, "exactly one"):
                harness.transform_source(source, "", True)

    def test_corpus_counts_alone_cannot_qualify_changed_inputs(self):
        paths = ["", ".mkv"] + ["directory/"] * 27 + ["file.mkv"] * (16300 - 29)
        with patch.object(harness, "run", return_value=json.dumps({"paths": paths})), \
             self.assertRaisesRegex(RuntimeError, "ordered corpus hash"):
            harness.record_corpus(Path("unused"), self.output)

    def test_generated_sources_change_only_the_reviewed_expression_and_names(self):
        for source in [harness.SOURCE, harness.HERE / "baseline/MediaNameRecognition.swift",
                       harness.HERE / "folder-reuse/MediaNameRecognition.swift"]:
            original = source.read_bytes()
            for prefix in ["", "Baseline", "Adapted", "AdaptedBaseline"]:
                with self.subTest(source=source, prefix=prefix):
                    adapted, counts = harness.transform_source(original, prefix, True)
                    renamed, _ = harness.transform_source(original, prefix, False)
                    self.assertEqual(adapted.replace(b"benchmarkParentPath(path)", b"path.deletingLastPathComponent"), renamed)
                    self.assertEqual(counts["parent_path_replacements"], 1)
                    if not prefix:
                        self.assertEqual(renamed, original)
                    self.assertEqual(source.read_bytes(), original)

    def test_linux_timing_compiles_original_sources_without_adapter(self):
        args = argparse.Namespace(output=self.output)
        metadata = {"swiftc": "swiftc", "reference_source": "Benchmarks/EpisodeNameRecognition/baseline/MediaNameRecognition.swift"}

        def fake_compile(command, output, label):
            Path(command[-1]).write_bytes(b"test executable")
            return ""

        with patch.object(harness.platform, "system", return_value="Linux"), patch.object(harness, "run", side_effect=fake_compile):
            harness.compile_driver(args, metadata, self.output, "adapted-differential")
            harness.compile_driver(args, metadata, self.output, "timing")
        adapted, timing = metadata["compilations"]
        self.assertEqual(sum(t["parent_path_replacements"] for t in adapted["source_transformations"]), 2)
        self.assertEqual(timing["source_transformations"][0]["parent_path_replacements"], 0)
        self.assertIn(str(harness.SOURCE), timing["command"])
        self.assertNotIn("-D", timing["command"])
        self.assertFalse(any("FoundationBoundary.swift" in arg for arg in timing["command"]))
        generated = Path(timing["source_transformations"][0]["generated_source"]).read_bytes()
        original = (harness.ROOT / metadata["reference_source"]).read_bytes()
        expected, _ = harness.transform_source(original, "Baseline", False)
        self.assertEqual(generated, expected)
        self.assertFalse(adapted["timing_allowed"])
        self.assertTrue(timing["timing_allowed"])

    def test_linux_correctness_precedes_separate_timing_compile(self):
        args = argparse.Namespace(output=self.output, command="benchmark", scenarios=["movie-controls"],
                                  repeats=1, iterations=1, rounds=1)
        events = []

        def compile_binary(args, metadata, build, role):
            events.append(role)
            return build / role

        def execute(command, output, label):
            events.append(label)
            if label == "differential":
                self.assertIn("adapted-differential", command[0])
                return json.dumps({"ok": True, "cases": 16300})
            self.assertTrue(command[0].endswith("/timing"))
            return json.dumps({"checksum": "1", "scenario": "movie-controls", "implementation": command[2],
                               "nanoseconds_per_operation": [1]})

        with patch.object(harness.platform, "system", return_value="Linux"), \
             patch.object(harness, "compile_driver", side_effect=compile_binary), \
             patch.object(harness, "record_corpus", return_value={}), \
             patch.object(harness, "run", side_effect=execute), patch("builtins.print"):
            harness.benchmark(args, {})
        self.assertEqual(events[:3], ["adapted-differential", "differential", "timing"])

    def test_failed_full_correctness_prevents_timing_compile(self):
        args = argparse.Namespace(output=self.output, command="benchmark")
        for differential in [{"ok": False, "cases": 16300}, {"ok": True, "cases": 16299}]:
            with self.subTest(differential=differential), \
                 patch.object(harness.platform, "system", return_value="Linux"), \
                 patch.object(harness, "compile_driver", return_value=Path("adapted")) as compile_binary, \
                 patch.object(harness, "record_corpus", return_value={}), \
                 patch.object(harness, "run", return_value=json.dumps(differential)), \
                 self.assertRaisesRegex(RuntimeError, "Full correctness"):
                harness.benchmark(args, {})
            self.assertEqual(compile_binary.call_count, 1)


if __name__ == "__main__":
    unittest.main()
