from pathlib import Path
import collections
import gzip
import hashlib
import json
import math
import os
import platform
import random
import re
import statistics
import subprocess
import sys
import time

BASE = Path('/workspace/scratch/355e15c67b63')
REPO = BASE / 'illiquid-episode'
HERE = REPO / 'Benchmarks/EpisodeDisplayName'
OUT = BASE / 'episode-display-name-linux-recovered'
ORIGINAL = BASE / 'episode-display-name-linux-12pair'
RUNTIME = BASE / 'tools/episode-swift-runtime'
DESTINATION = BASE / 'episode-display-name-independent-audit.json'
SOURCE = 'Sources/IlliquidCore/MediaLibrary/MediaNameRecognition.swift'

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def raw(path):
    return path.read_bytes()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')

def document(path):
    return json.loads(raw(path))

def lines(path, tolerate_incomplete_tail=False):
    values = []
    entries = path.read_text().splitlines()
    for index, line in enumerate(entries):
        try:
            values.append(json.loads(line))
        except json.JSONDecodeError:
            require(tolerate_incomplete_tail and index == len(entries) - 1, f'Malformed JSONL: {path}:{index + 1}')
    return values

def close(left, right, label):
    require(math.isclose(left, right, rel_tol=1e-11, abs_tol=1e-7), f'Statistic mismatch {label}: {left} != {right}')

def source_hashes(data):
    return {'bytes': len(data), 'sha256': sha(data),
            'git_blob': hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()}

def verify_source(data, expected, label):
    require(all(source_hashes(data)[key] == expected[key] for key in ('bytes', 'sha256', 'git_blob')), f'Source mismatch: {label}')

def confidence(values, label):
    seed = 20261028 ^ int.from_bytes(hashlib.sha256(label.encode()).digest()[:8], 'big')
    rng = random.Random(seed)
    resampled = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10000))
    result = []
    for probability in (.025, .975):
        point = probability * (len(resampled) - 1)
        low, high = math.floor(point), math.ceil(point)
        result.append(resampled[low] + (resampled[high] - resampled[low]) * (point - low))
    return result

manifest = document(OUT / 'manifest.json')
if manifest.get('complete') is not True:
    print('NOT COMPLETE: no performance audit performed')
    raise SystemExit(2)
require(manifest.get('status') == 'measured', 'Completed manifest is not a measurement run')
require(not DESTINATION.exists(), 'Refusing to overwrite an earlier independent audit')
original_manifest = document(ORIGINAL / 'manifest.json')
report = {'schema': 1, 'passed': False, 'evidence': str(OUT),
          'audited_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
          'method': 'Independent standard-library calculations; no import or execution of benchmark runner functions',
          'audit_script_sha256': sha(raw(Path(__file__))), 'checks': {}, 'headlines': []}

# Verify the complete archived and live source chain inherited by recovery.
source_records = original_manifest['input_sources']
source_proofs = {}
require(set(manifest['input_sources']) == set(source_records) | {'recover.py'}, 'Recovered source inventory differs')
for name, expected in source_records.items():
    archived = raw(ORIGINAL / 'inputs' / name)
    verify_source(archived, expected, f'original inputs/{name}')
    if name == 'candidate/MediaNameRecognition.swift':
        current = raw(REPO / SOURCE)
    elif name == 'Package.swift':
        current = archived
    elif name.startswith('Tests/'):
        current = raw(REPO / name)
    else:
        current = raw(HERE / name)
    verify_source(current, expected, f'current {name}')
    require(manifest['input_sources'][name] == expected, f'Recovered source declaration differs: {name}')
    verify_source(raw(OUT / 'inputs' / name), expected, f'recovered inputs/{name}')
    source_proofs[name] = expected['sha256']
for path in (OUT / 'inputs/recover.py', HERE / 'recover.py'):
    verify_source(raw(path), manifest['input_sources']['recover.py'], f'Recovery helper: {path}')
source_proofs['recover.py'] = manifest['input_sources']['recover.py']['sha256']
pinned = document(HERE / 'baseline/manifest.json')
baseline_bytes = raw(HERE / 'baseline/MediaNameRecognition.swift')
verify_source(baseline_bytes, pinned['source'], 'frozen baseline')
git_source = subprocess.check_output(['git', 'show', f"{pinned['commit']}:{SOURCE}"], cwd=REPO,
                                    env={**os.environ, 'GIT_NO_LAZY_FETCH': '1'})
