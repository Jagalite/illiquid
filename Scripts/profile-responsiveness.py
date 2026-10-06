#!/usr/bin/env python3
"""Isolated app preview, navigation and short-soak receipts.
UI commands enter the real hover handler; draw witnesses are not scan-out evidence.
Run sequentially, with warm OS file pages. Never launches the installed app.
"""
import argparse, hashlib, importlib.util, json, math, plistlib, statistics, subprocess, time
from pathlib import Path

spec = importlib.util.spec_from_file_location('lifecycle', Path(__file__).with_name('profile-lifecycle.py'))
lifecycle = importlib.util.module_from_spec(spec); spec.loader.exec_module(lifecycle)

def distribution(values):
    values = sorted(values)
    return {} if not values else dict(n=len(values), median_ms=statistics.median(values),
        p95_ms=values[math.ceil(len(values)*.95)-1], max_ms=values[-1])

def screenshot(run, name):
    windows = [w for w in lifecycle.resources.windows(run.process.pid)
               if w.get('kCGWindowIsOnscreen') and w.get('kCGWindowLayer') == 0
               and w['kCGWindowBounds']['Width'] > 500]
    if windows:
        result = subprocess.run(['screencapture', '-x', '-o', '-l', str(windows[0]['kCGWindowNumber']),
                                 str(run.directory / name)], capture_output=True)
        return {'exit': result.returncode, 'error': result.stderr.decode(errors='replace')}
    return {'error': 'no visible window'}

def open_media(run, fixture):
    offset = len(run.text()); start = time.monotonic()
    run.command('open', source=fixture)
    run.wait_line(lambda line: 'phase=first-frame-submitted ' in line, offset=offset)
    elapsed = (time.monotonic()-start)*1000
    run.command('pause')
    return elapsed

def previews(run, fixture):
    run.result['open_to_submit_observed_ms'] = open_media(run, fixture)
    time.sleep(.3)
    run.result['preview_requests'] = []
    for playing in [False, True]:
        offset=len(run.text()); run.command('clear-previews')
        run.wait_line(lambda line: 'phase=preview-cache-cleared ' in line, offset=offset)
        run.command('seek-exact', 0)
        time.sleep(.2)
        if playing: run.command('play')
        clock_before=float(run.command('snapshot')['response']['renderer-time'])
        usage_start=lifecycle.resources.usage(run.process.pid); start=time.monotonic()
        for target in [1.5, 2, 2.5, 4, 1.5, 8, 2]:
            run.command('hover-preview', -1)
            time.sleep(.1)
            offset=len(run.text()); call_start=time.monotonic()
            run.command('hover-preview', target)
            line=run.wait_line(lambda s: 'phase=preview-hover-' in s and '.begin ' in s, offset=offset)
            request_id=lifecycle.fields(line)['phase'].split('-')[-1].split('.')[0]
            endpoint=run.wait_line(lambda s: any(f'phase={phase}-{request_id}.end ' in s for phase in
                ['preview-view-draw','preview-unavailable']), offset=offset, timeout=10)
            drawn='preview-view-draw' in endpoint
            if not drawn: raise RuntimeError(f'Preview unavailable at {target}, playing={playing}')
            observed=(time.monotonic()-call_start)*1000
            # Keep the pointer stationary long enough for an approximate resident image
            # to refine before moving on. Retain both cache and exact-image stages.
            time.sleep(.4)
            rows=[lifecycle.fields(s) for s in run.text()[offset:].splitlines()
                  if s.startswith('[lifecycle-performance]') and f'-{request_id}.end ' in s]
            run.result['preview_requests'].append(dict(target=target, playing=playing, drawn=drawn,
                first_witness_observed_ms=observed, stages=rows))
        seconds=time.monotonic()-start; final=lifecycle.resources.usage(run.process.pid)
        run.result.setdefault('hover_workloads',[]).append(dict(playing=playing, wall_s=seconds,
            cpu_percent_one_core=(final['cpu_s']-usage_start['cpu_s'])/seconds*100,
            end_footprint_mib=final['footprint_mib'], snapshot=run.command('snapshot')['response']))
        clock_after=float(run.result['hover_workloads'][-1]['snapshot']['renderer-time'])
        advance=clock_after-clock_before
        run.result['hover_workloads'][-1]['renderer_advance_s']=advance
        if playing and not .8*seconds < advance < 1.2*seconds: raise RuntimeError('Playback clock did not track hover workload')
        if not playing and abs(advance)>.1: raise RuntimeError('Paused clock advanced during hover')
        run.command('pause')
    run.result['preview_screenshot']=screenshot(run,'preview.png')
    run.command('hover-preview',-1)
    run.result['seeks']=[run.command('seek-exact',target) for target in [18.5,2,18.5,2,18.5,2]]
    run.phase('paused-after-hover',seconds=4,playback=True)
    offset=len(run.text()); run.command('memory-pressure',2)
    run.wait_line(lambda line: 'phase=preview-memory-pressure-handled ' in line,offset=offset)
    run.phase('after-critical-cache-trim',seconds=3,playback=True)
    run.command('memory-pressure',0)
    run.command('hover-preview',1.5)
    time.sleep(.4)
    run.result['recovered_preview_screenshot']=screenshot(run,'preview-after-trim.png')

