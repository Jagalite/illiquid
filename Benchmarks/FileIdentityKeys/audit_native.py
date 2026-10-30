#!/usr/bin/env python3
"""Independent verification of the completed FileIdentityKeys native artifact."""
import argparse
import hashlib
import re
import json
import math
import random
import statistics
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path, help='Extracted native benchmark directory containing manifest.json')
parser.add_argument('--repo', type=Path, default=HERE.parents[1])
parser.add_argument('--source-index', type=Path, default=HERE / 'evidence/native-source-index.json')
parser.add_argument('--tests-root', type=Path)
parser.add_argument('--expected-pairs', type=int, default=12)
parser.add_argument('--expected-target-ms', type=float, default=250)
parser.add_argument('--report-name', default='independent-native-audit.json')
args=parser.parse_args()
OUT=args.directory.resolve()
REPO=args.repo.resolve()
SOURCE_INDEX=json.loads(args.source_index.read_text())
TESTS_ROOT=(args.tests_root or OUT.parent).resolve()
BINARY_VERIFICATION={'verified': [], 'not_uploaded': []}
FRONTEND_VERIFICATION={'verified': [], 'not_available_on_audit_host': []}
CMO_PLANS={}
MAX_ROUNDS=20_000_000
CALIBRATION_CHECKS={}



def read(name):
    return json.loads((OUT / name).read_text())


def hashes(data):
    return {
        'sha256': hashlib.sha256(data).hexdigest(),
        'git_blob_sha1': hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest(),
    }


def equal_number(left, right):
    assert math.isclose(left, right, rel_tol=1e-12, abs_tol=1e-8), (left, right)


manifest = read('manifest.json')
summary = read('summary.json')
commands = read('commands.json')
receipts = read('receipts.json')
calibrations = read('calibrations.json')
schedule = read('schedule.json')
differential = read('differential.json')
rows = [json.loads(line) for line in (OUT / 'observations.jsonl').read_text().splitlines()]
assert manifest['status'] == 'complete'
assert summary['complete'] is True
assert summary['baseline_revision'] == manifest['baseline']['revision'] == 'ea2ff568237e2667f7b1aeee67b11a44ebe95b72'
PAIR_COUNT=summary['pairs']
assert PAIR_COUNT == args.expected_pairs
assert summary['baseline_target_cpu_ms'] == args.expected_target_ms
assert manifest['checkout']['head'] == SOURCE_INDEX['commit']
assert manifest['checkout']['relevant_status'] == ''
assert '-apple-macosx' in manifest['environment']['swift_target_info']['target']['triple']
assert differential == summary['differential']
assert differential['mismatches'] == 0 and differential['examples'] == []
assert differential['cases'] > differential['rejected'] >= 0
assert differential['cases'] > 30_000 and differential['nativeReferenceCases'] == 8
assert len(receipts) == 17 and len(rows) == 2 * PAIR_COUNT * len(receipts)
assert not (OUT / 'failure.json').exists()

command_by_label = {}
for expected_id, command in enumerate(commands):
    assert command['id'] == expected_id and command['returncode'] == 0
    assert command['completed_utc'] >= command['started_utc']
    assert (OUT / command['stdout']).exists() and (OUT / command['stderr']).exists()
    assert command['label'] not in command_by_label
    command_by_label[command['label']] = command

for variant in ['baseline', 'candidate']:
    compile_command = command_by_label['build-' + variant]['arguments']
    assert '-O' in compile_command and '-whole-module-optimization' in compile_command
    assert '-swift-version' in compile_command and '-emit-object' in compile_command
    assert '-cross-module-optimization' not in compile_command and '-Ounchecked' not in compile_command
    for name, original in manifest['baseline']['files'].items():
        snapshot = (OUT / 'sources' / variant / name).read_bytes()
        assert hashes(snapshot) == manifest['source_hashes'][variant][name]
        if variant == 'baseline':
            frozen = (REPO / 'Benchmarks/FileIdentityKeys/baseline' / name).read_bytes()
            assert snapshot == frozen
            baseline_git = subprocess.check_output([
                'git', '-C', str(REPO), 'show', manifest['baseline']['revision'] + ':' + original['source'],
            ])
            assert snapshot == baseline_git
            assert hashes(snapshot) == {key: original[key] for key in ['sha256', 'git_blob_sha1']}
        else:
            assert hashes(snapshot)['git_blob_sha1'] == SOURCE_INDEX['files'][original['source']]['sha']
            if name != 'NormalizedFileURL.swift':
                assert snapshot == (OUT / 'sources/baseline' / name).read_bytes()

