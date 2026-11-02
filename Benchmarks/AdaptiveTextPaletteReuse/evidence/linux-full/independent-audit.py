#!/usr/bin/env python3
"""Independently audit the completed full palette-reuse Linux cohort.

Pass extracted raw benchmark and test evidence directories with --cohort and
--tests, and choose a JSON report with --output. The checkout must contain the
published research commit and historical baseline; the unpublished original
local commit is verified from its preserved raw object payload instead.
"""
from pathlib import Path
import argparse
import base64
import collections
import hashlib
import itertools
import json
import math
import re
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkout', type=Path, default=Path(__file__).resolve().parents[4],
                    help='repository checkout (default: repository containing this script)')
parser.add_argument('--cohort', type=Path, required=True,
                    help='extracted raw full benchmark output directory')
parser.add_argument('--tests', type=Path, required=True,
                    help='extracted raw baseline/candidate debug/release test output directory')
parser.add_argument('--output', type=Path, required=True, help='JSON audit report destination')
args = parser.parse_args()
ROOT = args.checkout.resolve()
OUT = args.cohort.resolve()
TESTS = args.tests.resolve()
DEST = args.output.resolve()
PUBLISHED = '8b89675ce399cb59bbf9a995768d2a32f2e04ffb'
LOCAL = '2ef550f27a0ecd37ce7cf2fc34815e14ee8abf07'
BASE = 'ea2ff568237e2667f7b1aeee67b11a44ebe95b72'
KERNELS = ['uncached', 'revision', 'hit', 'component_hit']
PREFIXES = ['one', 'local9-bright', 'local9-dark', 'local9-midgray',
            'leading32-saturated', 'bottom24-varied', 'overall96-bright',
            'overall96-dark', 'overall96-midgray', 'overall96-mixed',
            'overall96-varied', 'letterbox224']
CASES = [f'{prefix}-{mode}' for prefix in PREFIXES for mode in ['rainbow', 'mono']]
checks = []

def check(condition, message):
    if not condition:
        raise AssertionError(message)
    checks.append(message)

def read(name, root=OUT):
    return json.loads((root / name).read_text())

def sha(data):
    return hashlib.sha256(data).hexdigest()

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def close(a, b):
    return math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-10)

def theme_extraction(source, overlay):
    start = source.index('enum PlayerTheme:')
    end = source.index('\n@MainActor\nprivate struct DynamicPlayerTextStyleModifier:')
    prefix = source[start:end]
    appkit_start = prefix.index('    var appKitPrimaryColor: NSColor {')
    appkit_end = prefix.index('\n}\n\nenum PlayerThemeSurfaceStyle')
    prefix = prefix[:appkit_start] + prefix[appkit_end:]
    tail = source[source.index('struct PlayerTextSamplingGeometry:'):
                  source.index('\n@MainActor\n@Observable\nfinal class PlayerThemeStore')]
    role = overlay[overlay.index('enum PlayerOverlaySurfaceRole:'):
                   overlay.index('\n\nenum PlayerGlassGroupID:')]
    return ('import Foundation\nimport Observation\nimport IlliquidCore\nimport IlliquidPlayer\n'
            + '\n' + role + '\n\n' + prefix + '\n\n' + tail + '\n').encode()

manifest = read('manifest.json')
binding_path = ROOT / 'Benchmarks/AdaptiveTextPaletteReuse/evidence/source-revision-binding.json'
binding = json.loads(binding_path.read_text())
published_tree = git('rev-parse', PUBLISHED + '^{tree}').decode().strip()
local_object = binding['tested_local_commit_object']
check(local_object['type'] == 'commit' and local_object['encoding'] == 'base64',
      'preserved local object declares the expected commit type and byte encoding')
local_payload = base64.b64decode(local_object['payload'], validate=True)
check(len(local_payload) == local_object['byte_length'], 'preserved local commit payload length matches')
local_object_hash = hashlib.sha1(b'commit ' + str(len(local_payload)).encode('ascii')
                                 + b'\0' + local_payload).hexdigest()
check(local_object_hash == LOCAL, 'preserved raw commit payload reconstructs the tested local Git object ID')
local_headers = local_payload.split(b'\n\n', 1)[0].splitlines()
local_trees = [line.removeprefix(b'tree ').decode('ascii')
               for line in local_headers if line.startswith(b'tree ')]
check(len(local_trees) == 1 and re.fullmatch(r'[0-9a-f]{40}', local_trees[0]) is not None,
      'preserved tested commit contains exactly one valid tree header')
