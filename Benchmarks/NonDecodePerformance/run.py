#!/usr/bin/env python3
"""Reproduce Illiquid non-decoding tests/microbenchmarks. Never launches the app.

Ranking uses exact production sources. Cache logic uses explicit platform doubles,
NOT macOS integration. Opt-in Linux/glibc allocation requests are cumulative
traffic, NOT live heap, RSS, physical footprint, pixel buffers or GPU memory.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

POLICY = Path('Sources/IlliquidCore/Player/ThumbnailPolicy.swift')
CACHE = Path('Sources/IlliquidNativePlayback/Media/NativeThumbnailCache.swift')
PROBES = Path('Sources/IlliquidCore/Utilities/NonDecodePerformance.swift')
COMMIT = '854f8365750a0e4f046ab7015e01ca7a138ada40'
EXPECTED = {'ThumbnailPolicy.swift': 'e06088b51837491b6ff5975469453f34205020d8',
            'NativeThumbnailCache.swift': 'c97deee800b964e44ac02aaceb2ecd590770e41b'}
FLAGS = ['-O', '-swift-version', '6', '-warnings-as-errors']


def blob(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()


def main() -> None:
    here = Path(__file__).resolve().parent
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate-root', type=Path, default=here.parents[1])
    p.add_argument('--baseline', type=Path, default=here/'baseline')
    p.add_argument('--output', type=Path, required=True, help='New or empty directory')
    p.add_argument('--repeats', type=int, default=7)
    p.add_argument('--allocations', action='store_true')
    p.add_argument('--tests-only', action='store_true')
    p.add_argument('--swiftc', default='swiftc')
    args = p.parse_args()
    if not 1 <= args.repeats <= 100: p.error('--repeats must be 1..100')
    if args.allocations and (sys.platform != 'linux' or platform.libc_ver()[0] != 'glibc'):
        p.error('--allocations requires Linux/glibc; use Instruments on macOS')
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()): p.error('--output must be empty; evidence is never overwritten')
    out.mkdir(parents=True, exist_ok=True)
    build = out/'build'; build.mkdir()
    root = args.candidate_root.resolve(); baseline = args.baseline.resolve()
    original = {f: baseline/f if (baseline/f).exists() else baseline/f.name for f in (POLICY, CACHE)}
    for f in original.values():
        if blob(f) != EXPECTED[f.name]: raise RuntimeError(f'Original blob verification failed: {f}')

    def run(cmd: list, env: dict | None = None, timeout: int = 120) -> str:
        cmd = [str(c) for c in cmd]
        started = time.time()
        result = subprocess.run(cmd, text=True, capture_output=True, env=env, timeout=timeout)
        with (out/'commands.jsonl').open('a') as f:
            f.write(json.dumps(dict(command=cmd,started_unix=started,returncode=result.returncode,
                                    stdout=result.stdout,stderr=result.stderr))+'\n')
        if result.returncode: raise RuntimeError(f'Command failed: {cmd}\n{result.stderr}')
        return result.stdout

    def compile_to(name: str, sources: list, extras: list | None = None) -> Path:
        dest = build/name
        run([args.swiftc,*FLAGS,*(extras or []),*sources,'-o',dest])
        return dest

    cpu = platform.processor()
    if Path('/proc/cpuinfo').exists():
        cpu = next((line.split(':',1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
                    if line.startswith('model name')),cpu)
    inputs = list(original.values())+[root/f for f in (POLICY,CACHE,PROBES)]
    inputs += list(here.glob('*.swift'))+[Path(__file__).resolve(),here/'allocmeter.c']
    scope = 'Exact cache actor body with platform doubles, NOT macOS integration'
    manifest = dict(repository='Jagalite/illiquid',baseline_commit=COMMIT,platform=platform.platform(),cpu=cpu,
        python=sys.version,swift=run([args.swiftc,'--version']).strip(),compiler_flags=FLAGS,repeats=args.repeats,
        cache_test_scope=scope,instrumentation='Production signposts disabled in standalone executables',
        source_hashes={str(f):dict(sha256=hashlib.sha256(f.read_bytes()).hexdigest(),git_blob=blob(f)) for f in inputs})
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    legacy = original[POLICY].read_text()
    for name in ['ThumbnailPreferences','ThumbnailPolicy','ThumbnailCacheUsage']:
        legacy = legacy.replace(name,'Legacy'+name)
    lp = build/'LegacyPolicy.swift'; lp.write_text(legacy)
    test = compile_to('policy-tests',[root/POLICY,lp,here/'PolicyHarness.swift'],['-D','DIFFERENTIAL'])
    policy_test = json.loads(run([test]))
    cache_bin, policy_bin, traces, checks = {},{},{},{}
    for version in ['baseline','candidate']:
        policy = original[POLICY] if version == 'baseline' else root/POLICY
        cache = original[CACHE] if version == 'baseline' else root/CACHE
        text = cache.read_text()
        for module in ['CoreGraphics','CryptoKit','IlliquidCore']: text=text.replace(f'import {module}\n','')
        copy = build/f'Cache-{version}.swift'; copy.write_text(text)
        sources = [policy,copy,here/'CacheStubs.swift',here/'CacheHarness.swift']
        if version == 'candidate': sources.append(root/PROBES)
        binary = compile_to(f'cache-{version}',sources,['-D','CANDIDATE'] if version == 'candidate' else [])
        cache_bin[version]=binary
        output=run([binary]); (out/f'cache-{version}-tests.txt').write_text(output)
        lines=output.splitlines(); checks[version]=int(lines[-1].split('=')[1]); traces[version]=lines[:-1]
        if not args.tests_only: policy_bin[version]=compile_to(f'policy-{version}',[policy,here/'PolicyHarness.swift'])
    if traces['baseline'] != traces['candidate']: raise RuntimeError('Cache differential trace mismatch')
    receipts=dict(policy=policy_test,cache=dict(checks=checks,identical_differential_trace_rows=len(traces['candidate']),
        trace_sha256=hashlib.sha256('\n'.join(traces['candidate']).encode()).hexdigest(),passed=True,scope=scope))
    (out/'tests.json').write_text(json.dumps(receipts,indent=2)+'\n'); print(json.dumps(receipts),flush=True)
    if args.tests_only: return
    rows=[]
    def record(row: dict) -> None:
        rows.append(row)
        with (out/'measurements.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')

    # Fresh processes, alternating baseline/candidate order each round. Fixtures
    # and two warmups excluded from ranking timings. No global cache purges.
    for count in [32,256,2048]:
        for exclusions in [0,16,128]:
            iterations=10 if count == 32 else 3 if count == 256 else 1
            for rep in range(args.repeats):
                sums=[]
                for version in (['baseline','candidate'] if rep%2 == 0 else ['candidate','baseline']):
                    row=json.loads(run([policy_bin[version],count,exclusions,iterations])); sums.append(row['checksum'])
                    record(dict(row,experiment='ranking',version=version,repetition=rep))
                if len(set(sums)) != 1: raise RuntimeError('Ranking checksum mismatch')
            print(f'Completed ranking n={count}, exclusions={exclusions}',flush=True)
    for mode in ['hex','admission']:
        for rep in range(args.repeats):
            sums=[]
            for version in (['baseline','candidate'] if rep%2 == 0 else ['candidate','baseline']):
                row=json.loads(run([cache_bin[version],'benchmark',mode,10000])); sums.append(row['checksum'])
                record(dict(row,experiment=mode,version=version,repetition=rep))
            if len(set(sums)) != 1: raise RuntimeError('Cache microbenchmark checksum mismatch')
        print(f'Completed {mode}',flush=True)
    if args.allocations:
        run(['cc','-O2','-shared','-fPIC',here/'allocmeter.c','-o',build/'liballocmeter.so'])
        text=(here/'PolicyHarness.swift').read_text()
        declarations=''.join(f'@_silgen_name("{symbol}") func {swift}()'+return_type+'\n' for symbol,swift,return_type in
            [('meter_begin','meterBegin',''),('meter_end','meterEnd',''),
             ('meter_requests','meterRequests',' -> UInt64'),('meter_bytes','meterBytes',' -> UInt64')])
        text=text.replace('import Foundation\n','import Foundation\n'+declarations,1)
        text=text.replace('let start = DispatchTime.now().uptimeNanoseconds','meterBegin()\n        let start = DispatchTime.now().uptimeNanoseconds')
        text=text.replace('        print("{\\"count',
            '        meterEnd()\n        print("{\\"allocation_requests\\":\\(meterRequests()),\\"requested_bytes\\":\\(meterBytes())}")\n        print("{\\"count')
        hp=build/'PolicyAllocHarness.swift'; hp.write_text(text)
        metered={v:compile_to(f'policy-alloc-{v}',[original[POLICY] if v=='baseline' else root/POLICY,hp],
                              ['-L',str(build),'-lallocmeter']) for v in ['baseline','candidate']}
        env=os.environ.copy(); env['LD_LIBRARY_PATH']=str(build); env['LD_PRELOAD']=str(build/'liballocmeter.so')
        for exclusions in [0,16,128]:
            for rep in range(args.repeats):
                sums=[]
                for version in (['baseline','candidate'] if rep%2 == 0 else ['candidate','baseline']):
                    lines=run([metered[version],2048,exclusions,1],env=env).splitlines()
                    allocation=json.loads(lines[0]); timing=json.loads(lines[1]); sums.append(timing['checksum'])
                    record(dict(timing,**allocation,experiment='allocation_traffic',version=version,repetition=rep))
                if len(set(sums)) != 1: raise RuntimeError('Allocation checksum mismatch')
            print(f'Completed allocation traffic exclusions={exclusions}',flush=True)
    groups={}
    for row in rows:
        key=(row['experiment'],row.get('count'),row.get('exclusions'),row['version'])
        groups.setdefault(key,[]).append(row)
    summaries=[]
    for key,group in groups.items():
        summary=dict(experiment=key[0],count=key[1],exclusions=key[2],version=key[3],samples=len(group))
        for metric in ['ms_per_call','allocation_requests','requested_bytes']:
            values=[row[metric] for row in group if metric in row]
            if values: summary[metric]=dict(median=statistics.median(values),min=min(values),max=max(values))
        summaries.append(summary)
    (out/'summary.json').write_text(json.dumps(summaries,indent=2)+'\n')
    print(f'Saved {len(rows)} observations to {out}',flush=True)

if __name__ == '__main__':
    try: main()
    except (OSError,RuntimeError,subprocess.SubprocessError,ValueError) as error:
        print(f'ERROR: {error}',file=sys.stderr); sys.exit(1)