require(git_source == baseline_bytes, 'Frozen baseline differs from original git source')
for name, expected in pinned['existing_tests'].items():
    verify_source(raw(REPO / name), expected, name)
report['source_sha256'] = source_proofs
report['checks']['all_archived_current_and_frozen_source_hashes'] = True

# Inherited tests are explicitly separate from newly executed parity/timing.
tests = document(ORIGINAL / 'tests.json')
require(document(OUT / 'tests.json') == [{**row, 'inherited': True, 'qualified_run': str(ORIGINAL)} for row in tests], 'Recovered tests not explicitly inherited')
require(len(tests) == 4 and {(r['variant'], r['configuration']) for r in tests} ==
        {(v, c) for v in ('baseline', 'candidate') for c in ('debug', 'release')}, 'Incomplete inherited test matrix')
old_commands = lines(ORIGINAL / 'commands.jsonl', tolerate_incomplete_tail=True)
for test in tests:
    require(test['passed'] is True and test['count'] == 40, 'Unexpected inherited test qualification')
    label = f"tests-{test['variant']}-{test['configuration']}"
    matching = [row for row in old_commands if row['label'] == label]
    require(len(matching) == 1 and matching[0]['returncode'] == 0, f'Missing successful inherited command: {label}')
    text = ''
    for channel in ('stdout', 'stderr'):
        payload = raw(ORIGINAL / matching[0][channel])
        if matching[0][channel].endswith('.gz'):
            payload = gzip.decompress(payload)
        require(sha(payload) == matching[0][channel + '_sha256'], f'Inherited test log hash mismatch: {label}')
        text += payload.decode(errors='replace')
    require('Test run with 40 tests in 4 suites passed' in text, f'Inherited test completion missing: {label}')
report['test_qualification'] = {'origin': str(ORIGINAL), 'inherited': True, 'rerun_during_recovery': False,
                              'matrix': tests, 'executions': 160,
                              'qualification_note': 'Tests ran successfully before original environment failures; recovered runtime receives new full-output verification and timings below'}

binary_records = document(OUT / 'binaries.json') if (OUT / 'binaries.json').is_file() else document(ORIGINAL / 'binaries.json')
old_binaries = document(ORIGINAL / 'binaries.json')
for variant, entry in binary_records.items():
    require(sha(raw(Path(entry['path']))) == entry['sha256'] == old_binaries[variant]['sha256'], f'Executable mismatch: {variant}')
    package = ORIGINAL / 'work/packages' / variant
    expected_source = 'baseline/MediaNameRecognition.swift' if variant == 'baseline' else 'candidate/MediaNameRecognition.swift'
    require(raw(package / 'Sources/IlliquidCore/MediaNameRecognition.swift') == raw(ORIGINAL / 'inputs' / expected_source), 'Staged Core differs')
    require(raw(package / 'Sources/EpisodeDisplayNameDriver/Driver.swift') == raw(HERE / 'Driver.swift'), 'Staged Driver differs')
    description = document(Path(old_binaries[variant]['path']).parent / 'description.json')
    swift_commands = description['swiftCommands']
    by_module = {entry['moduleName']: entry for entry in swift_commands.values()}
    require('IlliquidCore' in by_module and 'EpisodeDisplayNameDriver' in by_module, 'Separate module compilation missing')
    core_args = by_module['IlliquidCore']['otherArguments']
    require('-enable-testing' in core_args, 'Core testing visibility not enabled')
    for entry in by_module.values():
        require('-cross-module-optimization' not in entry['otherArguments'], 'Unexpected cross-module optimization')
report['binary_sha256'] = {variant: entry['sha256'] for variant, entry in binary_records.items()}
report['checks']['unchanged_executables_and_separate_compilation_boundaries'] = True

runtime_receipt = document(OUT / 'original-verification.json')
require(raw(OUT / 'original-verification.json') == raw(RUNTIME / 'original-verification.json'), 'Runtime verification receipt differs')
require(raw(OUT / 'runtime-manifest.json') == raw(RUNTIME / 'runtime-manifest.json'), 'Runtime manifest differs')
runtime_hashes = {}
all_runtime_hashes = {}
runtime_manifest = document(OUT / 'runtime-manifest.json')
for original, entry in runtime_receipt['required_libraries'].items():
    if entry['in_surviving_runtime']:
        path = RUNTIME / Path(original).name
        require(not path.is_symlink(), 'Private runtime is a symlink to shared files')
        require(sha(raw(path)) == entry['sha256'], f'Private runtime library changed: {path.name}')
        require(runtime_manifest['files'][path.name]['sha256'] == entry['sha256'], 'Private runtime metadata differs')
        runtime_hashes[path.name] = entry['sha256']
    else:
        path = Path(entry['resolved_path'])
    require(len(raw(path)) == entry['bytes'] and sha(raw(path)) == entry['sha256'], f'Runtime dependency changed: {path}')
    all_runtime_hashes[str(path.resolve())] = {'bytes': entry['bytes'], 'sha256': entry['sha256']}