for name in ['Driver.swift', 'Differential.swift', 'run.py']:
    snapshot = (OUT / 'sources' / name).read_bytes()
    assert hashes(snapshot) == manifest['source_hashes'][name]
    assert hashes(snapshot)['git_blob_sha1'] == SOURCE_INDEX['files']['Benchmarks/FileIdentityKeys/' + name]['sha']

for name, expected_sha in manifest['binary_hashes'].items():
    assert re.fullmatch(r'[0-9a-f]{64}', expected_sha)
    binary=OUT / 'build' / name
    if binary.is_file():
        assert hashlib.sha256(binary.read_bytes()).hexdigest() == expected_sha
        BINARY_VERIFICATION['verified'].append(name)
    else:
        BINARY_VERIFICATION['not_uploaded'].append({'name': name, 'recorded_sha256': expected_sha})
for frontend in manifest['environment']['actual_swift_frontends']:
    assert re.fullmatch(r'[0-9a-f]{64}', frontend['sha256'])
    path=Path(frontend['path'])
    if path.is_file():
        digest=hashlib.sha256()
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        assert digest.hexdigest() == frontend['sha256']
        FRONTEND_VERIFICATION['verified'].append(frontend)
    else:
        FRONTEND_VERIFICATION['not_available_on_audit_host'].append(frontend)
for variant in ['baseline', 'candidate']:
    command=command_by_label[variant + '-compiler-plan']
    plan='\n'.join((OUT / command[stream]).read_text() for stream in ['stdout', 'stderr'])
    assert 'swift-frontend' in plan and '-O' in plan
    CMO_PLANS[variant]={'default_cmo_flag_observed': '-enable-default-cmo' in plan,
                        'explicit_cmo_flag_observed': '-cross-module-optimization' in plan,
                        'logs': [command['stdout'], command['stderr']]}

driver_command = command_by_label['build-driver']['arguments']
assert '-O' in driver_command and '-cross-module-optimization' not in driver_command
assert sum(value.endswith('URLBaseline.o') for value in driver_command) == 1
assert sum(value.endswith('URLCandidate.o') for value in driver_command) == 1

expected_indices = {
    'playlist-empty': None,
    'playlist-single-hit': 0,
    'playlist-small-last': 7,
    'playlist-first-1000': 0,
    'playlist-middle-1000': 500,
    'playlist-last-1000': 999,
    'playlist-miss-1000': None,
    'playlist-unicode-last-256': 255,
    'playlist-rejected-query-256': None,
}
units = {}
checksums = {}
operation_counts = {}
for case, combined in receipts.items():
    assert combined['case'] == case
    assert combined['baseline'] == combined['candidate']
    command = command_by_label['receipt-' + case]
    assert json.loads((OUT / command['stdout']).read_text()) == combined
    value = combined['baseline']
    if case.startswith('keys'):
        assert len(value['keyBytes']) == len(value['urls'])
        assert all(key is None or all(isinstance(byte, int) and 0 <= byte <= 255 for byte in key)
                   for key in value['keyBytes'])
        checksums[case] = sum(len(key) if key is not None else 1 for key in value['keyBytes'])
        operation_counts[case] = len(value['urls'])
        units[case] = 'persistence key'
        if case == 'keys-tiny-ascii':
            assert [bytes(value) for value in value['keyBytes']] == [b'/', b'/a', b'/a.mkv']
        if case == 'keys-rejected-256':
            assert value['keyBytes'] == [None] * 256
    else:
        assert value['indices'] == [expected_indices[case]]
        expected_count = 0 if case == 'playlist-empty' else (
            1 if case == 'playlist-single-hit' else (
                8 if case == 'playlist-small-last' else (256 if case.endswith('256') else 1000)))
        assert len(value['items']) == expected_count
        checksums[case] = sum(index + 1 if index is not None else 0 for index in value['indices'])
        operation_counts[case] = len(value['queries'])
        units[case] = 'playlist lookup'

