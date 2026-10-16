#!/usr/bin/env python3
"""Exact inventory code with real Foundation I/O; image types are compile-only adapters."""
import argparse,hashlib,json,pathlib,platform,statistics,subprocess,time
H=pathlib.Path(__file__).resolve().parent;R=H.parent.parent

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True)
 p.add_argument('--repeats',type=int,default=5);p.add_argument('--allocations',action='store_true')
 p.add_argument('--tests-only',action='store_true');p.add_argument('--build-only',action='store_true')
 p.add_argument('--cases',default='valid:0,valid:1000,valid:8191,malformed:8191,malformed:32768,unrelated:32768,mixed:8191')
 a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 if any(a.output.iterdir()):p.error('output must be empty')
 if a.repeats<1:p.error('positive repeats required')
 if a.allocations and platform.system()!='Linux':p.error('allocation interposer requires Linux/glibc')
 def run(cmd):
  cmd=list(map(str,cmd));t=time.time();c=subprocess.run(cmd,text=True,capture_output=True,timeout=180)
  with (a.output/'commands.jsonl').open('a') as f:f.write(json.dumps(dict(command=cmd,stdout=c.stdout,stderr=c.stderr,returncode=c.returncode,wall_seconds=time.time()-t))+'\n')
  if c.returncode:raise RuntimeError(c.stderr or c.stdout)
  return c.stdout
 extra=[]
 if a.allocations:
  run(['clang','-O2','-c',R/'Benchmarks/NonDecodePerformance/allocmeter.c','-o',a.output/'meter.o']);extra=['-D','ALLOCATION_METER',a.output/'meter.o']
 src=R/'Sources/IlliquidNativePlayback/Media';manifest=dict(compiler=run(['swiftc','--version']),platform=platform.platform(),allocation_instrumented=a.allocations,sources={})
 tests=[]
 for v in ['v2','v3']:
  d=a.output/v;d.mkdir()
  cp=src/'NativeThumbnailCache.swift';dp=H/'baseline/NativeThumbnailDiskCacheV2.swift' if v=='v2' else src/'NativeThumbnailDiskCache.swift'
  cache=cp.read_text();disk=dp.read_text()
  for name in ['CoreGraphics','CryptoKit','IlliquidCore','ImageIO','UniformTypeIdentifiers']:
   cache=cache.replace('import '+name+'\n','');disk=disk.replace('import '+name+'\n','')
  if '    private nonisolated static func readImage(' in disk:
   begin=disk.index('    private nonisolated static func readImage(')
   end=disk.index('    private static func filenames',begin)
   disk=disk[:begin]+'''    // CODEC ADAPTER ONLY; production lookup and inventory flow retained.
    private nonisolated static func readImage(at url: URL, key: Key) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let image = CGImage.decode(data),
              image.width <= key.width, image.height <= key.height else { return nil }
        return image
    }
'''+disk[end:]
  else:
   begin=disk.index('    func image(for key:');end=disk.index('    func insert(',begin)
   disk=disk[:begin]+'''    // ADAPTER: not called by inventory timing or inventory tests.
     func image(for key: Key, background: Bool) -> CGImage? {
         guard preferences.diskMiB > 0 else { return nil }
         loadDisk()
         guard let entry = files[key.digest], let data = try? Data(contentsOf: entry.url),
               let image = CGImage.decode(data), image.width <= key.width, image.height <= key.height else { return nil }
         if !background { promoteDisk(key.digest) }
         return image
     }
 '''+disk[end:]
  begin=disk.index('    private nonisolated static func encode');end=disk.index('    private func promoteDisk',begin)
  disk=disk[:begin]+'''    private nonisolated static func encode(_ image: CGImage) -> Data? { image.encoded() }
'''+disk[end:]
  disk+='''\nextension NativeThumbnailDiskCache {
    func testEntryCount() -> Int { files.count }
    #if CANDIDATE
    func testParseFilename(_ name: String) -> String? { Self.parseFilename(name)?.digest }
    #endif
}\n'''
  (d/'Cache.swift').write_text(cache);(d/'Disk.swift').write_text(disk)
  inputs=[d/'Cache.swift',d/'Disk.swift',src/'ThumbnailPromotionMailbox.swift',R/'Sources/IlliquidCore/Player/ThumbnailPolicy.swift',R/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',R/'Benchmarks/NonDecodeFollowup/PreviewAdapters.swift',H/'InventoryHarness.swift']
  defines=['-D','CANDIDATE'] if v=='v3' else [];libs=['-lcrypto'] if platform.system()=='Linux' else []
  run(['swiftc','-O','-swift-version','6','-warnings-as-errors',*defines,*extra,*inputs,*libs,'-o',d/'inventory'])
  manifest['sources'][v]={str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in [cp,dp,*inputs]}
  manifest.setdefault('binaries',{})[v]=hashlib.sha256((d/'inventory').read_bytes()).hexdigest()
  if not a.build_only:
   t=json.loads(run([d/'inventory','tests']));t['variant']=v;tests.append(t)
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2));(a.output/'tests.json').write_text(json.dumps(tests,indent=2))
 if a.tests_only or a.build_only:return
 rows=[]
 for case in a.cases.split(','):
  mode,n=case.split(':');n=int(n)
  for rep in range(a.repeats):
   for v in (['v2','v3'] if rep%2==0 else ['v3','v2']):
    row=json.loads(run([a.output/v/'inventory',n,mode]));row.update(variant=v,repeat=rep);rows.append(row)
    with (a.output/'measurements.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
   print(case,rep+1,a.repeats,flush=True)
 summary=[]
 for mode,n,v in sorted({(r['mode'],r['count'],r['variant']) for r in rows}):
  group=[r for r in rows if (r['mode'],r['count'],r['variant'])==(mode,n,v)]
  entry=dict(mode=mode,count=n,variant=v,samples=len(group))
  for k in ['inventory_ns','rss_before','rss_after','allocation_requests','allocation_request_bytes']:
   if k in group[0]:
    vals=[r[k] for r in group];entry[k]=dict(median=statistics.median(vals),min=min(vals),max=max(vals))
  summary.append(entry)
 (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
if __name__=='__main__': main()
