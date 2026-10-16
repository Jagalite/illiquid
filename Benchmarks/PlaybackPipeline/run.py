#!/usr/bin/env python3
"""Isolated, paired FFmpeg packet-ownership experiment. Never touches app data."""
from __future__ import annotations
import argparse, ctypes.util, hashlib, json, os, platform, shlex, shutil, statistics, subprocess, sys, time
from pathlib import Path
HERE = Path(__file__).resolve().parent

def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''): h.update(b)
    return h.hexdigest()

def command(args: list[str], log: Path, timeout: int = 120) -> str:
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    with log.open('a') as f:
        f.write(json.dumps({'command': args, 'returncode': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr}) + '\n')
    if p.returncode: raise RuntimeError(f"Command failed: {shlex.join(args)}\n{p.stderr}")
    return p.stdout

def main() -> None:
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('--output', type=Path, required=True)
    a.add_argument('--repeats', type=int, default=9)
    a.add_argument('--rounds', type=int, default=100)
    a.add_argument('--tests-only', action='store_true')
    opts = a.parse_args()
    if not 1 <= opts.repeats <= 99 or not 1 <= opts.rounds <= 10000: a.error('Invalid repeats/rounds')
    out = opts.output.resolve()
    if out.exists() and any(out.iterdir()): a.error('Output directory must be new or empty')
    out.mkdir(parents=True, exist_ok=True)
    log = out / 'commands.jsonl'
    if not shutil.which('ffmpeg'): a.error('ffmpeg executable required')
    flags: list[str] = []
    has_headers = False
    if shutil.which('pkg-config'):
        p = subprocess.run(['pkg-config', '--cflags', '--libs', 'libavformat', 'libavcodec', 'libavutil'], text=True, capture_output=True)
        if p.returncode == 0:
            flags = ['-DUSE_FFMPEG_HEADERS'] + shlex.split(p.stdout)
            has_headers = True
    if not flags:
        if sys.platform != 'linux': a.error('Install FFmpeg development packages and pkg-config')
        for lib in ['avformat', 'avcodec', 'avutil']:
            name = ctypes.util.find_library(lib)
            if not name or '/' in name: a.error(f'Cannot resolve {lib}')
            flags += ['-Wl,-l:' + name]
    binary = out / 'packet-ownership'
    command([os.environ.get('CC', 'cc'), '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror', str(HERE / 'packet_ownership.c'), *flags, '-o', str(binary)], log)
    fixture = out / 'fixtures'; fixture.mkdir()
    ff = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y']
    command(ff + ['-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=60', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '8', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '24', '-g', '120', '-bf', '3', '-threads:v', '2', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', str(fixture/'h264-aac.mp4')], log)
    command(ff + ['-i', str(fixture/'h264-aac.mp4'), '-c', 'copy', str(fixture/'h264-aac.mkv')], log)
    command(ff + ['-i', str(fixture/'h264-aac.mp4'), '-c:v', 'mpeg2video', '-q:v', '6', '-g', '30', '-bf', '2', '-threads:v', '2', '-c:a', 'mp2', '-b:a', '128k', '-f', 'mpegts', str(fixture/'mpeg2-mp2.ts')], log)
    variants = ['baseline', 'adopt', 'scratch']
    # Validate actual execution order, rather than assume nested loops alternate.
    schedule = [variants[i % 3:] + variants[:i % 3] for i in range(opts.repeats)]
    manifest = {'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'platform': platform.platform(), 'machine': platform.machine(), 'cpu': next((s.split(':',1)[1].strip() for s in Path('/proc/cpuinfo').read_text().splitlines() if s.startswith('model name')), None) if sys.platform == 'linux' else platform.processor(), 'compiler': command([os.environ.get('CC','cc'),'--version'],log), 'ffmpeg': command(['ffmpeg','-version'], log), 'uses_development_headers': has_headers, 'source_sha256': sha(HERE/'packet_ownership.c'), 'runner_sha256': sha(Path(__file__)), 'binary_sha256': sha(binary), 'fixtures': {p.name: {'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(fixture.iterdir())}, 'schedule': schedule, 'scope': 'Real FFmpeg C ownership kernel, not the Swift native runtime; warm OS-cache unpaced demux; no decoding/display'}
    (out/'manifest.json').write_text(json.dumps(manifest, indent=2))
    tests = []
    for media in sorted(fixture.iterdir()):
        for retention in [1, 96]:
            for seek in [None, 3.0]:
                outputs = []
                for mode in variants:
                    trace = out/f'{media.name}-{retention}-{seek}-{mode}.trace'
                    cmd = [str(binary), mode, str(media), '1', str(retention), str(trace)]
                    if seek is not None: cmd += [str(seek)]
                    row = json.loads(command(cmd, log))
                    outputs.append({'variant':mode, 'trace_sha256':sha(trace), 'trace_bytes':trace.stat().st_size, 'packets':row['packets'], 'header_allocations':row['explicit_header_allocations'], 'moves':row['explicit_moves']})
                    trace.unlink() # hashes and exact reproduction command retained
                assert len({x['trace_sha256'] for x in outputs}) == 1, outputs
                assert len({x['packets'] for x in outputs}) == 1, outputs
                n = outputs[0]['packets']
                assert [x['header_allocations'] for x in outputs] == [2*n+1,n+1,n+1]
                assert [x['moves'] for x in outputs] == [n,0,n]
                tests.append({'fixture':media.name,'retention':retention,'seek':seek,'matched':True,'outputs':outputs})
    (out/'tests.json').write_text(json.dumps({'scenarios':len(tests),'runs':len(tests)*3,'packet_and_side_data_receipts_match': True,'results':tests},indent=2))
    if opts.tests_only: print(json.dumps({'tests':len(tests),'runs':len(tests)*3})); return
    rows=[]
    for media in sorted(fixture.iterdir()):
        for round_index, order in enumerate(schedule):
            for order_index, mode in enumerate(order):
                row=json.loads(command([str(binary),mode,str(media),str(opts.rounds),'96'],log))
                row.update({'fixture':media.name,'repeat':round_index,'order':order_index})
                rows.append(row)
                with (out/'measurements.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
        print(json.dumps({'completed_fixture':media.name,'observations':len(rows)}),flush=True)
    groups=[]
    for media in sorted(fixture.iterdir()):
        for mode in variants:
            group=[r for r in rows if r['fixture']==media.name and r['variant']==mode]
            assert len(group)==opts.repeats
            group_summary={'fixture':media.name,'variant':mode,'n':len(group),'packets_per_process':group[0]['packets']}
            for metric in ['demux_wall_ns','demux_cpu_ns','open_probe_seek_ns','explicit_header_allocations','explicit_moves']:
                values=[r[metric] for r in group]
                group_summary[metric]={'median':statistics.median(values),'min':min(values),'max':max(values)}
            groups.append(group_summary)
    for media in manifest['fixtures']:
        for i,order in enumerate(schedule):
            actual=[r['variant'] for r in rows if r['fixture']==media and r['repeat']==i]
            assert actual==order
    (out/'summary.json').write_text(json.dumps({'observations':len(rows),'schedule_verified':True,'groups':groups},indent=2))
    print(json.dumps({'observations':len(rows),'tests':len(tests),'summary':str(out/'summary.json')}))
if __name__ == '__main__': main()