case_order = manifest['method']['cases']
assert set(case_order) == set(receipts) == set(summary['cases']) == set(calibrations)
assert len(schedule) == PAIR_COUNT
expected_sequence = []
schedule_rng = random.Random(manifest['method']['seed'])
for pair_index, item in enumerate(schedule):
    assert item['pair'] == pair_index and set(item['cases']) == set(case_order)
    assert len(item['cases']) == len(case_order)
    independently_shuffled = list(case_order)
    schedule_rng.shuffle(independently_shuffled)
    assert item['cases'] == independently_shuffled
    order = ['baseline', 'candidate'] if pair_index % 2 == 0 else ['candidate', 'baseline']
    assert item['variants'] == order
    for case in item['cases']:
        for position, variant in enumerate(order):
            expected_sequence.append((pair_index, case, position, variant))
assert [(row['pair'], row['case'], row['position'], row['variant']) for row in rows] == expected_sequence

for row in rows:
    case = row['case']
    assert row['unit'] == units[case]
    assert row['operationsPerRound'] == operation_counts[case]
    assert row['operations'] == row['operationsPerRound'] * row['rounds']
    assert row['expectedChecksumPerRound'] == checksums[case]
    assert row['checksum'] == checksums[case] * row['rounds']
    assert row['wallNanoseconds'] > 0 and row['cpuNanoseconds'] > 0
    assert row['rounds'] == calibrations[case]['selected_rounds']
    command = commands[row['command_id']]
    assert command['label'] == f"measure-{row['pair']:02d}-{case}-{row['variant']}"
    emitted = json.loads((OUT / command['stdout']).read_text())
    assert emitted == {key: value for key, value in row.items()
                       if key not in ['pair', 'order', 'position', 'command_id']}

for case, value in calibrations.items():
    assert value['included_in_summary'] is False
    samples = value['samples']
    assert 1 <= len(samples) <= 8 and samples[0]['rounds'] == 1
    for attempt, sample in enumerate(samples):
        command = command_by_label[f'calibrate-{case}-{attempt}']
        assert json.loads((OUT / command['stdout']).read_text()) == sample
        assert sample['variant'] == 'baseline' and sample['case'] == case
        assert isinstance(sample['rounds'], int) and 1 <= sample['rounds'] <= MAX_ROUNDS
        assert sample['unit'] == units[case]
        assert sample['operationsPerRound'] == operation_counts[case]
        assert sample['operations'] == sample['rounds'] * operation_counts[case]
        assert sample['expectedChecksumPerRound'] == checksums[case]
        assert sample['checksum'] == sample['rounds'] * checksums[case]
        assert sample['cpuNanoseconds'] > 0 and sample['wallNanoseconds'] > 0
        if attempt:
            previous=samples[attempt - 1]
            assert previous['cpuNanoseconds'] < 10_000_000 and previous['rounds'] < MAX_ROUNDS
            expected_rounds=min(MAX_ROUNDS, max(previous['rounds'] + 1,
                math.ceil(previous['rounds'] * 10_000_000 / previous['cpuNanoseconds'])))
            assert sample['rounds'] == expected_rounds
    last = samples[-1]
    assert last['cpuNanoseconds'] >= 10_000_000 or last['rounds'] == MAX_ROUNDS or len(samples) == 8
    uncapped_rounds=max(1, math.ceil(last['rounds'] * args.expected_target_ms * 1_000_000 / last['cpuNanoseconds']))
    rounds = min(MAX_ROUNDS, uncapped_rounds)
    assert rounds == value['selected_rounds']
    assert value['at_round_cap'] is (rounds == MAX_ROUNDS)
    baseline_durations=[row['cpuNanoseconds'] / 1_000_000 for row in rows
                        if row['case'] == case and row['variant'] == 'baseline']
    CALIBRATION_CHECKS[case]={
        'sample_count': len(samples),
        'last_calibration_rounds': last['rounds'],
        'last_calibration_cpu_ms': last['cpuNanoseconds'] / 1_000_000,
        'calibration_floor_reached': last['cpuNanoseconds'] >= 10_000_000,
        'requested_baseline_cpu_ms': args.expected_target_ms,
        'uncapped_projected_rounds': uncapped_rounds,
        'selected_rounds': rounds,
        'maximum_rounds': MAX_ROUNDS,
        'at_round_cap': value['at_round_cap'],
        'target_limited_by_round_cap': uncapped_rounds > MAX_ROUNDS,
        'projected_selected_baseline_cpu_ms': last['cpuNanoseconds'] * rounds / last['rounds'] / 1_000_000,
        'observed_baseline_cpu_median_ms': statistics.median(baseline_durations),
        'observed_baseline_cpu_range_ms': [min(baseline_durations), max(baseline_durations)],
    }

