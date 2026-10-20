#!/usr/bin/env python3
"""Build the exact disk actor except image codecs, with explicit file-based adapters.
Never replaces image(for:); first-access control flow remains production code.
"""
import hashlib,json,pathlib,platform,subprocess,time
H=pathlib.Path(__file__).resolve().parent
R=H.parent.parent

def run(cmd, log, timeout=180):
    cmd=list(map(str,cmd));t=time.monotonic()
    proc=subprocess.run(cmd,text=True,capture_output=True,timeout=timeout)
    with log.open('a') as f:f.write(json.dumps(dict(command=cmd,returncode=proc.returncode,stdout=proc.stdout,stderr=proc.stderr,wall_seconds=time.monotonic()-t))+'\n')
    if proc.returncode:raise RuntimeError(proc.stderr or proc.stdout)
    return proc.stdout

def build(output, harness='DiskHarness.swift', variants=('v3','accounting','v4'), allocations=False, debug=False):
    output=pathlib.Path(output);output.mkdir(parents=True,exist_ok=True)
    src=R/'Sources/IlliquidNativePlayback/Media';log=output/'commands.jsonl'
    extra=[]
    if allocations:
        if platform.system()!='Linux':raise RuntimeError('allocation meter requires Linux/glibc')
        run(['clang','-O2','-c',R/'Benchmarks/NonDecodePerformance/allocmeter.c','-o',output/'meter.o'],log)
        extra=['-D','ALLOCATION_METER',output/'meter.o']
    manifest={'compiler':run(['swiftc','--version'],log),'platform':platform.platform(),'allocation_instrumented':allocations,'variants':{}}
    if (output/'manifest.json').exists():
        manifest['variants']=json.loads((output/'manifest.json').read_text())['variants']
    for v in variants:
        d=output/v;d.mkdir(exist_ok=True)
        dp=(src/'NativeThumbnailDiskCache.swift' if v=='v4' else H/'baseline'/('NativeThumbnailDiskCacheV3.swift' if v=='v3' else 'NativeThumbnailDiskCacheAccounting.swift'))
        cp=src/'NativeThumbnailCache.swift';disk=dp.read_text();cache=cp.read_text()
        for name in ['CoreGraphics','CryptoKit','IlliquidCore','ImageIO','UniformTypeIdentifiers']:
            disk=disk.replace('import '+name+'\n','');cache=cache.replace('import '+name+'\n','')
        # Replace precisely codec operations, not the cache lookup/inventory logic.
        adapter='''    // TEST CODEC ADAPTER: payload is NOT JPEG; no native ImageIO claims.
    private nonisolated static func readImage(at url: URL, key: Key) -> CGImage? {
        guard let data = try? Data(contentsOf: url), let image = CGImage.decode(data),
              image.width <= key.width, image.height <= key.height else { return nil }
        return image
    }

'''
        if v=='v3':
            start=disk.index('        guard let source = CGImageSourceCreateWithURL')
            end=disk.index('        if !background { promoteDisk(digest) }',start)
            disk=disk[:start]+'''        guard let image = Self.readImage(at: entry.url, key: key)
        else { removeDisk(digest); return nil }
'''+disk[end:]
            at=disk.index('    func insert(');disk=disk[:at]+adapter+disk[at:]
            preferred='files[key.digest]?.background'
        else:
            start=disk.index('    private nonisolated static func readImage(')
            end=disk.index('    private static func filenames',start)
            disk=disk[:start]+adapter+disk[end:]
            preferred='preferredFilename(for: key.digest).flatMap { files[$0]?.background }'
        start=disk.index('    private nonisolated static func encode(')
        end=disk.index('    private func promoteDisk',start)
        disk=disk[:start]+'''    // TEST CODEC ADAPTER ONLY.
    private nonisolated static func encode(_ image: CGImage) -> Data? { image.encoded() }

'''+disk[end:]
        disk+='''\nextension NativeThumbnailDiskCache {
    func testStats() -> (inventoried: Bool, count: Int, bytes: Int) { (loadedDisk, files.count, diskBytes) }
    func testBlock(started: DispatchSemaphore, release: DispatchSemaphore) {
        started.signal(); precondition(release.wait(timeout: .now() + 30) == .success)
    }
    func testIsBackground(_ key: Key) -> Bool? { '''+preferred+''' }
    func testPendingPromotions() -> Int { promotions.pendingCount }
    func testParseFilename(_ name: String) -> String? { Self.parseFilename(name)?.digest }
    func testReservation(_ digest: String) -> Bool {
        if case .accepted = promotions.reserve(digest, epoch: generation) { return true }; return false
    }
    func testReleaseReservations() { promotions.reset(epoch: generation) }
}
'''
        if harness.endswith('InventoryHarness.swift'):
            disk=disk.replace('    func testStats()', '    func testEntryCount() -> Int { files.count }\n    func testStats()')
        cache+='\nextension NativeThumbnailCache { func testDisk() -> NativeThumbnailDiskCache { disk } }\n'
        (d/'Disk.swift').write_text(disk);(d/'Cache.swift').write_text(cache)
        inputs=[d/'Cache.swift',d/'Disk.swift',src/'ThumbnailDiskEvictionHeap.swift',src/'ThumbnailPromotionMailbox.swift',R/'Sources/IlliquidCore/Player/ThumbnailPolicy.swift',R/'Sources/IlliquidCore/Utilities/NonDecodePerformance.swift',R/'Benchmarks/NonDecodeFollowup/PreviewAdapters.swift',H/harness]
        defines=['-D','CANDIDATE'] if v!='v3' else []
        if v=='v4':defines+=['-D','DIRECT_LOOKUP']
        libs=['-lcrypto'] if platform.system()=='Linux' else []
        run(['swiftc','-Onone' if debug else '-O','-swift-version','6','-warnings-as-errors',*defines,*extra,*inputs,*libs,'-o',d/'disk'],log)
        manifest['variants'][v]={'inputs':{str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in [cp,dp,*inputs]},'binary_sha256':hashlib.sha256((d/'disk').read_bytes()).hexdigest()}
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2))
    return manifest

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=pathlib.Path,required=True)
    p.add_argument('--variants',default='v3,accounting,v4');p.add_argument('--allocations',action='store_true');p.add_argument('--debug',action='store_true')
    a=p.parse_args()
    if a.output.exists() and any(a.output.iterdir()):p.error('output must be new or empty')
    build(a.output,variants=a.variants.split(','),allocations=a.allocations,debug=a.debug)
