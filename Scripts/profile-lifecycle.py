#!/usr/bin/env python3
"""Profile an isolated, opt-in Illiquid benchmark bundle; retain raw phase evidence.

Command round trips and main-queue gaps are not input-to-photon latency.
Launches are fresh processes with warm OS caches; this does not purge system caches.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import statistics
import subprocess
import shutil
import tempfile
import time
import uuid

spec = importlib.util.spec_from_file_location('resources', Path(__file__).with_name('profile-reference-player.py'))
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)
DOMAIN = 'com.example.SuperplayrBenchmark'

def fields(line):
    return dict(re.findall(r'([\w-]+)=([^ ]+)', line))

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

class Run:
    def __init__(self, app, directory, entries, keep, source_count=0, *, environment_overrides=None,
                 controls_always_visible=True, source_folders=()):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=False)
        self.runtime_directory = tempfile.TemporaryDirectory(prefix='illiquid-lifecycle-')
        runtime = Path(self.runtime_directory.name)
        self.logpath = runtime / 'app.log'
        self.commandpath = runtime / 'command.json'
        self.sessionpath = runtime / 'session.json'
        self.session = uuid.uuid4().hex
        history = {'playbackPositions': {f'/benchmark/media/{i}.mkv': 120 for i in range(entries)},
                   'playbackDurations': {f'/benchmark/media/{i}.mkv': 3600 for i in range(entries)}}
        preferences = {'isMuted': True, 'volume': 0, 'playbackSpeed': 1,
                       'remembersPlaybackHistory': True, 'restoresSessionPaused': True}
        settings = {'Superplayr.playback-state.v1': json.dumps(history).encode(),
                    'Superplayr.playback-preferences.v1': json.dumps(preferences).encode(),
                    'Illiquid.keeps-running-after-last-window-closed': keep,
                    'Platinum.controls-always-visible': controls_always_visible}
        if source_count:
            settings['Superplayr.source-tabs.v1'] = json.dumps([{'id': 'benchmark', 'items': [
                {'kind': 'file', 'path': f'/benchmark/sources/episode-{i}.mkv'} for i in range(source_count)]}]).encode()
        if source_folders:
            settings['Superplayr.source-tabs.v1'] = json.dumps([{'id': 'benchmark', 'items': [
                {'kind': 'folder', 'path': str(folder)} for folder in source_folders]}]).encode()
        seed = directory / 'preferences.plist'
        seed.write_bytes(plistlib.dumps(settings))
        # `defaults import` merges unspecified keys. Reset this benchmark-only
        # domain so source tabs/window choices cannot leak between test cases.
        subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
        subprocess.run(['defaults', 'import', DOMAIN, str(seed)], check=True, capture_output=True)
        self.log = self.logpath.open('w')
        # Benchmark bundles otherwise default to legacy BGRA, unlike production.
        # Do not inherit unrelated tuning flags from an earlier shell experiment.
        environment = dict({k:v for k,v in os.environ.items() if not k.startswith('SUPERPLAYR_BENCHMARK_')}, SUPERPLAYR_ENABLE_BENCHMARK_OVERRIDES='1',
            SUPERPLAYR_BENCHMARK_LIFECYCLE='1', SUPERPLAYR_BENCHMARK_CONTROL_SESSION=self.session,
            SUPERPLAYR_BENCHMARK_CONTROL_FILE=str(self.commandpath),
            SUPERPLAYR_BENCHMARK_SESSION_FILE=str(self.sessionpath),
            SUPERPLAYR_BENCHMARK_THUMBNAIL_CACHE=str(runtime / 'thumbnails'),
            SUPERPLAYR_BENCHMARK_WINDOW_SIZE='960x600', SUPERPLAYR_BENCHMARK_HIDE_SIDEBAR='0',
            SUPERPLAYR_BENCHMARK_SOFTWARE_OUTPUT='planar', SUPERPLAYR_BENCHMARK_VP9_HARDWARE='0')
        environment.update(environment_overrides or {})
        self.start = time.monotonic()
        self.process = subprocess.Popen([str(app / 'Contents/MacOS/Illiquid')], env=environment,
                                        stdout=self.log, stderr=subprocess.STDOUT)
        self.result = {'history_entries': entries, 'keep_running': keep, 'source_items': source_count, 'pid': self.process.pid,
                       'commands': [], 'phases': [], 'software_output': environment['SUPERPLAYR_BENCHMARK_SOFTWARE_OUTPUT'],
                       'supplemental_vp9_experiment': environment['SUPERPLAYR_BENCHMARK_VP9_HARDWARE']=='1'}
        try:
            self.wait_window(True)
            self.result['launch_first_onscreen_ms'] = (time.monotonic() - self.start) * 1000
            self.wait_line(lambda line: 'phase=window-configure.end ' in line)
            self.result['launch_configured_ms'] = (time.monotonic() - self.start) * 1000
            self.wait_window(True)
            self.result['launch_onscreen_ms'] = (time.monotonic() - self.start) * 1000
            self.command('reopen-window')
        except BaseException:
            self.process.terminate()
            self.process.wait(timeout=10)
            self.log.close()
            self.archive()
            self.runtime_directory.cleanup()
            raise

    def archive(self):
        for path in [self.logpath, self.commandpath, self.sessionpath]:
            if path.exists(): shutil.copy2(path, self.directory / path.name)

    def text(self):
        return self.logpath.read_text(errors='replace')

    def wait_line(self, predicate, timeout=20, offset=0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for line in reversed(self.text()[offset:].splitlines()):
                if predicate(line): return line
            if self.process.poll() is not None:
                raise RuntimeError(f'app exited: {self.process.returncode}; see {self.logpath}')
            time.sleep(.005)
        raise TimeoutError(f'no acknowledgement; see {self.logpath}')

    def wait_window(self, visible, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = any(row.get('kCGWindowIsOnscreen') and row.get('kCGWindowLayer') == 0
                        and row['kCGWindowBounds']['Width'] >= 600 and row['kCGWindowBounds']['Height'] >= 400 for row in resources.windows(self.process.pid))
            if found == visible: return
            time.sleep(.01)
        raise TimeoutError(f'window visibility never became {visible}; '
                           f'own windows: {resources.windows(self.process.pid)}')

    def require_visible_window(self, context):
        # Small aspect-locked resize windows can be shorter than the startup
        # threshold. Record every own window so another Space is distinguishable
        # from a missing or undersized window. Onscreen is not scanout proof.
        rows = resources.windows(self.process.pid)
        visible = any(row.get('kCGWindowIsOnscreen') and row.get('kCGWindowLayer') == 0
                      and row['kCGWindowBounds']['Width'] >= 600
                      and row['kCGWindowBounds']['Height'] >= 200 for row in rows)
        self.result.setdefault('visibility_samples', []).append(
            dict(context=context, elapsed_s=time.monotonic() - self.start,
                 visible=visible, windows=rows))
        if not visible:
            raise RuntimeError(f'Benchmark window left the visible desktop during {context}; '
                               'this run is invalid, not a playback performance result')

    def command(self, action, target=None, source=None):
        identifier = uuid.uuid4().hex
        data = {'session': self.session, 'id': identifier, 'action': action}
        if target is not None: data['targetSeconds'] = target
        if source is not None: data['sourcePath'] = str(source)
        pending = self.commandpath.with_suffix('.pending')
        pending.write_text(json.dumps(data))
        pending.replace(self.commandpath)
        start = time.monotonic()
        os.kill(self.process.pid, signal.SIGUSR1)
        line = self.wait_line(lambda line: f'id={identifier} ' in line and
            ('phase=completed ' in line or 'phase=snapshot ' in line or 'accepted=no' in line))
        response = fields(line)
        if response.get('accepted') != 'yes': raise RuntimeError(line)
        result = {'action': action, 'target': target, 'roundtrip_ms': (time.monotonic()-start)*1000,
                  'response': response}
        self.result['commands'].append(result)
        return result

    def phase(self, name, seconds=2, playback=False):
        before_clock = float(self.command('snapshot')['response']['renderer-time']) if playback else None
        start = time.monotonic()
        first = resources.usage(self.process.pid)
        samples = []
        while time.monotonic() - start < seconds:
            time.sleep(.1)
            samples.append(resources.usage(self.process.pid))
        wall = time.monotonic() - start
        row = {'name': name, 'wall_s': wall,
               'cpu_percent_one_core': (samples[-1]['cpu_s']-first['cpu_s'])/wall*100,
               'peak_footprint_mib': max(s['footprint_mib'] for s in samples),
               'end_footprint_mib': samples[-1]['footprint_mib'], 'samples': samples}
        if playback:
            row['renderer_advance_s'] = float(self.command('snapshot')['response']['renderer-time']) - before_clock
        self.result['phases'].append(row)

    def quit(self):
        start = time.monotonic()
        # A normal Apple event enters AppKit outside a dispatch callback. Calling
        # terminate synchronously inside a main-queue callback nests its run loop
        # and can prevent the delegate's asynchronous shutdown task from running.
        subprocess.run(['osascript', '-e', 'tell application id "'+DOMAIN+'" to quit'],
                       check=True, capture_output=True, timeout=15)
        self.process.wait(timeout=15)
        self.result['quit_process_exit_ms'] = (time.monotonic()-start)*1000
        if self.process.returncode != 0: raise RuntimeError('nonzero application exit')
        self.result['isolated_session_written'] = self.sessionpath.exists()

    def finish(self):
        if self.process.poll() is None:
            self.quit()
        self.log.close()
        self.result['timings'] = [fields(line) for line in self.text().splitlines()
                                  if line.startswith('[lifecycle-performance]')]
        self.result['status'] = 'complete'
        self.archive()
        (self.directory / 'result.json').write_text(json.dumps(self.result, indent=2)+'\n')
        return self.result

    def cleanup(self):
        if self.process.poll() is None:
            try: self.quit()
            except Exception:
                self.process.terminate()
                self.process.wait(timeout=10)
        self.log.close()
        self.archive()
        self.runtime_directory.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--comparison-app', type=Path, help='Alternate this candidate with --app for matched runs')
    parser.add_argument('--fixture-dir', required=True, type=Path)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--keep-running', action='store_true')
    parser.add_argument('--close-cycles', type=int, default=3)
    parser.add_argument('--closed-seconds', type=float, default=1)
    parser.add_argument('--cases', nargs='+', default=['empty', 'history10k', '1080p', '4k'])
    args = parser.parse_args()
    if args.repeats < 1: parser.error('repeats must be positive')
    if not 1 <= args.close_cycles <= 20: parser.error('close-cycles must be 1...20')
    if not .5 <= args.closed_seconds <= 60: parser.error('closed-seconds must be .5...60')
    app = args.app.resolve(strict=True)
    metadata = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    if metadata.get('CFBundleIdentifier') != DOMAIN: parser.error('requires isolated benchmark bundle')
    apps = {'baseline': app} if args.comparison_app else {'app': app}
    if args.comparison_app:
        if args.keep_running: parser.error('test keep-running separately from baseline comparison')
        candidate = args.comparison_app.resolve(strict=True)
        if plistlib.loads((candidate/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != DOMAIN:
            parser.error('comparison app must use the benchmark identity')
        apps['candidate'] = candidate
    output = args.output.resolve()
    if (output/'summary.json').exists(): parser.error('output already contains results; choose a new directory')
    output.mkdir(parents=True, exist_ok=True)
    fixtures = {'1080p': args.fixture_dir.resolve()/'h264-1080p.mp4',
                '4k': args.fixture_dir.resolve()/'h264-4k.mp4'}
    summary = {'app': str(app), 'executable_sha256': digest(app/'Contents/MacOS/Illiquid'),
               'os': subprocess.check_output(['sw_vers'], text=True),
               'machine': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
               'fixtures': {k: {'path': str(v), 'sha256': digest(v)} for k,v in fixtures.items()},
               'limitations': ['Fresh processes, warm OS caches; no cache purge',
                   'WindowServer onscreen presence does not prove completed display scanout',
                   'Command acknowledgement is not input-to-photon latency',
                   '10 ms main-queue heartbeat is benchmark-only and records gaps over 20 ms',
                   'Process CPU excludes WindowServer and GPU; other host activity is uncontrolled'], 'runs': []}
    summary['protocol'] = {'repeats': args.repeats, 'cases': args.cases, 'close_cycles': args.close_cycles, 'closed_seconds': args.closed_seconds, 'script_sha256': digest(Path(__file__)), 'runtime_storage': tempfile.gettempdir()}
    summary['apps'] = {label: {'path': str(path), 'sha256': digest(path/'Contents/MacOS/Illiquid')}
                       for label, path in apps.items()}
    jobs = [(index, name, variant, bundle) for index in range(args.repeats)
            for name in (args.cases if index%2 == 0 else list(reversed(args.cases)))
            for variant, bundle in (list(apps.items()) if index%2 == 0 else list(reversed(list(apps.items()))))]
    for index, name, variant, bundle in jobs:
        label = f'{variant}-{name}-{index+1}'
        print('Profiling '+label, flush=True)
        run = None
        try:
            run = Run(bundle, output/label, {'history10k': 10000, 'history100k': 100000}.get(name, 0), args.keep_running,
                      1000 if name == 'sources1000' else 0)
            run.result['case'] = name
            run.result['variant'] = variant
            run.phase('empty-visible', 1)
            if name in fixtures:
                offset = len(run.text())
                start = time.monotonic()
                run.command('open', source=fixtures[name])
                run.wait_line(lambda line: '[native-presentation]' in line and 'renderer-clock-advanced=yes' in line, offset=offset)
                run.result['open_clock_advanced_ms'] = (time.monotonic()-start)*1000
                run.phase('playing-visible', 3, playback=True)
                for i in range(12):
                    run.command('ping')
                    run.command('toggle-sidebar')
                    run.command('resize-window', target=960 if i%2 else 1100)
                run.command('pause')
                run.phase('paused-visible', 2, playback=True)
                for target in [1.5, 8.5, 2.5]: run.command('seek-exact', target)
            if args.keep_running:
                for cycle in range(args.close_cycles):
                    start = time.monotonic()
                    run.command('close-window')
                    run.wait_window(False)
                    run.result.setdefault('close_onscreen_ms', []).append((time.monotonic()-start)*1000)
                    run.phase('closed-'+str(cycle), args.closed_seconds)
                    start = time.monotonic()
                    offset = len(run.text())
                    run.command('reopen-window')
                    run.wait_line(lambda line: 'phase=window-configure.end ' in line, offset=offset)
                    run.wait_window(True)
                    run.result.setdefault('reopen_onscreen_ms', []).append((time.monotonic()-start)*1000)
                    if name in fixtures and cycle < args.close_cycles-1:
                        offset = len(run.text())
                        run.command('open', source=fixtures[name])
                        run.wait_line(lambda line: '[native-presentation]' in line and 'renderer-clock-advanced=yes' in line, offset=offset)

            run.quit()
            summary['runs'].append(run.finish())
            (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
        except Exception as error:
            summary['failure'] = {'case': label, 'error': str(error)}
            (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
            raise
        finally:
            if run is not None: run.cleanup()
    print('Complete: '+str(output/'summary.json'), flush=True)

if __name__ == '__main__': main()
