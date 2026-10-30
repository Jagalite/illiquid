#!/usr/bin/env python3
"""Check production staging boundaries and complete Swift Testing receipts."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("checkpoint_membership_runner", HERE / "run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SessionSourceBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (runner.ROOT / "Sources/IlliquidCore/Persistence/PlaybackSessionStore.swift").read_bytes()

    def test_current_production_record_and_protocol_are_copied_verbatim(self):
        result = runner.session_api(self.source)
        self.assertEqual(result, self.source.split(runner.SESSION_BOUNDARY)[0] + b"\n")
        self.assertIn(b"public struct PlaybackSessionRecord:", result)
        self.assertIn(b"public protocol PlaybackSessionStoring:", result)
        self.assertNotIn(b"public final class AtomicPlaybackSessionStore:", result)

    def test_missing_boundary_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source.replace(runner.SESSION_BOUNDARY, b"\n", 1))

    def test_duplicate_boundary_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source + runner.SESSION_BOUNDARY)

    def test_lost_storage_protocol_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source.replace(b"public protocol PlaybackSessionStoring:", b"protocol RemovedStoring:", 1))

    def test_moved_atomic_store_declaration_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.session_api(self.source.replace(b"public final class AtomicPlaybackSessionStore:", b"public final class RenamedStore:", 1))


class SwiftTestingReceiptTests(unittest.TestCase):
    # Distilled receipt lines from the retained local Swift 6.3.2 and hosted
    # Swift 6.4 logs. The latter runs Player and Core test modules separately.
    membership = '✔ Suite "Playback checkpoint records" passed after 0.007 seconds.\n'
    core = """✔ Suite "Folder playlist" passed after 0.001 seconds.
✔ Suite "Natural filename ordering parity" passed after 0.098 seconds.
✔ Suite "Playlist deduplication" passed after 0.027 seconds.
✔ Suite "Playlist mutation" passed after 0.001 seconds.
✔ Suite "Playlist order restoration" passed after 0.794 seconds.
✔ Suite "Playlist session record semantics" passed after 0.002 seconds.
"""
    combined = membership + core + '✔ Test run with 43 tests in 7 suites passed after 1.108 seconds.\n'
    split = (membership + '✔ Test run with 9 tests in 1 suite passed after 0.008 seconds.\n'
             + core + '✔ Test run with 34 tests in 6 suites passed after 0.926 seconds.\n')

    def receipt(self, text):
        return runner.swift_testing_receipt(text, required_suites=runner.COMPONENT_TEST_SUITES,
                                            expected_counts=runner.COMPONENT_TEST_COUNTS)

    def test_swift_63_combined_run_counts_all_selected_tests(self):
        result = self.receipt(self.combined.encode())
        self.assertEqual((result['test_count'], result['suite_count']), (43, 7))
        self.assertEqual(result['run_summaries'], [{'test_count': 43, 'suite_count': 7}])

    def test_swift_64_module_runs_are_aggregated(self):
        result = self.receipt(self.split)
        self.assertEqual((result['test_count'], result['suite_count']), (43, 7))
        self.assertEqual(result['run_summaries'], [
            {'test_count': 9, 'suite_count': 1}, {'test_count': 34, 'suite_count': 6}])
        self.assertIn('Playback checkpoint records', result['passed_suites'])

    def test_module_summary_order_does_not_change_totals(self):
        text = (self.core + '✔ Test run with 34 tests in 6 suites passed after 0.926 seconds.\n'
                + self.membership + '✔ Test run with 9 tests in 1 suite passed after 0.008 seconds.\n')
        result = self.receipt(text)
        self.assertEqual((result['test_count'], result['suite_count']), (43, 7))

    def test_missing_membership_success_is_rejected_even_with_matching_totals(self):
        with self.assertRaises(ValueError):
            self.receipt(self.combined.replace(self.membership, ''))

    def test_missing_membership_module_is_rejected(self):
        with self.assertRaises(ValueError):
            self.receipt(self.core + '✔ Test run with 34 tests in 6 suites passed after 0.926 seconds.\n')

    def test_missing_module_summary_is_rejected(self):
        with self.assertRaises(ValueError):
            self.receipt(self.split.replace('✔ Test run with 9 tests in 1 suite passed after 0.008 seconds.\n', ''))

    def test_zero_only_or_zero_test_suites_cannot_qualify(self):
        for text in ['✔ Test run with 0 tests passed after 0.001 seconds.\n',
                     self.membership + '✔ Test run with 0 tests in 1 suite passed after 0.001 seconds.\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.receipt(text)

    def test_empty_filtered_module_does_not_hide_successful_selected_modules(self):
        result = self.receipt(self.split + '✔ Test run with 0 tests passed after 0.001 seconds.\n')
        self.assertEqual((result['test_count'], result['suite_count']), (43, 7))
        self.assertEqual(result['run_summaries'][-1], {'test_count': 0, 'suite_count': 0})

    def test_malformed_or_failed_summary_is_not_silently_ignored(self):
        for replacement in ['34 tests in six suites passed', '34 tests in 6 suites failed',
                            '34 tests in 6 suites stopped']:
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.receipt(self.split.replace('34 tests in 6 suites passed', replacement))

    def test_duplicate_summaries_or_suite_successes_are_rejected(self):
        for text in [self.combined + '✔ Test run with 43 tests in 7 suites passed after 1.108 seconds.\n',
                     self.combined + self.membership]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.receipt(text)

    def test_frozen_test_count_prevents_silent_partial_execution(self):
        with self.assertRaises(ValueError):
            self.receipt(self.combined.replace('43 tests', '42 tests'))



class ReviewedSupportTests(unittest.TestCase):
    def test_exact_reviewed_support_and_mutation_controls(self):
        for path in runner.CORE_PATHS:
            current = (runner.ROOT / path).read_bytes()
            with self.subTest(path=path):
                runner.guard_support(path, current, b"historical bytes", True)
                with self.assertRaises(RuntimeError):
                    runner.guard_support(path, current + b"\n", current, True)
                with self.assertRaises(RuntimeError):
                    runner.guard_support(path, current, b"historical bytes", False)
                runner.guard_support(path, current, current, False)

if __name__ == "__main__":
    unittest.main()