require(len(runtime_hashes) == 14, 'Unexpected runtime dependency inventory')
require(manifest['recovery']['runtime_libraries'] == all_runtime_hashes, 'Loaded runtime declaration differs')
require(manifest['recovery']['compilation_performed'] is False and manifest['recovery']['old_samples_included'] == 0, 'Recovery provenance is inaccurate')
require(manifest['environment']['LD_LIBRARY_PATH'] == str(RUNTIME), 'Private runtime not recorded in environment')
for key in ('LANG', 'LC_ALL', 'LC_COLLATE', 'LC_CTYPE', 'TZ', 'SWIFT_DETERMINISTIC_HASHING', 'SDKROOT', 'DEVELOPER_DIR'):
    require(manifest['environment'].get(key) == original_manifest['environment'].get(key), f'Environment differs: {key}')
report['runtime'] = {'directory': str(RUNTIME), 'required_libraries': runtime_hashes,
                     'all_loaded_dependency_count': len(all_runtime_hashes),
                     'copied_from_verified_surviving_runtime': True}

commands = lines(OUT / 'commands.jsonl')
by_sequence = {command['sequence']: command for command in commands}
require(len(by_sequence) == len(commands), 'Duplicate command sequence')
require([row['sequence'] for row in commands] == list(range(1, len(commands) + 1)), 'Missing or reordered command sequence')
for command in commands:
    require(command['returncode'] == 0, f"Failed command in completed evidence: {command['label']}")
    for channel in ('stdout', 'stderr'):
        path = OUT / command[channel]
        payload = raw(path)
        if path.suffix == '.gz':
            payload = gzip.decompress(payload)
        require(sha(payload) == command[channel + '_sha256'], f'Command log hash mismatch: {path}')
require(not any(row['label'].startswith(('tests-', 'build-')) for row in commands), 'Recovery unexpectedly contains new build/test commands')
for variant in ('baseline', 'candidate'):
    dependency_commands = [row for row in commands if row['label'] == f'runtime-dependencies-{variant}']
    require(len(dependency_commands) == 1, 'Missing runtime loading check')
    dependency_log = (OUT / dependency_commands[0]['stdout']).read_text()
    require('not found' not in dependency_log, 'Unresolved runtime dependency')
    resolved = {str(Path(path).resolve()) for path in re.findall(r'(?:=>\s+)?(/[^\s(]+)\s+\(', dependency_log)}
    require(resolved == set(all_runtime_hashes), 'Actual loaded runtime dependencies differ')

cases = document(OUT / 'cases.json')
require(len(cases) == 15 and len({case['name'] for case in cases}) == 15, 'Unexpected case inventory')
require(cases == manifest['selected_cases'], 'Manifest selected cases differ')
canonical_receipts = json.loads(gzip.decompress(raw(OUT / 'verification-receipts.json.gz')))
require(len(canonical_receipts) == 16 and sum(len(row['labels']) for row in canonical_receipts) == 4139, 'Unexpected full-output corpus')
parity = document(OUT / 'parity.json')
receipt_hash = sha(canonical(canonical_receipts))
require(receipt_hash == parity['sha256'] == '94a7075d4c5579548b6ab82fc4e22ffa8b39e734b28bcbb604c1a78c6e71146e', 'Complete receipt hash differs')
expected = {}
for row in canonical_receipts:
    checksum = sum((index + 1) * len(label.encode('utf-8')) for index, label in enumerate(row['labels']))
    require(type(row['checksum']) is int and checksum == row['checksum'], f"Receipt checksum mismatch: {row['name']}")
    expected[row['name']] = (len(row['labels']), checksum)
for variant in ('baseline', 'candidate'):
    for flag, expected_output in (('--list', cases), ('--verify', canonical_receipts)):
        matching = [row for row in commands if len(row['argv']) == 2 and row['argv'][0] == binary_records[variant]['path'] and row['argv'][1] == flag]
        require(len(matching) == 1, f'Missing new full-output command: {variant} {flag}')
        path = OUT / matching[0]['stdout']
        payload = gzip.decompress(raw(path)) if path.suffix == '.gz' else raw(path)
        require(json.loads(payload) == expected_output, f'Recovered {variant} {flag} differs')