local_tree = local_trees[0]
check(published_tree == local_tree == binding['identical_tree'], 'published and tested commits have exactly the same Git tree')
check(binding['published_research_commit'] == PUBLISHED and binding['tested_local_commit'] == LOCAL,
      'binding names the audited published and local commits')
check(manifest['candidate_git_head'] == LOCAL, 'run manifest binds to the expected tested local commit')
check(manifest['baseline']['commit'] == BASE, 'run baseline commit is pinned correctly')

source_checks = {}
for name, expected_hash in manifest['sources'].items():
    actual = (OUT / 'sources' / name).read_bytes()
    check(sha(actual) == expected_hash, 'source snapshot hash matches manifest: ' + name)
    source_checks[name] = {'sha256': sha(actual), 'matches_manifest': True}

paths = {
    'candidate-PlayerTheme.swift': 'Sources/IlliquidApp/UI/PlayerTheme.swift',
    'baseline-PlayerTheme.swift': 'Benchmarks/AdaptiveTextPaletteReuse/baseline/PlayerTheme.swift',
    'Driver.swift': 'Benchmarks/AdaptiveTextPaletteReuse/Driver.swift',
    'LinuxColor.swift': 'Benchmarks/AdaptiveTextPaletteReuse/LinuxColor.swift',
    'run.py': 'Benchmarks/AdaptiveTextPaletteReuse/run.py',
    **{name: data['original'] for name, data in manifest['shared_support'].items()},
}
for name, path in paths.items():
    blob = git('show', f'{PUBLISHED}:{path}')
    check(blob == (OUT / 'sources' / name).read_bytes(), 'snapshot equals published Git blob: ' + name)
    source_checks[name]['published_git_blob_match'] = True
    if name in manifest['shared_support']:
        check(blob == git('show', f'{BASE}:{path}'), 'common support equals historical baseline: ' + name)
        source_checks[name]['baseline_git_blob_match'] = True
baseline = (OUT / 'sources/baseline-PlayerTheme.swift').read_bytes()
candidate = (OUT / 'sources/candidate-PlayerTheme.swift').read_bytes()
check(baseline == git('show', f'{BASE}:Sources/IlliquidApp/UI/PlayerTheme.swift'), 'frozen theme is the exact historical production blob')
check(sha(baseline) == manifest['baseline']['sha256'], 'historical production blob matches baseline manifest digest')
check(sha(candidate) == manifest['candidate_theme_sha256'], 'candidate theme digest matches the manifest')
palette_start = '@MainActor\nstruct PlayerTextPalette {'
palette_end = '\n@MainActor\nprivate struct DynamicPlayerTextStyleModifier:'
def without_palette(text):
    check(text.count(palette_start) == text.count(palette_end) == 1, 'theme palette extraction boundaries are unique')
    return text[:text.index(palette_start)] + text[text.index(palette_end):]
check(without_palette(baseline.decode()) == without_palette(candidate.decode()),
      'baseline and candidate theme bytes outside PlayerTextPalette are identical')
overlay = (OUT / 'sources/PlayerOverlayMaterial.swift').read_text()
for variant, original in [('baseline', baseline), ('candidate', candidate)]:
    generated = theme_extraction(original.decode(), overlay)
    check(generated == (OUT / 'sources' / f'{variant}-PlayerThemeSupport.swift').read_bytes(),
          'independently reconstructed Linux extraction matches: ' + variant)

inventory = read('cases.json')
check([item['name'] for item in inventory] == CASES, 'driver inventory contains exactly the intended 24 ordered cases')
check(all(item['variants'] == 8 for item in inventory), 'all cases use eight deterministic input variants')
measurements = read('measurements.json')
pairs = read('pairs.json')
summary = read('summary.json')
commands = read('commands.json')
check(len(measurements) == 24 * 4 * 6 * 2 == 1152, 'all 1152 expected measured processes are present')
check(len(pairs) == 24 * 4 * 6 == 576, 'all 576 expected paired results are present')
check(len(summary) == 24 * 4 == 96, 'all 96 expected workload summaries are present')
check(len(commands) == 4 + 2 + 4 + 2 + 2 + 96 + 1152 == 1262,
      'all expected commands including calibration and provenance are recorded')
check(all(command['returncode'] == 0 for command in commands), 'all 1262 recorded commands exited successfully')
check(all((OUT / command['stdout']).is_file() and (OUT / command['stderr']).is_file() for command in commands),
      'every command retains stdout and stderr logs')
