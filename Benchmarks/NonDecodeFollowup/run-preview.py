#!/usr/bin/env python3
"""Compile actual cache/disk actor logic with explicitly labeled pixel/JPEG adapters.
Tests controlled actor blockage, NOT real disk latency, decoding, or input-to-photon.
"""
import argparse,hashlib,json,pathlib,platform,runpy,subprocess,time
H=pathlib.Path(__file__).resolve().parent;R=H.parent.parent
adapt_disk_codecs=runpy.run_path(str(R/'Benchmarks/NonDecodeFourthPass/build.py'))['adapt_disk_codecs']

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--repeats',type=int,default=7);p.add_argument('--tests-only',action='store_true');a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True)
 if any(a.output.iterdir()):p.error('output must be empty')
 if a.repeats < 1:p.error('repeats must be positive')
 def run(cmd):
  c=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=90)
  with (a.output/'commands.jsonl').open('a') as f:f.write(json.dumps({'cmd':list(map(str,cmd)),'returncode':c.returncode,'stdout':c.stdout,'stderr':c.stderr})+'\n')
  if c.returncode:raise RuntimeError(c.stderr)
  return c.stdout
 rows=[]
 for variant in ['baseline','candidate']:
  d=a.output/variant;d.mkdir()
  src=R/'Sources/IlliquidNativePlayback/Media'
  cp=H/'fixtures/PreviewCacheV1.swift' if variant=='baseline' else src/'NativeThumbnailCache.swift'
  dp=H/'fixtures/NativeThumbnailDiskCache.swift' if variant=='baseline' else src/'NativeThumbnailDiskCache.swift'
  cache=cp.read_text();disk=adapt_disk_codecs(dp.read_text(),dp)
  for name in ['CoreGraphics','CryptoKit','IlliquidCore','ImageIO','UniformTypeIdentifiers']:
   cache=cache.replace('import '+name+'\n','');disk=disk.replace('import '+name+'\n','')
  cache+='''\nextension NativeThumbnailCache { func testDisk() -> NativeThumbnailDiskCache { disk } }\n'''
  disk+='''\nextension NativeThumbnailDiskCache {
    func testBlock(started: DispatchSemaphore, release: DispatchSemaphore) {
        started.signal()
        precondition(release.wait(timeout: .now() + 30) == .success)
    }
    func testIsBackground(_ key: Key) -> Bool? { files[key.digest]?.background }
    #if CANDIDATE
    func testPendingPromotions() -> Int { promotions.pendingCount }
    #endif
}
'''
  if 'preferredFilename(for digest:' in disk:
   disk=disk.replace('files[key.digest]?.background', 'preferredFilename(for: key.digest).flatMap { files[$0]?.background }')
  (d/'Cache.swift').write_text(cache);(d/'Disk.swift').write_text(disk)
  inputs=[d/'Cache.swift',d/'Disk.swift',src/'ThumbnailDiskEvictionHeap.swift',src/'ThumbnailPromotionMailbox.swift',R/'Sources/IlliquidCore/Player/ThumbnailPolicy.swift',R/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',H/'PreviewAdapters.swift',H/'PreviewHarness.swift']
  defines=['-D','CANDIDATE'] if variant=='candidate' else []
  libs=['-lcrypto'] if platform.system()=='Linux' else []
  run(['swiftc','-O','-swift-version','6','-warnings-as-errors',*defines,*inputs,*libs,'-o',d/'preview'])
  (d/'input-hashes.json').write_text(json.dumps({str(x.relative_to(R)) if x.is_relative_to(R) else x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in [cp,dp,*inputs]},indent=2))
  result=json.loads(run([d/'preview','tests']));result['variant']=variant;rows.append(result)
 (a.output/'tests.json').write_text(json.dumps(rows,indent=2))
 if a.tests_only:return
 for block in [0,100,500]:
  for mode in (['unblocked'] if block==0 else ['promotion','hot']):
   for repetition in range(a.repeats):
    for variant in (['baseline','candidate'] if repetition%2==0 else ['candidate','baseline']):
     row=json.loads(run([a.output/variant/'preview',block,mode]));row.update(variant=variant,repeat=repetition)
     with (a.output/'measurements.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
    print(f'preview: {block} {mode} round {repetition+1}/{a.repeats}',flush=True)

if __name__=='__main__':main()