audited_cases = {}
for case_index, case in enumerate(case_order):
    records = [row for row in rows if row['case'] == case]
    assert len(records) == 2 * PAIR_COUNT
    paired = []
    for index in range(PAIR_COUNT):
        pair = {row['variant']: row for row in records if row['pair'] == index}
        assert len(pair) == 2
        assert pair['baseline']['operations'] == pair['candidate']['operations']
        assert pair['baseline']['checksum'] == pair['candidate']['checksum']
        paired.append(pair)
    assert summary['cases'][case]['rounds'] == calibrations[case]['selected_rounds']
    assert summary['cases'][case]['operations_per_round'] == operation_counts[case]
    for label, timer in [('cpu', 'cpuNanoseconds'), ('wall', 'wallNanoseconds')]:
        before = [pair['baseline'][timer] / pair['baseline']['operations'] for pair in paired]
        after = [pair['candidate'][timer] / pair['candidate']['operations'] for pair in paired]
        ratios = [b / a for a, b in zip(before, after)]
        expected = summary['cases'][case][label]
        equal_number(expected['baseline_median_ns_per_operation'], statistics.median(before))
        equal_number(expected['candidate_median_ns_per_operation'], statistics.median(after))
        equal_number(expected['median_paired_change_percent'], (statistics.median(ratios) - 1) * 100)
        equal_number(expected['median_paired_delta_ns_per_operation'], statistics.median(b - a for a, b in zip(before, after)))
        assert expected['candidate_faster_pairs'] == sum(value < 1 for value in ratios)
        assert expected['pair_count'] == PAIR_COUNT
        generator = random.Random(manifest['method']['seed'] + case_index)
        bootstrap = sorted(statistics.median(generator.choices(ratios, k=PAIR_COUNT)) for _ in range(5000))
        for actual, expected_percentile in zip(expected['median_change_bootstrap_95_percent'], [bootstrap[124], bootstrap[4874]]):
            equal_number(actual, (expected_percentile - 1) * 100)
    audited_cases[case] = summary['cases'][case]

TEST_SUMMARIES={}
for variant in ['baseline', 'candidate']:
    log=TESTS_ROOT / ('tests-' + variant + '.log')
    text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', log.read_text())
    passes=re.findall(r'Test run with (\d+) tests(?: in \d+ suites)? passed after ([0-9.]+) seconds', text)
    assert len(passes) == 2, (str(log), passes)
    assert all(int(count) > 0 for count, duration in passes)
    assert 'reachableFileReferencesMatchBeforeAndAfterRename' in text
    TEST_SUMMARIES[variant]=[{'configuration': config, 'passed_test_count': int(count),
                              'reported_seconds': float(duration)}
                             for config, (count, duration) in zip(['debug', 'release'], passes)]
