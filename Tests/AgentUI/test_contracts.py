"""Scenario/inventory regressions using synthetic state; no native helper or UI.

Run directly with unittest discovery in this directory. Synthetic input effects
only test scenario assertions and receipt flow, never actual event delivery.
"""
from collections import Counter
import copy
import importlib.util
import json
from pathlib import Path
import re
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


def validate_inventory(inventory):
    """Validate inventory bookkeeping only; no native UI correctness claim."""
    required = {'id', 'area', 'actions', 'status', 'live_qualified', 'scenarios',
                'source_paths', 'requires', 'gap', 'evidence'}

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def strings(values, label, nonempty=False):
        require(isinstance(values, list), label + ' must be a list')
        require(not nonempty or bool(values), label + ' must not be empty')
        require(all(isinstance(v, str) and v.strip() for v in values),
                label + ' must contain nonempty strings')

    def source(path):
        require(isinstance(path, str) and path.strip(), 'empty source path')
        relative = Path(path)
        require(not relative.is_absolute() and '..' not in relative.parts,
                'source must be repository relative: ' + path)
        require((ROOT / relative).is_file(), 'missing source: ' + path)

    ids = set()
    for entry in inventory['entries']:
        require(required.issubset(entry), 'missing fields: ' + str(required - entry.keys()))
        identifier = entry['id']
        require(isinstance(identifier, str) and bool(re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', identifier)),
                'invalid entry id')
        require(identifier not in ids, 'duplicate id: ' + identifier)
        ids.add(identifier)
        require(entry['status'] in inventory['status_definitions'], 'unknown status: ' + identifier)
        require(type(entry['live_qualified']) is bool, 'qualification must be boolean: ' + identifier)
        for field in ('area', 'gap'):
            require(isinstance(entry[field], str) and entry[field].strip(), 'empty ' + field)
        for field in ('actions', 'source_paths', 'requires', 'scenarios'):
            strings(entry[field], identifier + '.' + field, field in ('actions', 'source_paths'))
        require(isinstance(entry['evidence'], list), 'evidence must be a list: ' + identifier)
        for path in entry['source_paths']:
            source(path)
        if 'routes' in entry:
            strings(entry['routes'], identifier + '.routes', True)
        for variant in entry.get('state_variants', []):
            require({'state', 'action', 'expected_outcomes'}.issubset(variant),
                    'incomplete state variant: ' + identifier)
            for field in ('state', 'action'):
                require(isinstance(variant[field], str) and variant[field].strip(),
                        'empty variant ' + field + ': ' + identifier)
            strings(variant['expected_outcomes'], identifier + '.expected_outcomes', True)
    for collection, key in (('existing_identifiers', 'identifier'),
                            ('diagnostic_targets', 'identifier'),
                            ('identifier_patterns', 'source_pattern')):
        records = inventory[collection]
        require(len({record[key] for record in records}) == len(records),
                'duplicate ' + collection)
        for record in records:
            for path in record.get('source_paths', [record.get('source_path')]):
                source(path)
    return ids


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
    def test_entry_schema_unique_ids_and_existing_source_paths(self):
        inventory = json.loads((HERE / 'coverage.json').read_text())
        ids = validate_inventory(inventory)
        audit = inventory['source_audit']
        self.assertEqual(audit['revision'], inventory['source_baseline'])
        self.assertRegex(audit['revision'], r'^[0-9a-f]{40}$')
        self.assertEqual(audit['family_count'], len(ids))
        self.assertEqual(audit['state_variant_count'],
                         sum(len(e.get('state_variants', [])) for e in inventory['entries']))
        audited = set(audit['consolidated_entry_ids'])
        self.assertTrue(audited.issubset(ids))
        for entry in inventory['entries']:
            self.assertFalse(entry['live_qualified'], entry['id'])
            self.assertNotEqual(entry['status'], 'automated', entry['id'])
            if entry['id'] in audited:
                self.assertTrue(entry['routes'], entry['id'])
                self.assertTrue(entry['requires'], entry['id'])
                self.assertTrue(entry['state_variants'], entry['id'])

    def test_inventory_contract_rejects_malformed_records(self):
        inventory = json.loads((HERE / 'coverage.json').read_text())
        for mutation in ('duplicate-id', 'missing-source', 'missing-field', 'empty-outcome'):
            with self.subTest(mutation=mutation):
                invalid = copy.deepcopy(inventory)
                if mutation == 'duplicate-id':
                    invalid['entries'].append(copy.deepcopy(invalid['entries'][0]))
                elif mutation == 'missing-source':
                    invalid['entries'][0]['source_paths'] = ['Sources/not-a-real-source.swift']
                elif mutation == 'missing-field':
                    del invalid['entries'][0]['gap']
                else:
                    invalid['entries'][0]['state_variants'] = [
                        {'state': 'synthetic', 'action': 'inspect', 'expected_outcomes': []}]
                with self.assertRaises(ValueError):
                    validate_inventory(invalid)

    def test_settings_destinations_and_content_inventory_match_source_anchors(self):
        inventory = json.loads((HERE / 'coverage.json').read_text())
        settings = (ROOT / 'Sources/IlliquidApp/UI/SettingsView.swift').read_text()
        destination_enum = settings.split('enum SettingsDestination:', 1)[1].split('var id:', 1)[0]
        destinations = re.findall(r'^    case (\w+)\s*$', destination_enum, re.MULTILINE)
        entries = [e for e in inventory['entries'] if 'settings_destination' in e]
        self.assertEqual(Counter(e['settings_destination'] for e in entries), Counter(destinations))
        # These strings are audit anchors, not assertions that a live page rendered.
        components = settings + ''.join((ROOT / ('Sources/IlliquidApp/UI/' + name)).read_text()
                                        for name in ('ThumbnailSettingsCard.swift',
                                                     'TrackSelectionSettings.swift', 'UpdateSettingsView.swift'))
        for entry in entries:
            self.assertTrue(entry['content_anchors'], entry['id'])
            self.assertTrue(entry['routes'], entry['id'])
            self.assertTrue(entry['state_variants'], entry['id'])
            for anchor in entry['content_anchors']:
                self.assertIn('"' + anchor + '"', components, entry['id'])

    def test_shortcut_definitions_and_native_accelerators_have_inventory_anchors(self):
        inventory = json.loads((HERE / 'coverage.json').read_text())
        entries = {e['id']: e for e in inventory['entries']}
        source = (ROOT / 'Sources/IlliquidApp/App/PlayerShortcutBindings.swift').read_text()
        definitions = [dict(id=i, title=t, default_key=k) for i, t, k in re.findall(
            r'\.init\(id: "([^"]+)", title: "([^"]+)", action: .*?, defaultKey: "([^"]+)"\)', source)]
        self.assertEqual(len(definitions), 25)
        self.assertEqual(entries['help-shortcuts']['editable_actions'], definitions)
        self.assertEqual(len({e['id'] for e in definitions}), len(definitions))
        commands = (ROOT / 'Sources/IlliquidApp/App/PlayerCommands.swift').read_text()
        native = entries['native-menu-shortcuts']
        self.assertEqual(native['source_anchors'], re.findall(
            r'\.keyboardShortcut\((?!voiceOverEnabled)[^\n]+\)', commands))
        self.assertTrue(native['routes'])
        self.assertTrue(native['state_variants'])

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
