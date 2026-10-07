#!/usr/bin/env python3
"""Renderer readback, interaction and owned disk-image reconnect qualification.
Uses the isolated benchmark bundle. Renderer output is not physical scanout.
"""
import argparse, importlib.util, json, plistlib, shutil, subprocess, tempfile, time
from pathlib import Path
spec=importlib.util.spec_from_file_location('responsiveness',Path(__file__).with_name('profile-responsiveness.py'))
responsive=importlib.util.module_from_spec(spec);spec.loader.exec_module(responsive)
lifecycle=responsive.lifecycle

def displayed(run, target=None, timeout=10):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        run.require_visible_window('displayed-frame-readback')
        sample=run.command('snapshot')['response']
        pts=sample.get('displayed-pts','unavailable')
        if sample.get('displayed-current')=='yes' and pts!='unavailable':
            if target is None or abs(float(pts)-target)<.15: return sample
        time.sleep(.01)
    raise RuntimeError(f'No current displayed frame for {target}: {sample}')

def output(run, fixture):
    responsive.open_media(run, fixture)
    displayed(run)
    run.result['displayed_seeks']=[]
    for target in [18.5,2,18.5,2,18.5,2]:
        started=time.monotonic()
        pipeline=run.command('seek-exact',target)
        sample=displayed(run,target)
        run.result['displayed_seeks'].append(dict(target=target,command_to_readback_ms=(time.monotonic()-started)*1000,
            pipeline=pipeline,readback=sample))
    run.result['output_workloads']=[]
    for workload in ['steady','hover','resize']:
        run.command('seek-exact',0);displayed(run,0)
        before=run.command('renderer-metrics')['response']
        start_usage=lifecycle.resources.usage(run.process.pid);started=time.monotonic()
        run.command('play')
        for i in range(12):
            run.require_visible_window(f'{workload}-{i}')
            if workload=='hover': run.command('hover-preview',[1.5,4,8,14][i%4])
            elif workload=='resize': run.command('resize-window',[700,960,1200][i%3])
            time.sleep(.5)
        run.command('pause'); sample=displayed(run)
        after=run.command('renderer-metrics')['response']
        end_usage=lifecycle.resources.usage(run.process.pid);seconds=time.monotonic()-started
        run.result['output_workloads'].append(dict(name=workload,seconds=seconds,before=before,after=after,
            final_displayed=sample,usage_before=start_usage,usage_after=end_usage,
            cpu_percent_one_core=(end_usage['cpu_s']-start_usage['cpu_s'])/seconds*100))
        if before.get('metrics-available')!='yes' or after.get('metrics-available')!='yes':
            raise RuntimeError('Renderer metrics unavailable')
        if int(after['total']) <= int(before['total']): raise RuntimeError('Renderer counter did not advance')
        if int(after['corrupted'])>int(before['corrupted']): raise RuntimeError('Renderer reported corrupted frames')
        run.command('hover-preview',-1)
    run.result['output_screenshot']=responsive.screenshot(run,'output.png')

def command(*args):
    result=subprocess.run(args,capture_output=True,timeout=60)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.decode(errors="replace")}')
    return result.stdout

def storage(app, directory, fixture):
    with tempfile.TemporaryDirectory(prefix='illiquid-owned-volume-') as temporary:
        root=Path(temporary).resolve();image=root/'test.dmg';mount=root/'mount'
        command('hdiutil','create','-size','256m','-fs','APFS','-volname','IlliquidQualification',str(image))
        device=None;run=None
        def attach():
            result=plistlib.loads(command('hdiutil','attach',str(image),'-nobrowse','-mountpoint',str(mount),'-plist'))
            return next(row['dev-entry'] for row in result['system-entities'] if row.get('mount-point')==str(mount))
        try:
            device=attach();media=mount/'Library';media.mkdir();copied=media/fixture.name;shutil.copy2(fixture,copied)
            run=lifecycle.Run(app,directory,0,True,source_folders=[media],
                environment_overrides={"SUPERPLAYR_BENCHMARK_DISPLAY_READBACK":"1"})
            run.wait_line(lambda s:'phase=source-directory-ready ' in s)
            responsive.open_media(run,copied);displayed(run)
            run.command('play');time.sleep(.3)
            offset=len(run.text());start=time.monotonic()
            # Force applies only to the device returned by attaching this owned image.
            command('hdiutil','detach','-force',device);device=None
            run.wait_line(lambda s:'phase=source-volume-change ' in s,offset=offset)
            run.wait_line(lambda s:'phase=source-directory-unavailable ' in s,offset=offset)
            run.result['disconnect_to_unavailable_ms']=(time.monotonic()-start)*1000
            run.command('close-window');run.wait_window(False)
            run.command('reopen-window');run.wait_window(True)
            responsive.open_media(run,fixture);displayed(run)
            offset=len(run.text());start=time.monotonic();device=attach()
            run.wait_line(lambda s:'phase=source-volume-change ' in s,offset=offset)
            run.wait_line(lambda s:'phase=source-directory-ready ' in s,offset=offset)
            run.result['reconnect_to_directory_ms']=(time.monotonic()-start)*1000
            responsive.open_media(run,copied);displayed(run)
            run.command('hover-preview',1.5)
            run.wait_line(lambda s:'phase=preview-view-draw-' in s,offset=offset)
            run.result['recovered_screenshot']=responsive.screenshot(run,'recovered.png')
            return run.finish()
        finally:
            if run:
                (run.directory/'progress.json').write_text(json.dumps(run.result,indent=2))
                run.cleanup()
            if device: command('hdiutil','detach',device)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--app',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--fixture',type=Path,required=True)
    p.add_argument('--mode',choices=['output','storage'],required=True);args=p.parse_args()
    info=plistlib.loads((args.app/'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier']!=lifecycle.DOMAIN: raise SystemExit('Require isolated benchmark bundle')
    args.output.mkdir(parents=True,exist_ok=False)
    receipt=dict(mode=args.mode,binary_sha256=lifecycle.digest(args.app/'Contents/MacOS/Illiquid'),
        fixture_sha256=lifecycle.digest(args.fixture),script_sha256=lifecycle.digest(Path(__file__)),
        limits=['renderer readback is not display scanout','disk image is not NAS/network interruption',
                'process CPU excludes GPU and WindowServer'])
    try:
        if args.mode=='storage': receipt['run']=storage(args.app,args.output/'run',args.fixture)
        else:
            run=lifecycle.Run(args.app,args.output/'run',0,True,environment_overrides={'SUPERPLAYR_BENCHMARK_HEARTBEAT':'0','SUPERPLAYR_BENCHMARK_HIDE_SIDEBAR':'1','SUPERPLAYR_BENCHMARK_DISPLAY_READBACK':'1'})
            try: output(run,args.fixture);receipt['run']=run.finish()
            finally:
                receipt['run']=run.result
                run.cleanup()
    except BaseException as error:
        receipt['failure']=repr(error);raise
    finally: (args.output/'summary.json').write_text(json.dumps(receipt,indent=2))

if __name__=='__main__':main()