report['new_output_verification'] = {'rerun_for_both_variants': True, 'receipts': 16, 'labels': 4139,
                                    'exact_utf8_equal': True, 'independent_checksums_equal': True, 'sha256': receipt_hash}

observations = lines(OUT / 'observations.jsonl')
calibrations = lines(OUT / 'calibration.jsonl')
iterations = document(OUT / 'iterations.json')
require(len(observations) == 360, f'Expected 360 fresh observations; got {len(observations)}')
for row in observations + calibrations:
    name, variant, count = row['case'], row['variant'], row['iterations']
    require(name in {case['name'] for case in cases} and variant in ('baseline', 'candidate'), 'Unknown observation identity')
    size, batch_checksum = expected[name]
    require(type(count) is int and 1 <= count <= 1000000, 'Iteration bound violation')
    require(row['labels_per_iteration'] == size, 'Wrong measured batch size')
    require(row['checksum'] == row['expected_checksum'] == batch_checksum * count, 'Measured checksum mismatch')
    require(row['postflight_matches'] is True, 'Postflight failed')
    require(all(type(row[metric]) is int and row[metric] > 0 for metric in ('cpu_ns', 'wall_ns')), 'Invalid timing duration')
    command = by_sequence[row['command_sequence']]
    require(command['argv'] == [binary_records[variant]['path'], '--measure', name, str(count)], 'Measured command mismatch')
    path = OUT / command['stdout']
    original_output = document(path)
    require(all(row[key] == value for key, value in original_output.items()), 'Observation differs from recorded process output')
    for metric in ('cpu_ns', 'wall_ns'):
        close(row[metric + '_per_batch'], row[metric] / count, 'per-batch duration')
        close(row[metric + '_per_label'], row[metric] / (count * size), 'per-label duration')

planned = []
for pair in range(12):
    indexed = list(enumerate(cases))
    offset = pair % len(indexed)
    for index, case in indexed[offset:] + indexed[:offset]:
        order = ('baseline', 'candidate') if (pair + index) % 2 == 0 else ('candidate', 'baseline')
        for position, variant in enumerate(order):
            planned.append((case['name'], pair, variant, position, list(order)))
actual = [(row['case'], row['pair'], row['variant'], row['position_in_pair'], row['order']) for row in observations]
require(actual == planned, 'Fresh balanced rotation/order does not match fixed study design')
require(len({(r['case'], r['pair'], r['variant']) for r in observations}) == 360, 'Duplicate timed observation identity')
for case in cases:
    name = case['name']
    require(all(row['iterations'] == iterations[name] for row in observations if row['case'] == name), f'Unequal fixed work: {name}')
    trials = [row for row in calibrations if row['case'] == name]
    require(trials and all(row['variant'] == 'baseline' for row in trials), 'Calibration includes nonbaseline code')
    last = trials[-1]
    calculated_count = min(1000000, max(1, math.ceil(last['iterations'] * 150000000 / last['cpu_ns'])))
    require(calculated_count == iterations[name], f'Unexpected calibration-derived count: {name}')
report['checks']['360_fresh_valid_observations_balanced_equal_work_and_positive_times'] = True
report['observations'] = 360
report['calibration_observations'] = len(calibrations)
report['minimum_measured_cpu_ms'] = {variant: min(row['cpu_ns'] for row in observations if row['variant'] == variant) / 1000000 for variant in ('baseline', 'candidate')}

