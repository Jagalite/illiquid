"""Fast staging/qualification controls; does not compile or run Swift."""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("nfo_runner", Path(__file__).with_name("run.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="nfo-harness-test-", dir=ROOT / ".build")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)

    def staged(self):
        return RUNNER.stage_sources(ROOT, self.work, historical=False)

    def reports(self):
        report = {
            "schemaVersion": 1, "mode": "differential", "caseCount": 136,
            "cases": [
                {"case": f"case-{index}", "inputBytes": index, "result": {
                    "content": "movie", "title": "e\u0301", "year": None,
                    "season": None, "episode": None, "lastEpisode": None,
                    "episodeTitle": None, "catalogIDs": ["imdb:1", "tmdb:2"],
                    "sources": ["nfo"],
                }} for index in range(136)
            ],
        }
        return {"baseline": report, "candidate": copy.deepcopy(report)}

    def test_current_dependencies_and_root_regressions_are_preserved(self):
        roots = self.staged()
        receipt = RUNNER.verify_isolation(roots)
        self.assertEqual(receipt["changed_sources"], [RUNNER.PARSER])
        self.assertEqual(receipt["expected_parser_blobs"], RUNNER.CURRENT_PARSER_BLOBS)
        for name in RUNNER.SOURCES:
            path = Path("Sources/IlliquidCore") / name
            self.assertEqual((roots["candidate"] / path).read_bytes(), (ROOT / path).read_bytes())
            if name != RUNNER.PARSER:
                self.assertEqual((roots["baseline"] / path).read_bytes(), (ROOT / path).read_bytes())
        for name in RUNNER.CURRENT_TESTS:
            path = Path("Tests/IlliquidCoreTests") / name
            self.assertEqual((roots["candidate"] / path).read_bytes(), (ROOT / path).read_bytes())
        reader = Path("Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift")
        self.assertIn(b"relativePath", (roots["baseline"] / reader).read_bytes())

    def test_old_sidecar_dependency_is_rejected_before_building(self):
        real_stage = RUNNER.stage_sources
        real_run = RUNNER.run

        def bad_stage(root, work, historical):
            roots = real_stage(root, work, historical)
            path = Path("Sources/IlliquidCore/MediaLibrary/MediaSidecarReader.swift")
            (roots["baseline"] / path).write_bytes(RUNNER.git_bytes(ROOT, RUNNER.BASELINE, path))
            return roots

        def no_builds(command, log=None):
            if command == ["swiftc", "--version"]:
                return "mock Swift version for staging negative control"
            self.assertEqual(command[0], "git", "Isolation failure must precede every build")
            return real_run(command, log)

        with patch("sys.argv", ["run.py", "--output", str(self.work / "bad-staging")]), \
                patch.object(RUNNER, "stage_sources", side_effect=bad_stage), \
                patch.object(RUNNER, "run", side_effect=no_builds), \
                self.assertRaisesRegex(RuntimeError, "Source isolation failed.*MediaSidecarReader"):
            RUNNER.main()

    def test_unreviewed_parser_and_no_op_comparisons_are_rejected(self):
        roots = self.staged()
        path = Path("Sources/IlliquidCore") / RUNNER.PARSER
        candidate = roots["candidate"] / path
        candidate.write_bytes(candidate.read_bytes() + b"\n// unexpected change\n")
        with self.assertRaisesRegex(RuntimeError, "Unexpected candidate parser blob"):
            RUNNER.verify_isolation(roots)
        candidate.write_bytes((roots["baseline"] / path).read_bytes())
        with self.assertRaisesRegex(RuntimeError, "Source isolation failed"):
            RUNNER.verify_isolation(roots)

    def test_historical_inputs_match_archived_manifest_without_timing(self):
        roots = RUNNER.stage_sources(ROOT, self.work, historical=True)
        receipt = RUNNER.verify_isolation(roots, historical=True)
        archived = json.loads((ROOT / "Benchmarks/NFOTextLimits/evidence/long-ordinary-controls/manifest.json").read_text())
        self.assertEqual(receipt["source_blobs"], archived["source_blobs"])
        self.assertEqual(RUNNER.CASE_ITERATIONS, archived["iterations"])
        for name, expected in archived["test_blobs"].items():
            self.assertEqual(RUNNER.blob((roots["candidate"] / "Tests/IlliquidCoreTests" / name).read_bytes()), expected)
        self.assertEqual(RUNNER.blob((roots["candidate"] / "Benchmarks/NFOTextLimits/Driver.swift").read_bytes()), archived["driver_blob"])
        self.assertEqual(receipt["expected_parser_blobs"], RUNNER.PARSER_BLOBS)
        self.assertEqual(
            {path.name for path in (roots["candidate"] / "Tests/IlliquidCoreTests").iterdir()},
            set(archived["test_blobs"]),
        )

    def test_reviewed_current_parser_cannot_replace_historical_candidate(self):
        roots = RUNNER.stage_sources(ROOT, self.work, historical=True)
        path = Path("Sources/IlliquidCore") / RUNNER.PARSER
        (roots["candidate"] / path).write_bytes((ROOT / path).read_bytes())
        with self.assertRaisesRegex(RuntimeError, "Unexpected candidate parser blob"):
            RUNNER.verify_isolation(roots, historical=True)

    def test_historical_candidate_cannot_replace_current_parser(self):
        roots = self.staged()
        path = Path("Sources/IlliquidCore") / RUNNER.PARSER
        (roots["candidate"] / path).write_bytes(
            RUNNER.git_bytes(ROOT, RUNNER.HISTORICAL_CANDIDATE, path))
        with self.assertRaisesRegex(RuntimeError, "Unexpected candidate parser blob"):
            RUNNER.verify_isolation(roots)

    def test_frozen_baseline_rejects_drift_in_both_modes(self):
        for historical in (False, True):
            with self.subTest(historical=historical):
                roots = RUNNER.stage_sources(ROOT, self.work, historical=historical)
                path = roots["baseline"] / "Sources/IlliquidCore" / RUNNER.PARSER
                path.write_bytes(path.read_bytes() + b"\n// unexpected oracle change\n")
                with self.assertRaisesRegex(RuntimeError, "Unexpected baseline parser blob"):
                    RUNNER.verify_isolation(roots, historical=historical)

    def test_all_complete_outputs_match(self):
        reports = self.reports()
        self.assertEqual(RUNNER.compare_differentials(reports, self.work), reports["candidate"])

    def test_differential_does_not_normalize_text_or_collection_order(self):
        for field, value in [("title", "\u00e9"), ("catalogIDs", ["tmdb:2", "imdb:1"])]:
            with self.subTest(field=field):
                reports = self.reports()
                reports["candidate"]["cases"][0]["result"][field] = value
                with self.assertRaisesRegex(RuntimeError, "output mismatch"):
                    RUNNER.compare_differentials(reports, self.work)
                self.assertTrue((self.work / "differential-mismatch.json").is_file())

    def test_equal_but_incomplete_corpora_are_rejected(self):
        for defect in ("truncated", "duplicate", "omitted-null"):
            with self.subTest(defect=defect):
                reports = self.reports()
                for report in reports.values():
                    if defect == "truncated":
                        report["cases"].pop()
                        report["caseCount"] -= 1
                    elif defect == "duplicate":
                        report["cases"][-1] = report["cases"][0]
                    else:
                        del report["cases"][0]["result"]["year"]
                with self.assertRaises(RuntimeError):
                    RUNNER.compare_differentials(reports, self.work)

    def test_default_qualification_cannot_invoke_timing(self):
        output = self.work / "qualification"
        real_run = RUNNER.run

        def fake_run(command, log=None):
            if command[0] == "git":
                return real_run(command, log)
            if command == ["swiftc", "--version"]:
                return "mock Swift version for orchestration test"
            if command[0] == "swiftc":
                return ""
            self.assertEqual(command[1:], ["differential"])
            return json.dumps(self.reports()["baseline"])

        results = {configuration: {"test_count": 1} for configuration in ("debug", "release")}
        with patch("sys.argv", ["run.py", "--output", str(output)]), \
                patch.object(RUNNER, "run", side_effect=fake_run), \
                patch.object(RUNNER, "swift_tests", return_value=results) as tests:
            RUNNER.main()
        self.assertEqual(tests.call_count, 2)
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertTrue(manifest["completed"])
        self.assertEqual(manifest["protocol_revision"], "current-regression-2-declaration-preflight")
        self.assertEqual(manifest["expected_parser_blobs"], RUNNER.CURRENT_PARSER_BLOBS)
        self.assertEqual(set(manifest["test_blobs"]), set(RUNNER.CURRENT_TESTS))
        self.assertEqual({call.kwargs["historical"] for call in tests.call_args_list}, {False})
        self.assertEqual(manifest["differential_case_count"], 136)
        self.assertIsNone(manifest["rounds"])
        self.assertFalse((output / "measurements.jsonl").exists())

    def test_qualification_rejects_skipped_tests_and_timing_options(self):
        for option in (["--skip-tests"], ["--rounds", "2"], ["--jobs", "3"]):
            with self.subTest(option=option), \
                    patch("sys.argv", ["run.py", "--output", str(self.work / "invalid"), *option]), \
                    patch.object(RUNNER, "run") as run, \
                    contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as error:
                RUNNER.main()
            self.assertEqual(error.exception.code, 2)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