assert [row['passed_test_count'] for row in TEST_SUMMARIES['baseline']] == [row['passed_test_count'] for row in TEST_SUMMARIES['candidate']]
environment=TESTS_ROOT / 'environment.txt'
assert SOURCE_INDEX['commit'] in environment.read_text()
for path in ['Tests/IlliquidCoreTests/NormalizedFileURLPersistenceKeyTests.swift',
             'Scripts/test-file-identity-keys.sh', '.github/workflows/file-identity-keys.yml']:
    assert hashes((REPO / path).read_bytes())['git_blob_sha1'] == SOURCE_INDEX['files'][path]['sha']

report = {
    'passed': True,
    'native_checkout': manifest['checkout']['head'],
    'source_tree': SOURCE_INDEX['tree'],
    'test_summaries': TEST_SUMMARIES,
    'binary_verification': BINARY_VERIFICATION,
    'frontend_verification': FRONTEND_VERIFICATION,
    'compiler_plans': CMO_PLANS,
    'machine_code_audit_performed': False,
    'limitations': [
        'The artifact has source snapshots and command/data receipts. Recorded native binary/frontend hashes are not independently verified when the files are absent.',
        'No native machine-code or per-iteration-call-retention audit is claimed. Linux executable inspection does not establish native machine code.',
        'Separate compilation and no explicit CMO flag do not disable Swift default CMO; the recorded native frontend plans are reported directly.',
        'Ephemeral test-build sources are not uploaded; test log summaries are tied to the recorded checkout, script and test source identities.',
        'Unicode/URL parser differences may change the generated corpus count across platforms; exact optional byte parity and all eight native reference comparisons are required.',
        'The fixed 20-million-round cap can shorten very fast batches below the requested CPU duration. Valid capped selection is reported with its projection and observed durations, not treated as an invalid benchmark.',
    ],
    'baseline_revision': manifest['baseline']['revision'],
    'candidate_source_sha256': manifest['source_hashes']['candidate']['NormalizedFileURL.swift']['sha256'],
    'observations_verified': len(rows),
    'paired_comparisons_verified': len(rows) // 2,
    'workloads_verified': len(case_order),
    'exact_byte_differential': differential,
    'commands_verified': len(commands),
    'checks': [
        'Frozen source bytes equal the recorded baseline Git revision and hashes',
        'Candidate source snapshots match their recorded hashes and the immutable native Git commit tree',
        'Unchanged support source bytes match exactly',
        'Recorded compiler/build identities and explicit flags reviewed; unavailable native binaries/frontend reported as unverified',
        'All complete baseline/candidate receipts equal, with independent expected positions',
        'All recorded process outputs agree with retained observations and checksum expectations',
        'Every fixed-work pair has equal operations and balanced AB/BA order',
        'Calibration bounds, step progression, selection formula and cap flags verified and kept outside timing summaries',
        'Reported paired CPU/wall medians, absolute costs, wins and confidence intervals recomputed',
        'No observation deletion, missing output files, failed command or failure record',
    ],
    'round_capped_cases': [case for case, value in calibrations.items() if value['at_round_cap']],
    'calibration_checks': CALIBRATION_CHECKS,
    'screening': summary['screening'],
    'cases': audited_cases,
}
(OUT / args.report_name).write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
print(json.dumps({key: value for key, value in report.items() if key != 'cases'}, indent=2, sort_keys=True))
for case in case_order:
    value = audited_cases[case]['cpu']
    print(f"{case}: {value['median_paired_change_percent']:+.2f}% CPU; "
          f"{value['candidate_faster_pairs']}/{PAIR_COUNT} faster; "
          f"{value['baseline_median_ns_per_operation']:.1f} -> {value['candidate_median_ns_per_operation']:.1f} ns; "
          f"95% bootstrap {value['median_change_bootstrap_95_percent']}")