summary = document(OUT / 'summary.json')
require(len(summary) == 15, 'Incomplete summary')
summary_by_name = {row['name']: row for row in summary}
for case in cases:
    name = case['name']
    reported = summary_by_name[name]
    require(reported['pairs'] == 12 and reported['iterations_both_variants'] == iterations[name], 'Incorrect summary sample metadata')
    selected = [row for row in observations if row['case'] == name]
    for variant in ('baseline', 'candidate'):
        values = [row for row in selected if row['variant'] == variant]
        require(len(values) == 12, 'Wrong variant sample count')
        for metric in ('cpu_ns_per_batch', 'wall_ns_per_batch', 'cpu_ns_per_label', 'wall_ns_per_label'):
            numeric = [row[metric] for row in values]
            for field, calculated in [('median', statistics.median(numeric)), ('minimum', min(numeric)), ('maximum', max(numeric)), ('samples', len(numeric))]:
                close(reported[variant][metric][field], calculated, f'{name}/{variant}/{metric}/{field}')
    headline = {'case': name, 'batch_size': case['batch_size'], 'control': name.endswith('-control'),
                'baseline_cpu_ns_per_label': reported['baseline']['cpu_ns_per_label']['median'],
                'candidate_cpu_ns_per_label': reported['candidate']['cpu_ns_per_label']['median']}
    for metric in ('cpu_ns_per_label', 'wall_ns_per_label'):
        reductions = []
        for pair in range(12):
            values = {row['variant']: row[metric] for row in selected if row['pair'] == pair}
            reductions.append(100 * (1 - values['candidate'] / values['baseline']))
        key = metric.replace('_ns_per_label', '_reduction_percent')
        actual_interval = confidence(reductions, name + metric)
        entry = reported[key]
        for field, calculated in [('median', statistics.median(reductions)), ('minimum', min(reductions)), ('maximum', max(reductions)), ('samples', 12), ('faster_pairs', sum(x > 0 for x in reductions))]:
            close(entry[field], calculated, f'{name}/{key}/{field}')
        require(len(entry['paired_values']) == 12, 'Wrong number of paired reductions')
        for a, b in zip(entry['paired_values'], reductions):
            close(a, b, f'{name}/{key}/paired reduction')
        for a, b in zip(entry['bootstrap_median_95_ci'], actual_interval):
            close(a, b, f'{name}/{key}/bootstrap interval')
        ratio = 100 * (1 - reported['candidate'][metric]['median'] / reported['baseline'][metric]['median'])
        close(entry['ratio_of_medians'], ratio, f'{name}/{key}/ratio of medians')
        headline[key] = {'paired_median': statistics.median(reductions), 'bootstrap_95_ci': actual_interval,
                         'ratio_of_medians': ratio, 'faster_pairs': sum(x > 0 for x in reductions)}
    report['headlines'].append(headline)
report['checks']['all_reported_medians_ranges_paired_values_and_bootstrap_intervals_recomputed'] = True
report['adverse_controls'] = [row for row in report['headlines'] if row['control'] and row['cpu_reduction_percent']['paired_median'] < 0]
report['adverse_cases_with_entire_nominal_cpu_interval_below_zero'] = [row['case'] for row in report['headlines'] if row['cpu_reduction_percent']['bootstrap_95_ci'][1] < 0]
report['interrupted_attempts'] = []
for path in (ORIGINAL, BASE / 'episode-display-name-linux-12pair-rerun'):
    disposition = document(path / 'aborted.json') if (path / 'aborted.json').is_file() else None
    report['interrupted_attempts'].append({'path': str(path), 'included_in_statistics': False, 'recorded_disposition': disposition})
references = document(OUT / 'references.json')
require(len(references) == 2, 'Interrupted attempt references incomplete')
for index, reference in enumerate(references):
    for name, expected_hash in reference['files'].items():
        payload = raw(OUT / 'references' / f'interrupted-{index + 1}' / name)
        require(len(payload) == expected_hash['bytes'] and sha(payload) == expected_hash['sha256'], f'Interrupted reference changed: {name}')
report['checks']['interrupted_attempts_retained_separately_and_excluded_from_statistics'] = True
report['artifact_sha256'] = {name: sha(raw(OUT / name)) for name in (
    'manifest.json', 'cases.json', 'parity.json', 'iterations.json', 'observations.jsonl', 'calibration.jsonl', 'commands.jsonl', 'summary.json', 'verification-receipts.json.gz', 'tests.json', 'binaries.json', 'runtime-manifest.json', 'original-verification.json', 'references.json')}
report['passed'] = True
DESTINATION.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
print(json.dumps({'passed': True, 'output': str(DESTINATION), 'observations': 360,
                  'new_verification_labels': 4139, 'inherited_test_executions': 160,
                  'adverse_controls': [row['case'] for row in report['adverse_controls']],
                  'adverse_confident_cases': report['adverse_cases_with_entire_nominal_cpu_interval_below_zero']}, indent=2))
for row in report['headlines']:
    cpu = row['cpu_reduction_percent']
    print(f"{row['case']}: {row['baseline_cpu_ns_per_label']:.3f} -> {row['candidate_cpu_ns_per_label']:.3f} ns/label; paired {cpu['paired_median']:.3f}%; CI {cpu['bootstrap_95_ci']}; faster {cpu['faster_pairs']}/12")
