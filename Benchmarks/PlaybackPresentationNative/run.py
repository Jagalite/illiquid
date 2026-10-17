#!/usr/bin/env python3
"""Native CoreMedia component benchmark. No app data or display is touched."""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rounds', type=int, default=7)
    p.add_argument('--frames', type=int, default=10000)
    a = p.parse_args()
    if platform.system() != 'Darwin':
        p.error('Requires macOS CoreMedia/CoreVideo; not a Linux adapter.')
    if not 3 <= a.rounds <= 21 or not 100 <= a.frames <= 100000:
        p.error('Invalid rounds/frames.')
    if a.output.exists():
        p.error('Output must not already exist.')
    a.output.mkdir(parents=True)
    source = Path(__file__).with_name('FormatProbe.swift')
    binary = a.output / 'format-probe'
    commands = []
    def execute(command, timeout=120):
        r = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        commands.append({'command': [str(x) for x in command], 'exit': r.returncode,
                         'stdout': r.stdout, 'stderr': r.stderr})
        (a.output/'commands.json').write_text(json.dumps(commands, indent=2)+'\n')
        if r.returncode:
            raise RuntimeError(f'Command failed: {command}\n{r.stderr}')
        return r.stdout.strip()
    environment = {'platform': platform.platform(), 'machine': platform.machine(),
                   'processor': platform.processor(), 'rounds': a.rounds, 'frames': a.frames,
                   'swift': execute(['xcrun', 'swiftc', '--version']),
                   'xcode': execute(['xcodebuild', '-version']),
                   'hardware': execute(['sysctl', 'hw.model', 'hw.memsize', 'hw.ncpu']),
                   'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
    (a.output/'environment.json').write_text(json.dumps(environment, indent=2)+'\n')
    execute(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-warnings-as-errors',
             '-parse-as-library', str(source), '-o', str(binary)])
    verification = json.loads(execute([str(binary), 'verify']))
    (a.output/'verification.json').write_text(json.dumps(verification, indent=2)+'\n')
    rows = []
    cases = ['420v', 'bgra', 'hdr10', 'alternating-color', 'reset90']
    for scenario in cases:
        for round_number in range(a.rounds):
            order = ['fresh', 'reuse'] if round_number % 2 == 0 else ['reuse', 'fresh']
            for variant in order:
                row = json.loads(execute([str(binary), scenario, variant, str(a.frames), 'measure']))
                assert row['scenario'] == scenario and row['reuse'] == (variant == 'reuse')
                assert row['format_creations'] + row['format_hits'] == a.frames
                if variant == 'fresh':
                    assert row['format_creations'] == a.frames
                row.update(round=round_number, variant=variant, ordinal=len(rows))
                rows.append(row)
                with (a.output/'measurements.jsonl').open('a') as f:
                    f.write(json.dumps(row, sort_keys=True)+'\n')
    expected = [(s, r, v) for s in cases for r in range(a.rounds)
                for v in (['fresh', 'reuse'] if r % 2 == 0 else ['reuse', 'fresh'])]
    assert [(r['scenario'], r['round'], r['variant']) for r in rows] == expected
    summary = []
    for scenario in cases:
        for variant in ['fresh', 'reuse']:
            subset = [r for r in rows if r['scenario'] == scenario and r['variant'] == variant]
            entry = {'scenario': scenario, 'variant': variant, 'samples': len(subset)}
            for metric in ['wall_ns', 'cpu_ns', 'format_creations', 'format_hits']:
                values = [r[metric] for r in subset]
                entry[metric] = {'median': statistics.median(values), 'min': min(values), 'max': max(values)}
            summary.append(entry)
    (a.output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    (a.output/'validation.json').write_text(json.dumps({
        'rows': len(rows), 'verified_order': True, 'verification': verification,
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'scope': 'Native format/sample creation only. No enqueue, decode, GUI, footprint or energy measurement.'
    }, indent=2)+'\n')
    print(json.dumps({'verification': verification, 'summary': summary}, indent=2))

if __name__ == '__main__':
    main()
