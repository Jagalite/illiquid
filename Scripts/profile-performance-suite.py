#!/usr/bin/env python3
"""Serial, alternating native-player regression cohort. Uses isolated bundles only.
Run on the same quiet Mac; measures process CPU and renderer readback, not energy
or physical display scanout. A passing gate is a bounded workload result.
"""
import argparse
import hashlib
import json
import math
import os
import platform
import plistlib
import statistics
import subprocess
import sys
from pathlib import Path

DOMAIN = 'com.example.SuperplayrBenchmark'
SCRIPTS = ('profile-performance-suite.py', 'profile-output-recovery.py',
           'profile-responsiveness.py', 'profile-lifecycle.py', 'profile-reference-player.py')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def number(value):
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError(f'Invalid measurement: {value!r}')
    return result


def metrics(receipt):
    if receipt.get('failure'):
        raise ValueError(f"Failed probe: {receipt['failure']}")
    run = receipt['run'] if receipt['mode'] == 'output' else receipt['runs'][0]
    if run['status'] != 'complete':
        raise ValueError('Incomplete probe')
    visibility = run.get('visibility_samples', [])
    if not visibility or any(sample['visible'] is not True for sample in visibility):
        raise ValueError('Missing or failed window visibility evidence')
    result = {'quit_ms': number(run['quit_process_exit_ms']),
              'launch_ms': number(run['launch_configured_ms'])}
    if receipt['mode'] == 'output':
        seeks = run['displayed_seeks']
        if len(seeks) != 6 or any(s['readback']['displayed-current'] != 'yes' for s in seeks):
            raise ValueError('Missing displayed seek evidence')
        result['seek_ms'] = statistics.median(number(s['command_to_readback_ms']) for s in seeks)
        result['seek_max_ms'] = max(number(s['command_to_readback_ms']) for s in seeks)
        workloads = run['output_workloads']
        if [w['name'] for w in workloads] != ['steady', 'hover', 'resize']:
            raise ValueError('Missing output workload')
        for w in workloads:
            name = w['name']
            if w['before']['metrics-available'] != 'yes' or w['after']['metrics-available'] != 'yes':
                raise ValueError('Missing renderer counters')
            total = number(w['after']['total']) - number(w['before']['total'])
            if total <= 0 or number(w['seconds']) < 6:
                raise ValueError('Renderer or workload did not advance')
            result[name + '_cpu'] = number(w['cpu_percent_one_core'])
            result[name + '_mib'] = number(w['usage_after']['footprint_mib'])
            for counter in ['dropped', 'corrupted']:
                result[name + '_' + counter] = number(number(w['after'][counter]) - number(w['before'][counter]))
    elif receipt['mode'] == 'navigation':
        queries = run['queries']
        if len(queries) != 4 or queries[-1]['query'] != '':
            raise ValueError('Incomplete search sequence')
        result['clear_search_ms'] = number(queries[-1]['projection']['duration_ms'])
        result['search_ms'] = statistics.median(number(q['projection']['duration_ms']) for q in queries[:3])
        # Heartbeat reports only gaps above its threshold. An empty list is valid
        # only when the run contains timing evidence and the expected queries.
        if not run['timings']:
            raise ValueError('Missing heartbeat receipt')
        gaps = [number(t['duration_ms']) for t in run['timings'] if t['phase'] == 'main-queue-gap.end']
        result['main_queue_ms'] = max(gaps, default=0)
    else:
        raise ValueError('Unsupported probe mode')
    return result


