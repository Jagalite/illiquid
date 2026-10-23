"""Scenario/inventory regressions using synthetic state; no native helper or UI.

Run directly with unittest discovery in this directory. Synthetic input effects
only test scenario assertions and receipt flow, never actual event delivery.
"""
from collections import Counter
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SPEC = importlib.util.spec_from_file_location(
    'agent_ui_contract_runner', ROOT / 'Scripts/agent-ui/agent_ui.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def read_scenario(name):
    return json.loads((HERE / 'Scenarios' / (name + '.json')).read_text())


class ScenarioContracts(unittest.TestCase):
    def test_all_examples_validate_against_runner_schema(self):
        for path in sorted((HERE / 'Scenarios').glob('*.json')):
            with self.subTest(scenario=path.name):
                runner.validate_scenario(json.loads(path.read_text()))

    def replay_playback(self, *, ignore_input=False, malformed_state=False):
        scenario = read_scenario('playback-shortcuts')
        # Keep negative synthetic checks quick; never alter the retained fixture.
        for step in scenario['steps']:
            if step['command'] == 'wait':
                step['args'].update(timeout=.01, interval=.001)
        with tempfile.TemporaryDirectory() as temporary:
            run = runner.Runner(temporary, adapter=object())
            (run.directory / 'artifacts').mkdir()
            run.manifest = {'schema_version': 1, 'run_id': 'synthetic-scenario'}
            playback = {'duration_seconds': 12, 'loading': False,
                        'pause_desired': True, 'position_seconds': 0}
            delivered = []
            original_dispatch = run.dispatch

            def dispatch(command, args):
                if command == 'hook':
                    action = args['action']
                    if action == 'pause':
                        playback['pause_desired'] = True
                    elif action == 'seek-exact':
                        playback['position_seconds'] = args['targetSeconds']
                    elif action == 'capabilities':
                        return {'state': {'data': {'commands': ['agent-state']}}}
                    elif action != 'agent-state':
                        self.fail('unexpected hook ' + action)
                    state = {'playback': copy.deepcopy(playback), 'window': {'key': True}}
                    return {'state': state if malformed_state else {'data': state}}
                if command == 'act':
                    self.assertEqual(args['mode'], 'input')
                    delivered.append(args['key'])
                    if not ignore_input:
                        if args['key'] == 'space':
                            playback['pause_desired'] = not playback['pause_desired']
                        elif args['key'] in ('left', 'right'):
                            playback['position_seconds'] += 5 if args['key'] == 'right' else -5
                        else:
                            self.fail('unexpected input ' + args['key'])
                    return {'mode': 'input', 'synthetic': True}
                return original_dispatch(command, args)

            with patch.object(run, 'dispatch', side_effect=dispatch):
                result = run.execute('run', {'scenario': scenario})
            assertions = json.loads((run.directory / 'assertions.json').read_text())
            return result, assertions, delivered

    def test_playback_example_preserves_wait_observation_for_seek_bounds(self):
        result, assertions, delivered = self.replay_playback()
        self.assertEqual(result['status'], 'ok', result)
        self.assertEqual(len(assertions['steps']), 19)
        self.assertEqual(delivered, ['space', 'space', 'right', 'left'])
        self.assertEqual(assertions['required_metrics'], [])

    def test_playback_example_cannot_pass_without_key_effects(self):
        result, assertions, delivered = self.replay_playback(ignore_input=True)
        self.assertEqual(result['status'], 'timed-out', result)
        self.assertEqual(assertions['status'], 'timed-out')
        self.assertEqual(delivered, ['space'])

    def test_playback_example_rejects_incorrect_hook_envelope_paths(self):
        result, _, delivered = self.replay_playback(malformed_state=True)
        self.assertEqual(result['status'], 'timed-out', result)
        self.assertEqual(delivered, [])

    def test_pending_grip_probe_fails_before_its_steps(self):
        scenario = read_scenario('timeline-grip-pending')
        self.assertIn('timeline-grip-global-input', scenario['requires'])
        with tempfile.TemporaryDirectory() as temporary:
            run = runner.Runner(temporary, adapter=object())
            (run.directory / 'artifacts').mkdir()
            run.manifest = {'schema_version': 1, 'run_id': 'synthetic-pending'}
            original_dispatch = run.dispatch
            commands = []

            def dispatch(command, args):
                if command == 'hook':
                    commands.append(args['action'])
                    return {'commands': ['capabilities', 'agent-state']}
                return original_dispatch(command, args)

            with patch.object(run, 'dispatch', side_effect=dispatch):
                result = run.execute('run', {'scenario': scenario})
            self.assertEqual(result['status'], 'unsupported', result)
            self.assertIn('timeline-grip-global-input', result['data']['missing'])
            self.assertEqual(commands, ['capabilities'])


class InventoryContracts(unittest.TestCase):
    def test_counts_references_and_historical_evidence_are_consistent(self):
        inventory = json.loads((HERE / 'coverage.json').read_text())
        self.assertEqual(Counter(e['status'] for e in inventory['entries']),
                         Counter(inventory['counts']))
        examples = inventory['scenario_examples']
        self.assertEqual(len({e['path'] for e in examples}), len(examples))
        paths = {e['path'] for e in examples}
        self.assertEqual(paths, {str(p.relative_to(HERE)) for p in (HERE / 'Scenarios').glob('*.json')})
        for entry in inventory['entries']:
            self.assertTrue(set(entry['scenarios']).issubset(paths), entry['id'])
        historical = []
        for example in examples:
            scenario = json.loads((HERE / example['path']).read_text())
            self.assertEqual(example['setup'], scenario['description'], example['path'])
            if 'historical_smoke' in example:
                receipt = example['historical_smoke']
                self.assertEqual(receipt['status'], 'passed')
                self.assertEqual(receipt['steps'], len(scenario['steps']))
                self.assertTrue(receipt['receipt_directory'])
                self.assertTrue(receipt['scope'])
                historical.append(example['path'])
        self.assertEqual(inventory['example_counts'], {
            'runnable_after_prerequisites': sum(e['state'] == 'runnable-after-prerequisites' for e in examples),
            'pending_capability_gated': sum(e['state'] == 'pending-capability-gated' for e in examples),
            'live_qualified': sum(e['live_qualified'] for e in examples),
            'historical_smoke_passed': len(historical),
        })
        self.assertEqual(set(historical), {'Scenarios/inspection.json', 'Scenarios/playback-shortcuts.json'})


if __name__ == '__main__':
    unittest.main()
