#!/usr/bin/env python3
"""Audit the eight-round Linux cache-control confirmation and compare the full cohort."""
from pathlib import Path
import argparse
import collections
import hashlib
import itertools
import json
import math
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkout', type=Path, default=Path.cwd())
parser.add_argument('--cohort', type=Path, required=True)
parser.add_argument('--reference', type=Path, required=True,
                    help='original full-cohort raw evidence directory')
parser.add_argument('--binary-receipt', type=Path,
                    help='optional contemporaneous independent binary-hash observation')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
ROOT, OUT, REFERENCE, DEST = (value.resolve() for value in
    (args.checkout, args.cohort, args.reference, args.output))
PUBLISHED = '8b89675ce399cb59bbf9a995768d2a32f2e04ffb'
BASE = 'ea2ff568237e2667f7b1aeee67b11a44ebe95b72'
KERNELS = ['hit', 'component_hit']
PREFIXES = ['one', 'local9-bright', 'local9-dark', 'local9-midgray',
            'leading32-saturated', 'bottom24-varied', 'overall96-bright',
            'overall96-dark', 'overall96-midgray', 'overall96-mixed',
            'overall96-varied', 'letterbox224']
CASES = [f'{prefix}-{mode}' for prefix in PREFIXES for mode in ['rainbow', 'mono']]
assertions = []

def check(condition, description):
    if not condition:
        raise AssertionError(description)
    assertions.append(description)

def read(name, root=OUT):
    return json.loads((root / name).read_text())

def sha(data):
    return hashlib.sha256(data).hexdigest()

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def close(a, b):
    return math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-10)

manifest = read('manifest.json')
reference_manifest = read('manifest.json', REFERENCE)
check(manifest['candidate_git_head'] == PUBLISHED, 'candidate manifest identifies published commit')
check(manifest['baseline']['commit'] == BASE, 'historical baseline commit is pinned')
check(manifest['arguments']['rounds'] == 8 and manifest['arguments']['target_ms'] == 250.0,
      'eight-round, 250-ms confirmation design is recorded')
check(manifest['arguments']['cases'] == 'all' and manifest['arguments']['kernels'] == 'hit,component_hit',
      'all cases and both controls were preselected')
check(manifest['arguments']['cpu'] == manifest['environment']['timed_cpu_affinity'] == 3,
      'confirmation declares CPU3 affinity')
check(manifest['sources'] == reference_manifest['sources'], 'all source digests match the original full cohort')
paths = {'candidate-PlayerTheme.swift': 'Sources/IlliquidApp/UI/PlayerTheme.swift',
         'baseline-PlayerTheme.swift': 'Benchmarks/AdaptiveTextPaletteReuse/baseline/PlayerTheme.swift',
         'Driver.swift': 'Benchmarks/AdaptiveTextPaletteReuse/Driver.swift',
         'LinuxColor.swift': 'Benchmarks/AdaptiveTextPaletteReuse/LinuxColor.swift',
         'run.py': 'Benchmarks/AdaptiveTextPaletteReuse/run.py',
         **{name: data['original'] for name, data in manifest['shared_support'].items()}}
source_receipts = {}
for name, digest in manifest['sources'].items():
    data = (OUT / 'sources' / name).read_bytes()
    check(sha(data) == digest, 'source matches confirmation manifest: ' + name)
    check(data == (REFERENCE / 'sources' / name).read_bytes(), 'source bytes equal original full cohort: ' + name)
    if name in paths:
        check(data == git('show', f'{PUBLISHED}:{paths[name]}'), 'source equals published Git blob: ' + name)
    if name in manifest['shared_support']:
        check(data == git('show', f'{BASE}:{paths[name]}'), 'common source equals historical baseline: ' + name)
    source_receipts[name] = {'sha256': digest, 'matches_original_cohort': True,
                             'matches_published_git_blob': name in paths}

