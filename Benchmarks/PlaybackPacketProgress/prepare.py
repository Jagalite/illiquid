#!/usr/bin/env python3
"""Compile real Swift read/executor/gate code against FFmpeg; no macOS renderer.
Requires a full PR #5-compatible checkout, FFmpeg 8.1.2 headers/libs,
and a NEW output directory. A narrow media-info projection replaces UI metadata;
subtitle reconstruction is an uncalled trap. The experimental patch is applied
only to an isolated copy; main packet reads remain unchanged.
"""
import argparse, hashlib, json, pathlib, shutil, subprocess
HERE=pathlib.Path(__file__).resolve().parent

def block(s, token):
    i=s.index(token); j=s.index('{',i); k=j+1; depth=1
    while depth:
        depth+=(s[k]=='{')-(s[k]=='}');k+=1
    return s[i:k]

def run(cmd, log):
    p=subprocess.run(cmd,capture_output=True,text=True,timeout=240)
    with log.open('a') as f: f.write(json.dumps({'command':list(map(str,cmd)),'returncode':p.returncode})+'\n'+p.stdout+p.stderr+'\n')
    if p.returncode:raise RuntimeError('Build failed; see '+str(log))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--repo',type=pathlib.Path,default=HERE.parents[1]);p.add_argument('--prefix',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
    repo,prefix,out=a.repo.resolve(),a.prefix.resolve(),a.output.resolve();out.mkdir(parents=True,exist_ok=False)
    src=repo/'Sources/IlliquidNativePlayback';(out/'CFFmpeg').mkdir();log=out/'build.log'
    # Refuse a stale baseline: PR #5 already removes the second AVPacket header.
    expected={'FFmpegDemuxer.swift':'0fb75688f7bbdfb6c1e3bfab0000a7241b5680a7','FFmpegPacket.swift':'be28cdb3b568fa9adf7b9bf0da8a74bc2d715d4d'}
    for name, want in expected.items():
        data=(src/'Media'/name).read_bytes()
        if hashlib.sha1(f'blob {len(data)}\0'.encode()+data).hexdigest()!=want:
            raise SystemExit('Review changed baseline before benchmarking: '+name)
    candidate=out/'native-candidate/Sources/IlliquidNativePlayback'
    (candidate/'Media').mkdir(parents=True)
    for name in ['FFmpegDemuxer.swift','FFmpegInputExecutor.swift','MediaSession.swift']:
        shutil.copy2(src/'Media'/name,candidate/'Media'/name)
    patch=(HERE/'native-candidate.patch').resolve()
    run(['git','-C',str(out/'native-candidate'),'apply','--check',str(patch)],log)
    run(['git','-C',str(out/'native-candidate'),'apply',str(patch)],log)
    shim=(repo/'Sources/CFFmpeg/include/ffmpeg_shim.h').read_text()
    header='''#include <libavformat/avformat.h>\n#include <libavcodec/avcodec.h>\n#include <libavutil/sha.h>\n#include <libavutil/mem.h>\n#include <sys/resource.h>\n'''
    for name in ['illiquid_averror_eagain','illiquid_averror_eof','illiquid_averror_nomem','illiquid_averror_unknown','illiquid_averror_invaliddata','illiquid_averror_exit','illiquid_packet_is_corrupt','illiquid_packet_is_keyframe']:
        header+=block(shim,'static inline int '+name+'(')+'\n'
    header+='typedef int (*illiquid_interrupt_callback)(void *opaque);\n'+block(shim,'static inline AVFormatContext *illiquid_alloc_interruptible_format_context(')+'\n'+block(shim,'static inline int64_t illiquid_nopts_value(')+'\n'
    header+='''static inline double lab_cpu_seconds(void) {struct rusage r; getrusage(RUSAGE_SELF,&r);return r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6;}
static inline void lab_hash_packet(const AVPacket *p, char *out) {
    struct AVSHA *sha=av_sha_alloc(); av_sha_init(sha,256);
    if(p->size>0) av_sha_update(sha,p->data,p->size);
    for(int i=0;i<p->side_data_elems;i++) {
        int type=p->side_data[i].type; size_t n=p->side_data[i].size;
        av_sha_update(sha,(const unsigned char*)&type,sizeof(type));
        av_sha_update(sha,(const unsigned char*)&n,sizeof(n));
        if(n) av_sha_update(sha,p->side_data[i].data,n);
    }
    unsigned char hash[32];av_sha_final(sha,hash);av_free(sha);
    static const char chars[]="0123456789abcdef";
    for(int i=0;i<32;i++){out[2*i]=chars[hash[i]>>4];out[2*i+1]=chars[hash[i]&15];}out[64]=0;
}
void meter_begin(void); void meter_end(void); unsigned long long meter_requests(void); unsigned long long meter_bytes(void);
'''
    (out/'CFFmpeg/shim.h').write_text(header)
    (out/'CFFmpeg/module.modulemap').write_text('module CFFmpeg [system] { header "shim.h" export * }\n')
    time=(src/'Media/MediaTime.swift').read_text()
    common='import CFFmpeg\nimport Foundation\n'+block(time,'struct FFmpegRational')+'\nenum MediaTime {\n'+block(time,'    static func seconds(')+'\n}\n'
    common+='''struct FFmpegMediaInfo: Sendable { let startTime: Double; let audio: Int32; let subtitle: Int32; let video: Int32 }
'''
    (out/'TimeAndInfo.swift').write_text(common)
    for f in ['FFmpegPacket.swift','FFmpegError.swift','FFmpegPacketReadStep.swift','MediaReadAheadGate.swift']:
        shutil.copy2((candidate if f=='FFmpegPacketReadStep.swift' else src)/'Media'/f,out/f)
    for f in ['PacketQueue.swift','FixedRingBuffer.swift']:
        shutil.copy2(src/'Playback'/f,out/f)
    shutil.copy2(HERE/'Probe.swift',out/'Probe.swift')
    shutil.copy2(HERE/'Regression.swift',out/'Regression.swift')
    shutil.copy2(repo/'Benchmarks/NonDecodePerformance/allocmeter.c',out/'allocmeter.c')
    run(['clang','-O2','-c',str(out/'allocmeter.c'),'-o',str(out/'allocmeter.o')],log)
    sources={str(f.relative_to(repo)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (src/'Media').glob('*.swift') if f.name in ['FFmpegDemuxer.swift','FFmpegInputExecutor.swift','FFmpegPacketReadStep.swift','FFmpegPacket.swift','MediaTime.swift','MediaReadAheadGate.swift']}
    for v in ['baseline','candidate']:
        raw=((src if v=='baseline' else candidate)/'Media/FFmpegDemuxer.swift').read_text()
        if v=='candidate':
            original=(src/'Media/FFmpegDemuxer.swift').read_text()
            assert block(raw,'    func readPacket(generation:')==block(original,'    func readPacket(generation:')
        d=raw[:raw.index('    /// Consult only the demuxer')]
        d+=block(raw,'    func seek(to seconds:')+'\n'+block(raw,'    static func clearInterruptedReadState(')+'\n'+block(raw,'    func codecParameters(')+'\n'+block(raw,'    func codecPrivateData(')+'\n'
        d+='''    private static func makeMediaInfo(url: URL, context: UnsafeMutablePointer<AVFormatContext>) -> FFmpegMediaInfo {
        func first(_ type: AVMediaType)->Int32 {
            for i in 0..<Int(context.pointee.nb_streams) {
                if context.pointee.streams[i]?.pointee.codecpar?.pointee.codec_type == type { return Int32(i) }
            };return -1
        }
        return FFmpegMediaInfo(startTime: context.pointee.start_time == illiquid_nopts_value() ? 0 : Double(context.pointee.start_time)/Double(AV_TIME_BASE),audio:first(AVMEDIA_TYPE_AUDIO),subtitle:first(AVMEDIA_TYPE_SUBTITLE),video:first(AVMEDIA_TYPE_VIDEO))
    }
    func activeSubtitlePackets(streamIndex: Int32, at seconds: Double, generation: Int) throws -> [FFmpegPacket] { fatalError("Not exercised: native subtitle acquisition is outside this harness") }
    var labBytes: Int64 { bytesRead }
    var labContext: UnsafeMutablePointer<AVFormatContext>? { context }
'''
        if v=='baseline':d+='''    func readPacketStep(generation: Int, keepingStream: Int32?) throws -> FFmpegPacketReadStep? { try readPacket(generation:generation).map(FFmpegPacketReadStep.packet) }
'''
        # Deterministic read faults in regression binaries only. Counter-free timing
        # executes av_read_frame directly, without this test seam or extra branch.
        needle='            let result = av_read_frame(context, temporary)'
        assert d.count(needle)==(1 if v=='baseline' else 2)
        d=d.replace(needle,'''#if REGRESSION
            let result = labRead?(context, temporary) ?? av_read_frame(context, temporary)
#else
'''+needle+'''\n#endif''')
        d+='''#if REGRESSION
    var labRead: ((UnsafeMutablePointer<AVFormatContext>,UnsafeMutablePointer<AVPacket>)->Int32)?
#endif
}\n'''
        (out/(v+'-Demuxer.swift')).write_text(d)
        e=(candidate/'Media/FFmpegInputExecutor.swift').read_text() # exact candidate API; original behavior still available
        e=e.replace('    func seek(to seconds: Double, exact: Bool) throws {','''    var labBytes: Int64 { queue.sync { demuxer?.bytesRead ?? 0 } }
    func seek(to seconds: Double, exact: Bool) throws {''',1)
        (out/(v+'-Executor.swift')).write_text(e)
        core=[out/(v+'-Demuxer.swift'),out/(v+'-Executor.swift')]+[out/f for f in ['TimeAndInfo.swift','FFmpegPacket.swift','FFmpegError.swift','FFmpegPacketReadStep.swift','MediaReadAheadGate.swift','PacketQueue.swift','FixedRingBuffer.swift']]
        base=['swiftc','-swift-version','6','-warnings-as-errors','-I'+str(out/'CFFmpeg'),'-Xcc','-I'+str(prefix/'include')]
        libs=['-L'+str(prefix/'lib'),'-lavformat','-lavcodec','-lavutil','-lm','-lpthread']
        for mode in ['timing','verify','allocations','regression','regression-debug']:
            flag=['-Onone'] if mode.endswith('debug') else ['-O']
            defs=['-D','BASELINE'] if v=='baseline' else []
            if mode.startswith('regression'): defs+=['-D','REGRESSION'];mainfile=out/'Regression.swift'
            else:
                mainfile=out/'Probe.swift'
                if mode=='verify': defs+=['-D','VERIFY']
                if mode=='allocations': defs+=['-D','METER']
            obj=[str(out/'allocmeter.o')] if mode=='allocations' else []
            run(base+flag+defs+list(map(str,core))+[str(mainfile)]+obj+libs+['-o',str(out/(v+'-'+mode))],log)
    manifest={'sources':sources,'swift':subprocess.check_output(['swiftc','--version'],text=True),'binaries':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.iterdir() if f.is_file() and '-' in f.name and '.' not in f.name}}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(out)
if __name__=='__main__':main()