def compare(records, minimum_runs=3):
    if minimum_runs < 3:
        raise ValueError('At least three repeats are required')
    cases = sorted({r['case'] for r in records})
    if not cases:
        raise ValueError('No measurements')
    checks = []
    for case in cases:
        cohorts = {label: [r['metrics'] for r in records if r['case'] == case and r['app'] == label]
                   for label in ('baseline', 'candidate')}
        a, b = cohorts.values()
        if len(a) != len(b) or len(a) < minimum_runs:
            raise ValueError(f'Incomplete cohort: {case}')
        keys = set(a[0])
        if not keys or any(set(row) != keys for row in a + b):
            raise ValueError(f'Mismatched measurements: {case}')
        for key in sorted(keys):
            av, bv = ([number(row[key]) for row in cohort] for cohort in (a, b))
            # Any corrupted frame fails qualification, including a bad baseline.
            if key.endswith('_corrupted'):
                base, candidate, limit = max(av), max(bv), 0
                passed = max(base, candidate) == 0
            elif key.endswith('_dropped'):
                base, candidate = max(av), max(bv)
                limit = base
                passed = candidate <= limit
            else:
                base, candidate = statistics.median(av), statistics.median(bv)
                absolute = 2 if key.endswith('_cpu') else 16 if key.endswith('_mib') else 25
                limit = max(base * 1.15, base + absolute)
                passed = candidate <= limit
            checks.append(dict(case=case, metric=key, baseline=base, candidate=candidate,
                               limit=limit, passed=passed, n=len(a)))
    return dict(passed=all(c['passed'] for c in checks), checks=checks,
                policy='median <= max(baseline * 1.15, baseline + 2 CPU points / 16 MiB / 25 ms); '
                       'maximum dropped frames cannot increase; no corrupted frames in either cohort')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-app', type=Path, required=True)
    parser.add_argument('--candidate-app', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, action='append', required=True,
                        help='Local video at least 20 seconds long; repeat for each codec')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--source-count', type=int, default=100000)
    args = parser.parse_args()
    if args.runs < 3 or not 1 <= args.source_count <= 100000:
        parser.error('Require at least three repeats and 1...100000 source items')
    apps = {'baseline': args.baseline_app.resolve(strict=True), 'candidate': args.candidate_app.resolve(strict=True)}
    for app in apps.values():
        if plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != DOMAIN:
            parser.error('Require isolated benchmark bundles')
    fixtures = [p.resolve(strict=True) for p in args.fixture]
    if len(set(fixtures)) != len(fixtures):
        parser.error('Duplicate fixture')
    scripts = Path(__file__).parent
    args.output.mkdir(parents=True, exist_ok=False)
    report = dict(schema=1, machine=platform.platform(), source_count=args.source_count,
                  prevents_idle_display_sleep=True,
                  scripts={name: digest(scripts / name) for name in SCRIPTS},
                  apps={name: dict(path=str(path), binary_sha256=digest(path / 'Contents/MacOS/Illiquid'))
                        for name, path in apps.items()},
                  fixtures={str(p): digest(p) for p in fixtures}, records=[])
    path = args.output / 'summary.json'
    # A player releases its own activity assertion when paused or closed. Keep
    # the display awake across those measurement boundaries too. This assertion
    # belongs only to this process; it does not alter system sleep preferences.
    awake = subprocess.Popen(['caffeinate', '-di', '-w', str(os.getpid())])
    try:
        cases = [('navigation', None)] + [(f'output-{i}', p) for i, p in enumerate(fixtures)]
        for repeat in range(args.runs):
            order = ['baseline', 'candidate'] if repeat % 2 == 0 else ['candidate', 'baseline']
            for case, fixture in cases:
                for label in order:
                    destination = args.output / f'{repeat + 1}-{case}-{label}'
                    script = 'profile-output-recovery.py' if fixture else 'profile-responsiveness.py'
                    command = [sys.executable, str(scripts / script), '--app', str(apps[label]),
                               '--output', str(destination), '--mode', 'output' if fixture else 'navigation']
                    command += ['--fixture', str(fixture)] if fixture else ['--runs', '1', '--source-count', str(args.source_count)]
                    subprocess.run(command, check=True)
                    receipt = json.loads((destination / 'summary.json').read_text())
                    if receipt['binary_sha256'] != report['apps'][label]['binary_sha256']:
                        raise ValueError('Binary changed during cohort')
                    if fixture and receipt['fixture_sha256'] != report['fixtures'][str(fixture)]:
                        raise ValueError('Fixture changed during cohort')
                    report['records'].append(dict(app=label, case=case, repeat=repeat,
                        receipt=str(destination / 'summary.json'), metrics=metrics(receipt)))
                    path.write_text(json.dumps(report, indent=2) + '\n')
                    print(f'{repeat + 1} {case} {label}: complete', flush=True)
        if any(digest(scripts / name) != value for name, value in report['scripts'].items()):
            raise ValueError('Harness changed during cohort')
        report['comparison'] = compare(report['records'], args.runs)
    except BaseException as error:
        report['failure'] = repr(error)
        raise
    finally:
        awake.terminate()
        awake.wait(timeout=5)
        path.write_text(json.dumps(report, indent=2) + '\n')
    return 0 if report['comparison']['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