inventory = read('cases.json')
check([case['name'] for case in inventory] == CASES, 'exact intended 24-case inventory is present')
measurements, pairs, summary, commands = (read(name) for name in
    ['measurements.json', 'pairs.json', 'summary.json', 'commands.json'])
check(len(measurements) == 768, 'all768 measured observations are present')
check(len(pairs) == 384, 'all384 paired results are present')
check(len(summary) == 48, 'all48 workload summaries are present')
check(len(commands) == 14 + 48 + 768 == 830, 'all830 expected provenance, calibration, and measurement commands are present')
check(all(command['returncode'] == 0 for command in commands), 'all830 commands exited successfully')
check(all((OUT / command['stdout']).is_file() and (OUT / command['stderr']).is_file() for command in commands),
      'all command output and error logs are retained')
command_outputs = {command['stdout']: command for command in commands}
check(len(command_outputs) == len(commands), 'command log paths are unique')
indexed = {(row['case'], row['kernel'], row['round'], row['variant']): row for row in measurements}
check(len(indexed) == 768 and set(indexed) == set(itertools.product(CASES, KERNELS, range(1,9), ['baseline','candidate'])),
      'observation Cartesian coverage is complete without duplicates')
workloads = list(itertools.product(CASES, KERNELS))
expected_command_order = []
for round_number in range(1,9):
    offset = (round_number - 1) % len(workloads)
    order = ['baseline','candidate'] if round_number % 2 else ['candidate','baseline']
    for case, kernel in workloads[offset:] + workloads[:offset]:
        for variant in order:
            expected_command_order.append(f'timings/r{round_number:02d}-{case}-{kernel}-{variant}.json')
actual_command_order = [command['stdout'] for command in commands if command['stdout'].startswith('timings/r')]
check(actual_command_order == expected_command_order, 'actual executed command sequence alternatesAB/BA and rotates workload order as declared')

