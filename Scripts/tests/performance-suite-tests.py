#!/usr/bin/env python3
import importlib.util
import unittest
from unittest.mock import patch
from pathlib import Path
spec = importlib.util.spec_from_file_location('suite', Path(__file__).parents[1] / 'profile-performance-suite.py')
suite = importlib.util.module_from_spec(spec); spec.loader.exec_module(suite)
spec = importlib.util.spec_from_file_location('lifecycle', Path(__file__).parents[1] / 'profile-lifecycle.py')
lifecycle = importlib.util.module_from_spec(spec); spec.loader.exec_module(lifecycle)

class RegressionGateTests(unittest.TestCase):
    def records(self):
        return [dict(app=label, case='hevc', metrics={'steady_cpu':10, 'seek_ms':200,
                     'hover_dropped':0, 'hover_corrupted':0})
                for label in ('baseline','candidate') for _ in range(3)]

    def test_matches_pass(self):
        self.assertTrue(suite.compare(self.records())['passed'])

    def test_cpu_regression_fails(self):
        rows=self.records()
        for r in rows[3:]: r['metrics']['steady_cpu']=13
        self.assertFalse(suite.compare(rows)['passed'])

    def test_single_corrupt_or_dropped_frame_fails(self):
        for metric in ('hover_dropped','hover_corrupted'):
            rows=self.records();rows[-1]['metrics'][metric]=1
            self.assertFalse(suite.compare(rows)['passed'])

    def test_corrupt_baseline_cannot_qualify_candidate(self):
        rows=self.records();rows[0]['metrics']['hover_corrupted']=1
        self.assertFalse(suite.compare(rows)['passed'])

    def test_incomplete_or_mismatched_cohort_rejected(self):
        for rows in ([],self.records()[:-1]):
            with self.assertRaises(ValueError):suite.compare(rows)
        rows=self.records();del rows[-1]['metrics']['seek_ms']
        with self.assertRaises(ValueError):suite.compare(rows)

    def test_nonfinite_and_negative_values_rejected(self):
        for value in (float('nan'),float('inf'),-1):
            rows=self.records();rows[-1]['metrics']['steady_cpu']=value
            with self.assertRaises(ValueError):suite.compare(rows)

    def test_failed_receipt_rejected(self):
        with self.assertRaises(ValueError):suite.metrics({'failure':'timeout'})

    def test_cannot_weaken_repeat_requirement(self):
        with self.assertRaises(ValueError):suite.compare(self.records(),1)

    def test_missing_or_offscreen_evidence_cannot_qualify(self):
        for samples in ([], [{'visible':False}]):
            with self.assertRaisesRegex(ValueError, 'visibility'):
                suite.metrics(dict(mode='output', run=dict(status='complete', visibility_samples=samples)))

    def test_visibility_records_other_space_and_accepts_small_aspect_window(self):
        run = lifecycle.Run.__new__(lifecycle.Run)
        run.result = {}; run.start = 0
        run.process = type('Process', (), {'pid':123})()
        row = dict(kCGWindowIsOnscreen=True, kCGWindowLayer=0,
                   kCGWindowBounds={'Width':700,'Height':393})
        with patch.object(lifecycle.resources, 'windows', return_value=[row]):
            run.require_visible_window('resize')
            self.assertTrue(run.result['visibility_samples'][-1]['visible'])
            row['kCGWindowIsOnscreen'] = None
            with self.assertRaisesRegex(RuntimeError, 'run is invalid'):
                run.require_visible_window('other-space')
            self.assertFalse(run.result['visibility_samples'][-1]['visible'])

if __name__=='__main__':unittest.main()
