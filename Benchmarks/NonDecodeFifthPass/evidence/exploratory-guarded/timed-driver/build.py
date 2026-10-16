#!/usr/bin/env python3
"""Build the exact selected core/Observation sources; no UI, codecs, or mock values."""
from pathlib import Path
import hashlib,json,os,platform,subprocess
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
OLD=ROOT/'Benchmarks/NonDecodeFollowup/fixtures'
EXPECTED={
 'baseline/PlaybackState.swift':'0f9014ba2a41029a20410ddf51c0271fe341224a',
 'fixtures/PlaybackViewStore.swift':'c8511ca7c60ede45b1bc0557f6e768851cc80e25',
 'fixtures/PlaybackModels.swift':'eaf55128a490782e77c23363a37ae256d8c456cc',
 'fixtures/FolderPlaylist.swift':'b2fe49ea21a1d38bd1a8ae9dea2936ef34d6d206',
 'fixtures/MediaSource.swift':'f0651daabf51d342e4d61e78f541415f38bd3951',
 'fixtures/PictureInPictureState.swift':'f51a3f244e621567db9c24f3581fbc1f866ac62b',
 'fixtures/PlaybackPhase.swift':'72df924051cd23d2c0245d7a9738a011ffc6a4bd',
 'fixtures/PlaybackRecoveryIssue.swift':'fb102c4982a5a6ef585c52c210c4f264397d0a3a',
 'fixtures/NaturalFilenameOrdering.swift':'3e31506bdec552337ce25dfeaf54da2afc6e6c1d',
}
SUPPORT=['MediaTrack.swift','TrackSelectionPreferences.swift','PlaybackPreferences.swift','SubtitleFallbackEncoding.swift','NormalizedFileURL.swift']
def run(cmd,output,timeout=180):
 r=subprocess.run([str(x) for x in cmd],capture_output=True,text=True,timeout=timeout)
 with (output/'commands.jsonl').open('a') as f:
  f.write(json.dumps({'command':[str(x) for x in cmd],'returncode':r.returncode,'stdout':r.stdout,'stderr':r.stderr})+'\n')
 if r.returncode: raise RuntimeError(r.stderr+r.stdout)
 return r.stdout

def build(output:Path,variant='v5',configuration='release',meter=False,differential=False):
 output.mkdir(parents=True,exist_ok=True)
 for name,expected in EXPECTED.items():
  raw=(HERE/name).read_bytes();actual=hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
  if actual!=expected: raise ValueError(f'Original Git blob mismatch: {name}: {actual}')
 state={'v4':HERE/'baseline/PlaybackState.swift','batch':HERE/'baseline/PlaybackStateBatchOnly.swift','v5':ROOT/'Sources/IlliquidCore/Player/PlaybackState.swift'}[variant]
 sources=[*sorted((HERE/'fixtures').glob('*.swift')),*[OLD/n for n in SUPPORT],state,ROOT/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift']
 if differential:
  import re
  legacy=(HERE/'baseline/PlaybackState.swift').read_text()
  legacy='import Foundation\nimport Observation\n\n'+legacy[legacy.index('@MainActor\n@Observable'):]
  legacy=re.sub(r'\bPlaybackState\b','LegacyPlaybackState',legacy)
  (output/'LegacyPlaybackState.swift').write_text(legacy)
  view=(HERE/'fixtures/PlaybackViewStore.swift').read_text()
  fields=re.findall(r'^    public let (\w+):',view,re.M)
  extra='extension PlaybackViewSnapshot {\n    @MainActor public init(baseline: LegacyPlaybackState) {\n'+''.join(f'        {name} = baseline.{name}\n' for name in fields)+'    }\n}\n'
  (output/'LegacySnapshot.swift').write_text(extra)
  sources += [output/'LegacyPlaybackState.swift',output/'LegacySnapshot.swift']
 flags=['-O','-whole-module-optimization'] if configuration=='release' else ['-Onone','-g']
 # Supplied dynamic Observation library has an unresolved hidden threading::fatal
 # on this Linux toolchain. Static linkage uses the matching shipped Swift runtime
 # implementation, with no replacement/fake Observation functions.
 static=['-static-stdlib'] if platform.system()=='Linux' else []
 common=['swiftc','-swift-version','6','-warnings-as-errors',*flags,*static]
 run([*common,'-emit-library','-static','-emit-module','-module-name','IlliquidCore','-enable-testing',*sources,'-emit-module-path',output/'IlliquidCore.swiftmodule','-o',output/'libIlliquidCore.a'],output)
 obj=[]
 if meter:
  if platform.system()!='Linux':raise RuntimeError('Allocation interposer is Linux/glibc only')
  run(['cc','-O2','-c',ROOT/'Benchmarks/NonDecodePerformance/allocmeter.c','-o',output/'allocmeter.o'],output);obj=[output/'allocmeter.o']
 harness=HERE/'StateHarness.swift'
 tests=ROOT/'Tests/IlliquidCoreTests/PlaybackStatePublicationTests.swift'
 extra=[]
 if differential:
  # Duplicate operation dispatch only; the legacy state itself is the exact
  # original implementation with its class name changed to coexist in one module.
  text=(HERE/'StateDifferential.swift').read_text()
  start=text.index('    static func apply(');end=text.index('\n    static func run()',start)
  text=text[:end]+text[start:end].replace('apply(','applyLegacy(',1).replace('state: PlaybackState','state: LegacyPlaybackState')+text[end:]
  (output/'StateDifferential.swift').write_text(text)
  extra=[output/'StateDifferential.swift']
 run([*common,'-D','PORTABLE_STATE_TESTS',*(['-D','ALLOC_METER'] if meter else []),*(['-D','STATE_DIFFERENTIAL'] if differential else []),'-I',output,'-L',output,'-lIlliquidCore',harness,tests,*extra,*obj,'-o',output/'state-harness'],output)
 manifest={'variant':variant,'configuration':configuration,'allocation_meter':meter,'differential':differential,'platform':platform.platform(),'compiler':run(['swift','--version'],output).strip(),'static_swift_runtime':bool(static),'original_git_blobs':EXPECTED,'sha256':{str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,harness,tests,*extra]},'executable_sha256':hashlib.sha256((output/'state-harness').read_bytes()).hexdigest()}
 (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 return output/'state-harness'