command_outputs = {command['stdout']: command for command in commands}
check(len(command_outputs) == len(commands), 'command stdout log paths are unique')
expected_measurements = set(itertools.product(CASES, KERNELS, range(1, 7), ('baseline', 'candidate')))
indexed = {(row['case'], row['kernel'], row['round'], row['variant']): row for row in measurements}
check(len(indexed) == len(measurements) and set(indexed) == expected_measurements,
      'measurement Cartesian coverage is complete with no duplicate workload observations')

raw_hashes = {}
for key, row in indexed.items():
    case, kernel, round_number, variant = key
    order = ['baseline', 'candidate'] if round_number % 2 else ['candidate', 'baseline']
    check(row['order'] == order, f'balanced order recorded correctly: {key}')
    check(isinstance(row['iterations'], int) and row['iterations'] > 0, f'positive iteration count: {key}')
    check(row['warmup_iterations'] == max(1, min(64, row['iterations'] // 10)), f'correct common warmup count: {key}')
    for elapsed, per_operation in [('elapsed_ns', 'ns_per_operation'), ('cpu_elapsed_ns', 'cpu_ns_per_operation')]:
        check(math.isfinite(row[elapsed]) and row[elapsed] > 0 and
              close(row[per_operation], row[elapsed] / row['iterations']), f'timing division recomputes exactly: {key}/{elapsed}')
    expected_revision = 0 if kernel == 'uncached' else 1 if kernel == 'hit' else row['iterations'] + 1
    check(row['revision'] == expected_revision and row['generation'] == 0,
          f'actual cache counters match the intended path: {key}')
    filename = f'timings/r{round_number:02d}-{case}-{kernel}-{variant}.json'
    raw = read(filename)
    check(all(field in row and row[field] == value for field, value in raw.items()),
          f'aggregate measurement equals the raw process result: {key}')
    command = command_outputs[filename]
    check(command['argv'][1:] == ['time', case, kernel, str(row['iterations']), str(row['warmup_iterations'])]
          and Path(command['argv'][0]).name == variant, f'process command matches measured workload: {key}')
    check(command['cpu_affinity'] == 0, f'timed process pins the declared CPU: {key}')
    raw_hashes[filename] = sha((OUT / filename).read_bytes())

pair_index = {(row['case'], row['kernel'], row['round']): row for row in pairs}
check(len(pair_index) == len(pairs), 'paired records are unique')
recomputed = {}
for case, kernel, round_number in itertools.product(CASES, KERNELS, range(1, 7)):
    a = indexed[case, kernel, round_number, 'baseline']
    b = indexed[case, kernel, round_number, 'candidate']
    for invariant in ['checksum', 'warmup_checksum', 'revision', 'generation', 'iterations', 'warmup_iterations']:
        check(a[invariant] == b[invariant], f'exact pair invariant agrees: {case}/{kernel}/{round_number}/{invariant}')
    result = {'wall_reduction_percent': 100 * (1 - b['ns_per_operation'] / a['ns_per_operation']),
              'cpu_reduction_percent': 100 * (1 - b['cpu_ns_per_operation'] / a['cpu_ns_per_operation'])}
    for field, value in result.items():
        check(close(value, pair_index[case, kernel, round_number][field]),
              f'paired reduction independently recomputes: {case}/{kernel}/{round_number}/{field}')
    recomputed[case, kernel, round_number] = result

recomputed_summary = []
summary_index = {(row['case'], row['kernel']): row for row in summary}
check(len(summary_index) == len(summary), 'summary workload records are unique')
for case, kernel in itertools.product(CASES, KERNELS):
    observed = summary_index[case, kernel]
    row = {'case': case, 'kernel': kernel, 'pairs': 6,
           'iterations_per_process': indexed[case, kernel, 1, 'baseline']['iterations']}
    for clock, metric in [('wall', 'ns_per_operation'), ('cpu', 'cpu_ns_per_operation')]:
        reductions = [recomputed[case, kernel, round_number][clock + '_reduction_percent'] for round_number in range(1, 7)]
        row[f'median_paired_{clock}_reduction_percent'] = statistics.median(reductions)
        row[f'candidate_faster_{clock}_pairs'] = sum(value > 0 for value in reductions)
        for variant in ['baseline', 'candidate']:
            field = f'{variant}_median_' + ('cpu_ns_per_operation' if clock == 'cpu' else 'ns_per_operation')
            row[field] = statistics.median(indexed[case, kernel, round_number, variant][metric] for round_number in range(1, 7))
    for field, value in row.items():
        check(close(value, observed[field]) if isinstance(value, (int, float)) else value == observed[field],
              f'summary statistic independently recomputes: {case}/{kernel}/{field}')
    row['paired_cpu_changes_percent'] = [recomputed[case, kernel, round_number]['cpu_reduction_percent'] for round_number in range(1, 7)]
    row['absolute_cpu_median_delta_ns'] = row['candidate_median_cpu_ns_per_operation'] - row['baseline_median_cpu_ns_per_operation']
    row['cpu_process_duration_ms_range'] = [min(indexed[case, kernel, rnd, variant]['cpu_elapsed_ns'] / 1e6 for rnd in range(1, 7) for variant in ['baseline', 'candidate']),
                                           max(indexed[case, kernel, rnd, variant]['cpu_elapsed_ns'] / 1e6 for rnd in range(1, 7) for variant in ['baseline', 'candidate'])]
    recomputed_summary.append(row)

receipt_bytes = {variant: (OUT / f'{variant}-receipts.jsonl').read_bytes() for variant in ['baseline', 'candidate']}
differential = read('differential.json')
check(receipt_bytes['baseline'] == receipt_bytes['candidate'], 'complete verification receipt streams are byte-identical')
check(len(receipt_bytes['baseline'].splitlines()) == differential['receipt_count'] == 5382,
      'all 5382 expected semantic output receipts are present')
check(all(sha(data) == differential['sha256'][variant] for variant, data in receipt_bytes.items()),
      'receipt stream SHA256 values recompute correctly')
receipt_rows = [json.loads(line) for line in receipt_bytes['baseline'].splitlines()]
receipt_counts = collections.Counter('ordinary' if 'revision_miss' in row else
                                    'component_hit' if 'component_hit' in row else
                                    'store_switch' if 'store_switch' in row else
                                    'equal_counter_switch' if 'equal_counter_switch' in row else
                                    'overflow' if 'overflow' in row else
                                    'fallback' if 'fallback_theme' in row else 'unknown'
                                    for row in receipt_rows)
check(dict(receipt_counts) == {'ordinary': 3456, 'component_hit': 1152, 'store_switch': 72,
                              'equal_counter_switch': 72, 'overflow': 600, 'fallback': 30},
      'receipt coverage exactly matches normal paths, both source switches, component hits, overflow, and fallbacks')

tests = read('tests.json', TESTS)
test_manifest = read('manifest.json', TESTS)
test_commands = read('commands.json', TESTS)
check(set(tests) == {'baseline-debug', 'baseline-release', 'candidate-debug', 'candidate-release'},
      'isolated tests include both variants in both configurations')
check(all(value['passed'] and value['executed_tests'] == 6 for value in tests.values()),
      'six isolated tests passed in each of four variant/configuration runs')
check(all(command['returncode'] == 0 for command in test_commands), 'all retained tests3 commands exited successfully')
for source_name, source_hash in test_manifest['sources'].items():
    check(sha((TESTS / 'sources' / source_name).read_bytes()) == source_hash,
          'test source snapshot hashes match the tests3 manifest: ' + source_name)
    if source_name in paths:
        check((TESTS / 'sources' / source_name).read_bytes() == git('show', f'{PUBLISHED}:{paths[source_name]}'),
              'test snapshot equals published Git source: ' + source_name)
test_source = (TESTS / 'sources/AdaptiveTextPaletteReuseTests.swift').read_bytes()
check(test_source == git('show', f'{PUBLISHED}:Tests/IlliquidAppTests/AdaptiveTextPaletteReuseTests.swift'),
      'the six isolated tests are the exact published test source')
for variant_configuration, data in tests.items():
    output_file = data['output']
    command = next(cmd for cmd in test_commands if cmd['stdout'] == output_file)
    output = (TESTS / output_file).read_text() + (TESTS / command['stderr']).read_text()
    counts = re.findall(r'Test run with (\d+) tests?\b[^\n]*\bpassed\b', output)
    check(bool(counts) and int(counts[-1]) == 6, 'positive Swift Testing execution receipt verified: ' + variant_configuration)

kernel_summaries = {}
for kernel in KERNELS:
    rows = [row for row in recomputed_summary if row['kernel'] == kernel]
    medians = [row['median_paired_cpu_reduction_percent'] for row in rows]
    kernel_summaries[kernel] = {
        'workloads': len(rows), 'positive_cpu_medians': sum(value > 0 for value in medians),
        'median_paired_cpu_reduction_range_percent': [min(medians), max(medians)],
        'candidate_faster_cpu_pairs': sum(row['candidate_faster_cpu_pairs'] for row in rows),
        'total_pairs': len(rows) * 6,
        'negative_cpu_median_workloads': [row['case'] for row in rows if row['median_paired_cpu_reduction_percent'] < 0],
    }

representative_cases = ['local9-bright-rainbow', 'local9-midgray-rainbow',
                        'leading32-saturated-rainbow', 'overall96-bright-rainbow',
                        'overall96-midgray-rainbow', 'overall96-mixed-mono',
                        'overall96-varied-mono', 'letterbox224-rainbow']
audit = {
    'result': 'all integrity and arithmetic checks passed; control non-regression remains unproven',
    'input_directory': str(OUT),
    'test_directory': str(TESTS),
    'checkout': str(ROOT),
    'published_commit': PUBLISHED, 'tested_local_commit': LOCAL, 'identical_git_tree': published_tree,
    'preserved_local_commit_verification': {'object_sha1': local_object_hash,
        'payload_byte_length': len(local_payload), 'tree': local_tree,
        'verified_from_preserved_payload': True, 'requires_local_git_object': False,
        'binding_file_sha256': sha(binding_path.read_bytes())},
    'number_of_successful_assertions': len(checks),
    'counts': {'cases': 24, 'kernels': 4, 'rounds': 6, 'variants': 2,
               'observations': len(measurements), 'pairs': len(pairs), 'summaries': len(summary),
               'commands': len(commands), 'semantic_receipts': len(receipt_rows),
               'isolated_tests_per_configuration': 6, 'isolated_variant_configurations': 4},
    'source_checks': source_checks,
    'receipt_sha256': differential['sha256'], 'receipt_categories': dict(receipt_counts),
    'kernel_summaries': kernel_summaries,
    'recomputed_summaries': recomputed_summary,
    'representative_miss_revision_results': [row for row in recomputed_summary
        if row['case'] in representative_cases and row['kernel'] in {'uncached', 'revision'}],
    'control_interpretation': {
        'neutrality_established': False,
        'material_concerns': [
            'hit/local9-dark-rainbow: five of six pairs slower; median paired CPU change -12.70%; approximately 73 ns difference between independent CPU timing medians',
            'component_hit/overall96-bright-mono: five of six pairs slower; median paired CPU change -8.45%; approximately 5.36 us difference between independent CPU timing medians',
            'component_hit/leading32-saturated-rainbow: median paired change -15.79% with one -126.3% pair and four of six slower; mixed signs preclude attribution from this short cohort alone',
        ],
        'recommended_confirmation': {'cases': ['local9-dark-rainbow', 'overall96-bright-mono',
            'leading32-saturated-rainbow', 'local9-midgray-rainbow', 'bottom24-varied-rainbow',
            'overall96-dark-mono', 'overall96-varied-mono', 'letterbox224-mono'],
            'kernels': ['hit', 'component_hit'], 'pairs': 8, 'target_ms': 250,
            'reason': 'Cover the materially concerning negative patterns plus positive/neutral shapes without repeating every stable miss workload.'},
    },
    'limitations': [
        'Linux uses a numeric Color shim; native macOS, real view rendering, end-to-end playback, FPS, energy, and whole-player CPU were not measured here.',
        'No CPU frequency, thermal state, or neighboring-workload isolation guarantee; raw controls show wide positive and negative paired swings.',
        'Benchmark temporary binaries were already removed by the runner before this independent audit, so their manifest hashes cannot be independently recomputed after completion. Source snapshots, commands, and source hashes were independently verified.',
        'The isolated tests exercise exact extracted production code rather than the complete native app module graph.',
    ],
    'audited_file_sha256': {name: sha((OUT / name).read_bytes()) for name in
        ['manifest.json', 'commands.json', 'cases.json', 'measurements.json', 'pairs.json', 'summary.json',
         'differential.json', 'baseline-receipts.jsonl', 'candidate-receipts.jsonl']},
    'raw_process_json_sha256': raw_hashes,
}
DEST.write_text(json.dumps(audit, indent=2, sort_keys=True) + '\n')
print('AUDIT', DEST)
print('SUCCESSFUL_ASSERTIONS', len(checks))
print(json.dumps(kernel_summaries, indent=2))
for row in audit['representative_miss_revision_results']:
    print(row['case'], row['kernel'],
          round(row['baseline_median_cpu_ns_per_operation'] / 1000, 3),
          round(row['candidate_median_cpu_ns_per_operation'] / 1000, 3),
          round(row['median_paired_cpu_reduction_percent'], 3),
          row['candidate_faster_cpu_pairs'])
