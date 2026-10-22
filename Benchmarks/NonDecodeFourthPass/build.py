#!/usr/bin/env python3
"""Build the exact disk actor except image codecs, with explicit file-based adapters.
Never replaces image(for:); first-access control flow remains production code.
"""
import hashlib,json,pathlib,platform,re,subprocess,time
H=pathlib.Path(__file__).resolve().parent
R=H.parent.parent

# Only these immutable historical inputs predate the bounded encoded-byte reader.
LEGACY_DISK_FIXTURES = {
    'Benchmarks/NonDecodeFollowup/fixtures/NativeThumbnailDiskCache.swift':
        '71055048cf4471affa3244d553854d226b30e6ba540880d341d3812226a62ba1',
    'Benchmarks/NonDecodeThirdPass/baseline/NativeThumbnailDiskCacheV2.swift':
        'e987a58eebf9c10196df821090a45b72ca87b45218a63a89f82810a9aa7de3c3',
    'Benchmarks/NonDecodeFourthPass/baseline/NativeThumbnailDiskCacheV3.swift':
        'dad57684693eca74860cd343be6a1a9d74e327f5613e89a6674c10e5bd296c4b',
    'Benchmarks/NonDecodeFourthPass/baseline/NativeThumbnailDiskCacheAccounting.swift':
        'f4834d1e07bdc16e053cb301717d5e2fb0b3ba8999ffd3c6c38bd56cfd8df36b',
}

def disk_function(source, name):
    """Match one complete actor function, never consume a following helper.

    These source fixtures indent function bodies by eight spaces. Fail closed
    if that layout or the declaration changes instead of guessing a boundary.
    """
    declarations = re.findall(r'\bfunc\s+' + re.escape(name) + r'\s*\(', source)
    pattern = (r'^    (?:private |internal )?(?:nonisolated )?(?:static )?func '
               + re.escape(name) + r'\([^\n]*\)[^\n]* \{\n'
               r'(?P<body>(?:        [^\n]*\n|\n)*)    \}$')
    matches = list(re.finditer(pattern, source, re.MULTILINE))
    if len(declarations) != 1 or len(matches) != 1:
        raise ValueError(f'Expected one unambiguous {name} function')
    return matches[0]

def adapt_disk_codecs(disk, source_path):
    """Replace only codec work; retain lookup, byte reads and accounting."""
    relative_path = pathlib.Path(source_path).resolve().relative_to(R).as_posix()
    legacy_hash = LEGACY_DISK_FIXTURES.get(relative_path)
    if legacy_hash is not None and hashlib.sha256(disk.encode()).hexdigest() != legacy_hash:
        raise ValueError(f'Historical disk fixture changed: {relative_path}')
    image = disk_function(disk, 'image')
    if re.search(r'\bfunc\s+readImage\s*\(', disk):
        decoder = disk_function(disk, 'readImage')
        if re.search(r'\bfunc\s+readEncodedImage\s*\(', disk):
            disk_function(disk, 'readEncodedImage')
            read = 'readEncodedImage(at: url)'
        elif legacy_hash is not None:
            read = 'try? Data(contentsOf: url)'
        else:
            raise ValueError('Current disk source must retain readEncodedImage')
        body = '''        // TEST CODEC ADAPTER: payload is NOT JPEG; retain the source byte reader.
        guard let data = ''' + read + ''', let image = CGImage.decode(data),
              image.width <= key.width, image.height <= key.height else { return nil }
        return image
'''
        disk = disk[:decoder.start('body')] + body + disk[decoder.end('body'):]
    elif legacy_hash is not None:
        # The v1/v2/v3 fixtures decode inline. Keep their empty-cache fast path,
        # signposts, failed-decode removal and promotion exactly as recorded.
        codec = '''        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width <= key.width, height <= key.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
'''
        if image.group('body').count(codec) != 1:
            raise ValueError('Expected one historical inline decoder')
        start = disk.index(codec, image.start('body'))
        disk = disk[:start] + '''        // TEST CODEC ADAPTER: historical fixtures read the whole payload.
        guard let data = try? Data(contentsOf: entry.url), let image = CGImage.decode(data),
              image.width <= key.width, image.height <= key.height
''' + disk[start + len(codec):]
    else:
        raise ValueError('Current disk source must retain readImage')
    encoder = disk_function(disk, 'encode')
    return disk[:encoder.start('body')] + '''        // TEST CODEC ADAPTER ONLY.
        return image.encoded()
''' + disk[encoder.end('body'):]

def run(cmd, log, timeout=180):
    cmd=list(map(str,cmd));t=time.monotonic()
    proc=subprocess.run(cmd,text=True,capture_output=True,timeout=timeout)
    with log.open('a') as f:f.write(json.dumps(dict(command=cmd,returncode=proc.returncode,stdout=proc.stdout,stderr=proc.stderr,wall_seconds=time.monotonic()-t))+'\n')
    if proc.returncode:raise RuntimeError(proc.stderr or proc.stdout)
    return proc.stdout

def build(output, harness='DiskHarness.swift', variants=('v3','accounting','v4'), allocations=False, debug=False):
    if any(v not in ('v3','accounting','v4') for v in variants):
        raise ValueError('Unknown disk source variant')
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
        cp=src/'NativeThumbnailCache.swift';disk=adapt_disk_codecs(dp.read_text(),dp);cache=cp.read_text()
        for name in ['CoreGraphics','CryptoKit','IlliquidCore','ImageIO','UniformTypeIdentifiers']:
            disk=disk.replace('import '+name+'\n','');cache=cache.replace('import '+name+'\n','')
        if v=='v3':
            preferred='files[key.digest]?.background'
        else:
            preferred='preferredFilename(for: key.digest).flatMap { files[$0]?.background }'
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