raw_hashes = {}
for key, row in indexed.items():
    case, kernel, round_number, variant = key
    order = ['baseline','candidate'] if round_number % 2 else ['candidate','baseline']
    check(row['order'] == order, f'order metadata is correct: {key}')
    check(isinstance(row['iterations'],int) and row['iterations'] > 0, f'positive iteration count: {key}')
    check(row['warmup_iterations'] == max(1,min(64,row['iterations']//10)), f'correct warmup count: {key}')
    for elapsed, per_operation in [('elapsed_ns','ns_per_operation'),('cpu_elapsed_ns','cpu_ns_per_operation')]:
        check(row[elapsed] > 0 and math.isfinite(row[elapsed]) and close(row[per_operation],row[elapsed]/row['iterations']),
              f'elapsed/per-operation timings recompute: {key}/{elapsed}')
    check(row['generation'] == 0 and row['revision'] == (1 if kernel == 'hit' else row['iterations']+1),
          f'cache counters prove intended control path: {key}')
    filename = f'timings/r{round_number:02d}-{case}-{kernel}-{variant}.json'
    raw = read(filename)
    check(all(row.get(field) == value for field,value in raw.items()), f'aggregate matches raw processJSON: {key}')
    command = command_outputs[filename]
    check(command['argv'][1:] == ['time',case,kernel,str(row['iterations']),str(row['warmup_iterations'])]
          and Path(command['argv'][0]).name == variant, f'executed command matches measured workload: {key}')
    check(command['cpu_affinity'] == 3, f'process affinity equalsCPU3: {key}')
    raw_hashes[filename] = sha((OUT/filename).read_bytes())

pair_index = {(row['case'],row['kernel'],row['round']):row for row in pairs}
check(len(pair_index) == 384, 'paired results are unique')
recomputed_pairs = {}
for case,kernel,round_number in itertools.product(CASES,KERNELS,range(1,9)):
    a,b = (indexed[case,kernel,round_number,variant] for variant in ['baseline','candidate'])
    for invariant in ['checksum','warmup_checksum','revision','generation','iterations','warmup_iterations']:
        check(a[invariant] == b[invariant], f'pair invariant is exact: {case}/{kernel}/{round_number}/{invariant}')
    recalc = {'wall_reduction_percent':100*(1-b['ns_per_operation']/a['ns_per_operation']),
              'cpu_reduction_percent':100*(1-b['cpu_ns_per_operation']/a['cpu_ns_per_operation'])}
    for field,value in recalc.items():
        check(close(value,pair_index[case,kernel,round_number][field]),
              f'paired reduction recomputes: {case}/{kernel}/{round_number}/{field}')
    recomputed_pairs[case,kernel,round_number] = recalc

summary_index = {(row['case'],row['kernel']):row for row in summary}
check(len(summary_index) == 48, 'summary rows are unique')
reference_index = {(row['case'],row['kernel']):row for row in read('summary.json',REFERENCE)}
recomputed_rows = []
for case,kernel in workloads:
    iters = {indexed[case,kernel,rnd,variant]['iterations'] for rnd in range(1,9) for variant in ['baseline','candidate']}
    check(len(iters) == 1, f'iteration count remains fixed across all rounds and variants: {case}/{kernel}')
    row = {'case':case,'kernel':kernel,'pairs':8,'iterations_per_process':iters.pop()}
    for clock,metric in [('wall','ns_per_operation'),('cpu','cpu_ns_per_operation')]:
        values=[recomputed_pairs[case,kernel,rnd][clock+'_reduction_percent'] for rnd in range(1,9)]
        row[f'median_paired_{clock}_reduction_percent']=statistics.median(values)
        row[f'candidate_faster_{clock}_pairs']=sum(value>0 for value in values)
        for variant in ['baseline','candidate']:
            field=f'{variant}_median_'+('cpu_ns_per_operation' if clock=='cpu' else 'ns_per_operation')
            row[field]=statistics.median(indexed[case,kernel,rnd,variant][metric] for rnd in range(1,9))
    for field,value in row.items():
        expected=summary_index[case,kernel][field]
        check(close(value,expected) if isinstance(value,(float,int)) else value==expected,
              f'summary independently recomputes: {case}/{kernel}/{field}')
    row['paired_cpu_changes_percent']=[recomputed_pairs[case,kernel,rnd]['cpu_reduction_percent'] for rnd in range(1,9)]
    row['absolute_cpu_median_delta_ns']=row['candidate_median_cpu_ns_per_operation']-row['baseline_median_cpu_ns_per_operation']
    row['cpu_process_duration_ms_range']=[min(indexed[case,kernel,rnd,variant]['cpu_elapsed_ns']/1e6 for rnd in range(1,9) for variant in ['baseline','candidate']),
                                        max(indexed[case,kernel,rnd,variant]['cpu_elapsed_ns']/1e6 for rnd in range(1,9) for variant in ['baseline','candidate'])]
    row['original_median_paired_cpu_reduction_percent']=reference_index[case,kernel]['median_paired_cpu_reduction_percent']
    row['original_candidate_faster_cpu_pairs']=reference_index[case,kernel]['candidate_faster_cpu_pairs']
    recomputed_rows.append(row)

receipts={variant:(OUT/f'{variant}-receipts.jsonl').read_bytes() for variant in ['baseline','candidate']}
differential=read('differential.json')
check(receipts['baseline']==receipts['candidate'], 'complete confirmation receipt streams match exactly')
check(receipts['baseline']==(REFERENCE/'baseline-receipts.jsonl').read_bytes(),
      'confirmation semantic receipts exactly equal original cohort receipts')
check(len(receipts['baseline'].splitlines())==differential['receipt_count']==5382,
      'all5382 semantic receipts are present')
check(all(sha(data)==differential['sha256'][variant] for variant,data in receipts.items()),
      'recorded semantic receipt hashes independently match')

binary_observation=None
if args.binary_receipt:
    binary_observation=json.loads(args.binary_receipt.read_text())
    check(set(binary_observation['binary_hashes'])==set(manifest['binary_sha256']),
          'independent binary-hash observation includes all four compiled artifacts')
    for name,item in binary_observation['binary_hashes'].items():
        check(item.get('matches_manifest') and item['sha256']==manifest['binary_sha256'][name],
              'contemporaneously observed binary matches cohort manifest: '+name)

kernel_summaries={}
for kernel in KERNELS:
    rows=[row for row in recomputed_rows if row['kernel']==kernel]
    values=[row['median_paired_cpu_reduction_percent'] for row in rows]
    kernel_summaries[kernel]={
        'workloads':len(rows),'positive_cpu_medians':sum(value>0 for value in values),
        'median_paired_cpu_reduction_range_percent':[min(values),max(values)],
        'candidate_faster_cpu_pairs':sum(row['candidate_faster_cpu_pairs'] for row in rows),
        'total_pairs':len(rows)*8,
        'negative_cpu_median_workloads':[row['case'] for row in rows if row['median_paired_cpu_reduction_percent']<0],
        'candidate_slower_in_every_pair':[row['case'] for row in rows if row['candidate_faster_cpu_pairs']==0],
        'negative_median_in_both_cohorts':[row['case'] for row in rows if row['median_paired_cpu_reduction_percent']<0 and row['original_median_paired_cpu_reduction_percent']<0],
    }

original_concerns={('local9-dark-rainbow','hit'),('overall96-bright-mono','component_hit'),
                   ('leading32-saturated-rainbow','component_hit'),('local9-midgray-rainbow','component_hit'),
                   ('bottom24-varied-rainbow','component_hit'),('overall96-dark-mono','component_hit')}
audit={
    'result':'integrity, source correspondence, exact outputs, and timing arithmetic verified; interpret control timing with original cohort',
    'input_directory':str(OUT),'original_cohort_directory':str(REFERENCE),
    'published_commit':PUBLISHED,'checkout':str(ROOT),
    'counts':{'cases':24,'kernels':2,'rounds':8,'variants':2,'observations':768,'pairs':384,'summaries':48,'commands':830,'semantic_receipts':5382},
    'number_of_successful_assertions':len(assertions),
    'source_checks':source_receipts,'binary_observation':binary_observation,
    'kernel_summaries':kernel_summaries,'recomputed_summaries':recomputed_rows,
    'original_concerning_cases':[row for row in recomputed_rows if (row['case'],row['kernel']) in original_concerns],
    'audited_file_sha256':{name:sha((OUT/name).read_bytes()) for name in
        ['manifest.json','commands.json','cases.json','measurements.json','pairs.json','summary.json',
         'differential.json','baseline-receipts.jsonl','candidate-receipts.jsonl']},
    'raw_process_json_sha256':raw_hashes,
    'limitations':[
        'Independent fresh-process comparisons on a shared Linux host with a numeric Color shim. No native macOS, view-rendering, playback, energy, or whole-player conclusions.',
        'Confirmation changes CPU affinity from0 to3 and duration target from100ms to250ms. Sources and algorithms are identical, but this is not a controlled single-variable hardware experiment.',
        'No individual observation or workload was removed. Timing controls must be interpreted together with the first cohort rather than selectively replacing inconvenient results.',
    ],
}
DEST.write_text(json.dumps(audit,indent=2,sort_keys=True)+'\n')
print('AUDIT',DEST,'ASSERTIONS',len(assertions))
print(json.dumps(kernel_summaries,indent=2))
for row in sorted(recomputed_rows,key=lambda row:(row['kernel'],row['median_paired_cpu_reduction_percent'])):
    print(row['kernel'],row['case'],'original',round(row['original_median_paired_cpu_reduction_percent'],2),
          'confirmation',round(row['median_paired_cpu_reduction_percent'],2),
          'cpu_ns',round(row['baseline_median_cpu_ns_per_operation'],2),round(row['candidate_median_cpu_ns_per_operation'],2),
          'wins',row['candidate_faster_cpu_pairs'],'pairs',','.join(f'{x:.2f}' for x in row['paired_cpu_changes_percent']))
