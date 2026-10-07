#!/usr/bin/env python3
"""Same-host, serial Illiquid/mpv/IINA resource comparison; no display-latency claims.

Requires an isolated IINA bundle and benchmark Illiquid bundle. Never changes
system volume or the installed players' preferences. Native quit uses one helper.
"""
import argparse, hashlib, importlib.util, json, os, plistlib, shutil, subprocess, tempfile, time
from pathlib import Path

def module(name, filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
lifecycle=module('lifecycle','profile-lifecycle.py')
ref=lifecycle.resources
IINA_DOMAIN='com.example.IINAPerformanceBenchmark'

def wait_for(test, timeout=20):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        result=test()
        if result:return result
        time.sleep(.01)
    raise TimeoutError('condition not reached')

def visible(pid):
    return [w for w in ref.windows(pid) if w.get('kCGWindowIsOnscreen') and w.get('kCGWindowLayer')==0
            and w['kCGWindowBounds']['Width']>200 and w['kCGWindowBounds']['Height']>150]

def latest_fields(log, prefix):
    lines=[line for line in log.splitlines() if line.startswith(prefix)]
    return dict(part.split('=',1) for part in lines[-1].split() if '=' in part) if lines else {}

def phase(pid, name, seconds, clock=None):
    before=clock() if clock else None; start=time.monotonic();first=ref.usage(pid);samples=[]
    while time.monotonic()-start<seconds:
        time.sleep(.1);samples.append(ref.usage(pid))
    wall=time.monotonic()-start
    result={'name':name,'wall_s':wall,'cpu_percent_one_core':(samples[-1]['cpu_s']-first['cpu_s'])/wall*100,
            'end_footprint_mib':samples[-1]['footprint_mib'],'peak_footprint_mib':max(s['footprint_mib'] for s in samples),'samples':samples}
    if clock:result['clock_advance_s']=clock()-before
    return result

class Reference:
    def __init__(self,player,iina,fixture,directory,disable_thumbnails=False):
        self.temp=tempfile.TemporaryDirectory(prefix='illiquid-reference-');temp=Path(self.temp.name)
        self.logpath=temp/'app.log';self.log=self.logpath.open('w');self.directory=directory
        self.ipc=None;ipcpath=temp/'ipc'
        options=[f'--input-ipc-server={ipcpath}','--pause=yes','--keep-open=yes','--idle=yes',
                 '--hwdec=videotoolbox','--volume=0','--mute=yes','--resume-playback=no',
                 '--save-position-on-quit=no','--osd-level=0']
        if player=='mpv':
            command=[shutil.which('mpv'),'--no-config','--vo=gpu-next','--force-window=immediate',
                     '--geometry=1920x1080+200+200',*options]
        else:
            settings={'recordPlaybackHistory':False,'recordRecentFiles':False,'quitWhenNoOpenedWindow':False,
                      'SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SUHasLaunchedBefore':True,
                      'enableRecentDocumentsWorkaround':False,'pauseWhenOpen':True,'actionAfterLaunch':0,
                      'enableLogging':False,'enablePluginSystem':False}
            if disable_thumbnails: settings['enableThumbnailPreview']=False
            seed=temp/'seed.plist';seed.write_bytes(plistlib.dumps(settings))
            subprocess.run(['defaults','delete',IINA_DOMAIN],capture_output=True)
            subprocess.run(['defaults','import',IINA_DOMAIN,str(seed)],check=True,capture_output=True)
            command=[str(iina/'Contents/MacOS/IINA'),*['--mpv-'+o[2:] for o in options], '--mpv-geometry=960x540+100+100']
        if fixture:command.append(str(fixture))
        self.start=time.monotonic();self.process=subprocess.Popen(command,stdout=self.log,stderr=subprocess.STDOUT)
        self.pid=self.process.pid;self.result={'command':command,'pid':self.pid,'phases':[]}
        try:
            self.result['launch_window_ms']=(time.monotonic()-self.start)*1000 if visible(self.pid) else None
            wait_for(lambda:visible(self.pid));self.result['launch_window_ms']=(time.monotonic()-self.start)*1000
            if fixture or player=='mpv':
                wait_for(ipcpath.exists);self.ipc=ref.IPC(ipcpath)
                if fixture:
                    wait_for(lambda:self.ipc.get('duration') is not None and self.ipc.get('time-pos') is not None and self.ipc.get('video-out-params') is not None)
                    self.result['launch_media_state_ready_ms']=(time.monotonic()-self.start)*1000
                    self.result['metadata']={key:self.ipc.get(key) for key in ['mpv-version','ffmpeg-version','current-vo','hwdec-current','video-params','video-out-params','osd-dimensions','audio-params','duration','sid','sub-codec','track-list']}
            self.result['windows']=visible(self.pid)
        except BaseException:self.cleanup();raise
    def cleanup(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait()
        if self.ipc:self.ipc.socket.close()
        self.log.close();shutil.copy2(self.logpath,self.directory/'app.log');self.temp.cleanup()

def run(player,case,index,args,output):
    directory=output/f'{index}-{case}-{player}';directory.mkdir()
    fixture=None if case=='empty' else args.media[case]
    app=None
    try:
        if player=='illiquid':
            # Run creates its own output directory.
            directory.rmdir()
            app=lifecycle.Run(args.illiquid,directory,0,True,environment_overrides={
                'ILLIQUID_BENCHMARK_HEARTBEAT':'0','ILLIQUID_BENCHMARK_HIDE_SIDEBAR':'1',
                'ILLIQUID_BENCHMARK_VP9_HARDWARE':'1' if getattr(args,'experimental_vp9_hardware',False) else '0',
                'ILLIQUID_BENCHMARK_WINDOW_SIZE':'960x540'},controls_always_visible=False)
            pid=app.process.pid;result=app.result;result['launch_player_ready_ms']=result['launch_onscreen_ms']
            result['windows']=visible(pid)
            clock=lambda:float(app.command('snapshot')['response']['renderer-time'])
            if fixture:
                offset=len(app.text());app.command('open',source=fixture)
                app.wait_line(lambda line:'phase=first-frame-submitted ' in line,offset=offset)
                result['launch_first_submit_observed_ms']=(time.monotonic()-app.start)*1000
                wait_for(lambda:clock()>.1)
            pause=lambda value:app.command('pause' if value else 'play')
            seek=lambda target:app.command('seek-exact',target)
        else:
            app=Reference(player,args.iina,fixture,directory,disable_thumbnails=args.no_iina_thumbnails);pid=app.pid;result=app.result
            clock=lambda:float(app.ipc.get('time-pos') or 0)
            pause=lambda value:app.ipc.command(['set_property','pause',value])
            seek=lambda target:app.ipc.seek(target)
        result.update(player=player,case=case,repeat=index)
        if fixture:
            pause(True);seek(0);pause(False);time.sleep(2)
            result['phases'].append(phase(pid,'playing',6,clock))
            if player=='illiquid':
                result['playing_native_metrics']=latest_fields(app.text(),'[native-metrics]')
                result['playing_native_observations']=latest_fields(app.text(),'[native-observation]')
            pause(True);time.sleep(1)
            result['phases'].append(phase(pid,'paused',4,clock))
            result['seeks']=[seek(t) for t in [1.5,8.5,2.5]]
            if player=='illiquid':result['native_snapshot']=app.command('snapshot')['response']
            assert .85*result['phases'][0]['wall_s']<result['phases'][0]['clock_advance_s']<1.15*result['phases'][0]['wall_s']
            assert abs(result['phases'][1]['clock_advance_s'])<.1
            if player!='illiquid':
                result['dropped_frames']={key:app.ipc.get(key) for key in ['frame-drop-count','decoder-frame-drop-count']}
        else:
            time.sleep(2);result['phases'].append(phase(pid,'empty-idle',4))
        result['windows_end']=visible(pid)
        if fixture and args.drain:
            duration=float(args.probes[case]['format']['duration'])
            seek(duration-2);pause(False)
            start=time.monotonic()
            if player=='illiquid':
                def stopped_at_end():
                    sample=app.command('snapshot')['response']
                    return sample if float(sample['renderer-rate'])==0 and float(sample['renderer-time'])>=duration-.25 else None
                result['end_snapshot']=wait_for(stopped_at_end,timeout=10)
            else:
                wait_for(lambda:app.ipc.get('eof-reached'),timeout=10)
                result['end_snapshot']={'eof-reached':app.ipc.get('eof-reached'),'time-pos':app.ipc.get('time-pos')}
            result['end_wait_ms']=(time.monotonic()-start)*1000
        if args.close:
            start=time.monotonic()
            if player=='illiquid':
                app.command('close-window');closed=True
                result['native_close_control']={'method':'benchmark command to NSWindow close','exit':0}
            else:
                control=subprocess.run([str(args.control),str(pid),'close'],capture_output=True,text=True,timeout=10)
                result['native_close_control']={'method':'AXCloseButton','exit':control.returncode,'stdout':control.stdout}
                closed=control.returncode==0
            if closed:
                wait_for(lambda:app.process.poll() is not None or not visible(pid))
                result['close_window_ms']=(time.monotonic()-start)*1000
                time.sleep(1);result['alive_after_close']=app.process.poll() is None
                if result['alive_after_close']:result['phases'].append(phase(pid,'closed',4))
                if player=='illiquid' and result['alive_after_close']:
                    offset=len(app.text());start=time.monotonic();app.command('reopen-window')
                    app.wait_line(lambda line:'phase=window-configure.end ' in line,offset=offset);app.wait_window(True)
                    result['reopen_window_ms']=(time.monotonic()-start)*1000
                    if fixture:
                        offset=len(app.text());start=time.monotonic();app.command('open',source=fixture)
                        app.wait_line(lambda line:'phase=first-frame-submitted ' in line,offset=offset)
                        result['reopen_media_submit_ms']=(time.monotonic()-start)*1000
        if app.process.poll() is None:
            start=time.monotonic()
            if player=='mpv':
                result['quit_method']='mpv IPC quit'
                try:app.ipc.command(['quit'])
                except (OSError,RuntimeError):pass
            else:
                result['quit_method']='NSRunningApplication terminate helper'
                control=subprocess.run([str(args.control),str(pid),'quit'],capture_output=True,text=True,timeout=10)
                assert control.returncode==0 and 'accepted' in control.stdout,control.stdout
            app.process.wait(timeout=15);result['native_quit_exit_ms']=(time.monotonic()-start)*1000
        assert app.process.returncode==0,app.process.returncode
        if player=='illiquid':app.finish()
        result['status']='complete';(directory/'comparison.json').write_text(json.dumps(result,indent=2)+'\n');return result
    except BaseException as error:
        if app:
            app.result['failure']=repr(error)
            (directory/'failed-comparison.json').write_text(json.dumps(app.result,indent=2)+'\n')
        raise
    finally:
        if app:app.cleanup()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['illiquid','iina','fixtures','control','output']:p.add_argument('--'+name,required=True,type=Path)
    p.add_argument('--repeats',type=int,default=3);p.add_argument('--close',action='store_true')
    p.add_argument('--no-iina-thumbnails',action='store_true',help='Disable IINA automatic thumbnails for the playback-only control')
    p.add_argument('--drain',action='store_true',help='Also seek near EOF and verify reference EOF/native clock stopped near end; this does not prove audible/visible output')
    p.add_argument('--experimental-vp9-hardware',action='store_true',help='Opt into supplemental VP9 registration in supported benchmark builds; not the production default')
    p.add_argument('--players',nargs='+',choices=['illiquid','mpv','iina'],default=['illiquid','mpv','iina'])
    p.add_argument('--cases',nargs='+',default=['empty','1080p','4k'])
    p.add_argument('--fixture',action='append',default=[],metavar='NAME=PATH',help='Additional video fixture, at least 16 seconds long')
    a=p.parse_args()
    if a.repeats<1:p.error('repeats must be positive')
    for name in ['illiquid','iina','fixtures','control']:setattr(a,name,getattr(a,name).resolve(strict=True))
    a.media={name:a.fixtures/f'h264-{name}.mp4' for name in ['1080p','4k']}
    for specification in a.fixture:
        name,separator,path=specification.partition('=')
        if not separator or not name or name=='empty' or not all(c.isalnum() or c in '-_' for c in name):p.error('fixture must be NAME=PATH with a simple name other than empty')
        a.media[name]=Path(path).resolve(strict=True)
    if any(case!='empty' and case not in a.media for case in a.cases):p.error('unknown case; supply --fixture NAME=PATH')
    selected_media={name:a.media[name] for name in a.cases if name!='empty'}
    probes={}
    for name,path in selected_media.items():
        probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(path)],text=True))
        if float(probe['format'].get('duration',0))<16 or not any(s['codec_type']=='video' for s in probe['streams']):p.error('fixtures require video and at least 16 seconds duration')
        probes[name]=probe
    a.probes=probes
    if plistlib.loads((a.iina/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']!=IINA_DOMAIN:p.error('requires isolated IINA identity')
    if plistlib.loads((a.illiquid/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']!=lifecycle.DOMAIN:p.error('requires benchmark Illiquid identity')
    a.output.mkdir(parents=True,exist_ok=False)
    digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    summary={'runs':[],'protocol':{'script_sha256':digest(Path(__file__)),'repeats':a.repeats,'heartbeat':False,'iina_thumbnail_generation':'disabled' if a.no_iina_thumbnails else 'default','target_window_points':'960x540','muting':'per-player only','quit':'NSRunningApplication helper for apps; IPC for mpv CLI','lifecycle_script_sha256':digest(Path(__file__).with_name('profile-lifecycle.py')),'resource_script_sha256':digest(Path(__file__).with_name('profile-reference-player.py'))},
      'versions':{'mpv':subprocess.check_output(['mpv','--version'],text=True),'iina':plistlib.loads((a.iina/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']},
      'sha256':{'illiquid':digest(a.illiquid/'Contents/MacOS/Illiquid'),'iina':digest(a.iina/'Contents/MacOS/IINA'),'mpv':digest(Path(shutil.which('mpv'))),'control':digest(a.control),**{name:digest(f) for name,f in selected_media.items()}},
      'fixtures':probes,
      'limitations':['warm caches; direct process launches','media readiness endpoints differ; neither proves scanout','process CPU excludes GPU and WindowServer','mpv forced idle window; IINA welcome window; Illiquid player-ready window','IINA isolated copy re-signed ad hoc; recent/history/plugins/update checks disabled','Illiquid benchmark diagnostics enabled but heartbeat off; no universal overhead correction','Reference IPC seek completion differs from native exact-seek completion','host background activity uncontrolled']}
    try:
        for index in range(a.repeats):
            players=a.players[index%len(a.players):]+a.players[:index%len(a.players)]
            for case in a.cases:
                for player in players:
                    print(f'{index+1} {case} {player}',flush=True)
                    summary['runs'].append(run(player,case,index+1,a,a.output))
                    (a.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    except BaseException as e:
        summary['failure']=repr(e);raise
    finally:(a.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
if __name__=='__main__':main()