def navigation(run, count):
    # Let the asynchronous initial projection finish before measuring typing.
    run.wait_line(lambda line: 'phase=source-projection.end ' in line,timeout=60)
    run.result['queries']=[]
    for query in ['episode-9','episode-99',f'episode-{count-1}','']:
        offset=len(run.text()); run.command('source-query',source=query)
        line=run.wait_line(lambda s:'phase=source-projection.end ' in s,offset=offset,timeout=60)
        run.result['queries'].append(dict(query=query,projection=lifecycle.fields(line)))
    run.result['sidebar_screenshot']=screenshot(run,'sidebar.png')
    run.phase('large-sidebar-idle',seconds=3)

def soak(run, fixtures, cycles, memory_map=False):
    run.result['cycles']=[]
    for cycle in range(cycles):
        fixture=fixtures[cycle%len(fixtures)]
        elapsed=open_media(run,fixture)
        run.command('seek-exact',1.5); run.command('play')
        run.phase(f'cycle-{cycle}-playing',seconds=5,playback=True)
        run.command('pause'); run.command('hover-preview',8)
        time.sleep(.6);run.command('hover-preview',-1)
        run.command('close-window');run.wait_window(False)
        run.phase(f'cycle-{cycle}-closed',seconds=3)
        run.result['cycles'].append(dict(cycle=cycle,fixture=str(fixture),open_to_submit_observed_ms=elapsed,
            usage=lifecycle.resources.usage(run.process.pid)))
        run.command('reopen-window');run.wait_window(True)
    run.phase('final-idle',seconds=10)
    if memory_map:
        with (run.directory/'vmmap-summary.txt').open('w') as output:
            result=subprocess.run(['vmmap','-summary',str(run.process.pid)],stdout=output,stderr=subprocess.STDOUT,timeout=60)
            run.result['vmmap_exit_code']=result.returncode
    offset=len(run.text());run.command('memory-pressure',2)
    run.wait_line(lambda line:'phase=preview-memory-pressure-handled ' in line,offset=offset)
    run.phase('final-trimmed-idle',seconds=5)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--fixture',action='append',type=Path,default=[])
    parser.add_argument('--mode',choices=['previews','navigation','soak'],default='previews')
    parser.add_argument('--runs',type=int,default=3)
    parser.add_argument('--source-count',type=int,default=10000)
    parser.add_argument('--cycles',type=int,default=12)
    parser.add_argument('--memory-map',action='store_true',help='Capture vmmap after the final idle phase of a soak')
    parser.add_argument('--disable-scroll-restoration',action='store_true',help='Benchmark the sidebar without SwiftUI scroll targets')
    args=parser.parse_args()
    args.app=args.app.resolve(strict=True);args.fixture=[f.resolve(strict=True) for f in args.fixture]
    if plistlib.loads((args.app/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']!=lifecycle.DOMAIN:
        parser.error('requires isolated benchmark bundle')
    if args.mode!='navigation' and not args.fixture:parser.error('fixture required')
    if args.runs<1 or args.cycles<1 or not 1<=args.source_count<=100000:parser.error('invalid workload limits')
    args.output.mkdir(parents=True,exist_ok=False)
    summary=dict(mode=args.mode,runs=[],script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        protocol={'runs':args.runs,'cycles':args.cycles,'source_count':args.source_count,'scroll_restoration':not args.disable_scroll_restoration},
        binary_sha256=hashlib.sha256((args.app/'Contents/MacOS/Illiquid').read_bytes()).hexdigest(),
        fixtures={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in args.fixture},
        limitations=['command injection into real hover handler; not physical input',
                     'view drawing witness is not compositor or scan-out timing',
                     'warm OS file pages; process CPU excludes GPU and WindowServer',
                     'short soak does not establish absence of long-session leaks'])
    try:
        for repeat in range(args.runs):
            fixtures=args.fixture if args.mode=='previews' else [None]
            for index,fixture in enumerate(fixtures):
                run=lifecycle.Run(args.app,args.output/f'{repeat}-{index}',0,True,
                    source_count=args.source_count if args.mode=='navigation' else 0,
                    environment_overrides={'SUPERPLAYR_BENCHMARK_HIDE_SIDEBAR':'0' if args.mode=='navigation' else '1',
                        'SUPERPLAYR_BENCHMARK_HEARTBEAT':'0' if args.mode=='soak' else '1',
                        'SUPERPLAYR_BENCHMARK_SCROLL_RESTORATION':'0' if args.disable_scroll_restoration else '1'})
                try:
                    if args.mode=='previews':previews(run,fixture)
                    elif args.mode=='navigation':navigation(run,args.source_count)
                    else:soak(run,args.fixture,args.cycles,args.memory_map)
                    result=run.finish();summary['runs'].append(result)
                    print(f'{repeat+1} {fixture or args.mode}: complete',flush=True)
                except BaseException as error:
                    run.result['failure']=repr(error)
                    run.result['failure_screenshot']=screenshot(run,'failure.png')
                    (run.directory/'failure.json').write_text(json.dumps(run.result,indent=2))
                    raise
                finally:run.cleanup()
                (args.output/'summary.json').write_text(json.dumps(summary,indent=2))
    except BaseException as error:
        summary['failure']=repr(error);(args.output/'summary.json').write_text(json.dumps(summary,indent=2));raise

if __name__=='__main__':main()
