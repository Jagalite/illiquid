import CFFmpeg
import Foundation

private final class Box<T>: @unchecked Sendable {
    private let lock=NSLock();private var value:T
    init(_ value:T){self.value=value}
    func withValue<R>(_ body:(inout T)->R)->R {lock.lock();defer{lock.unlock()};return body(&value)}
}
@main struct Regression {
    static func main() throws {
        guard CommandLine.arguments.count==2 else {fatalError("regression <fixture.mkv>")}
        let url=URL(fileURLWithPath:CommandLine.arguments[1]);var count=0
        func check(_ condition:Bool,_ label:String){count+=1;precondition(condition,label)}
        // Value-only metadata cannot own the C packet's reference-counted payload.
        var p:UnsafeMutablePointer<AVPacket>?=av_packet_alloc()!;try checkFFmpeg(av_new_packet(p,8*1024*1024),operation:"test packet")
        p!.pointee.stream_index=3;p!.pointee.pts=45000;p!.pointee.dts=illiquid_nopts_value()
        var retained:UnsafeMutablePointer<AVBufferRef>?=av_buffer_ref(p!.pointee.buf)!
        let progress=FFmpegPacketProgress(packet:UnsafePointer(p!),timeBase:AVRational(num:1,den:1000),generation:42)
        check(av_buffer_get_ref_count(retained)==2,"two owners before packet release")
        av_packet_free(&p)
        check(av_buffer_get_ref_count(retained)==1,"progress retains no payload")
        check(progress.streamIndex==3 && progress.generation==42 && progress.presentationSeconds==45 && progress.decodeSeconds==nil,"metadata survives release")
        av_buffer_unref(&retained)
        let event=FFmpegPacketReadStep.progress(progress)
        check(event.packet==nil && event.generation==42 && event.presentationSeconds==45,"typed progress")
        // Missing or negative timestamps remain observations, not EOF.
        for pts:Int64 in [Int64.min,-50,0,Int64.max] {
            var raw:UnsafeMutablePointer<AVPacket>?=av_packet_alloc()!;raw!.pointee.pts=pts;raw!.pointee.dts=pts
            let m=FFmpegPacketProgress(packet:UnsafePointer(raw!),timeBase:AVRational(num:1,den:1000),generation:7)
            check((m.decodeSeconds==nil)==(pts==Int64.min),"missing DTS exactly preserved")
            av_packet_free(&raw)
        }
        // Exercise the real gate with all-packet progress, reset and close.
        for reset in [true,false] {
            let gate=MediaReadAheadGate();gate.reset(generation:42,position:0)
            let completed=DispatchSemaphore(value:0),answer=Box<Bool?>(nil)
            DispatchQueue.global().async {
                let result=gate.wait(until:event.presentationSeconds,generation:event.generation)
                answer.withValue{$0=result};completed.signal()
            }
            check(gate.waitForBlockedReader(timeout:2),"progress reaches read-ahead gate")
            if reset{gate.reset(generation:43,position:0)}else{gate.close()}
            check(completed.wait(timeout:.now()+2) == .success,"gate wakes control")
            check(answer.withValue{$0}==false,"stale/closed progress rejected")
        }
        // Continue normal EOF waiting until a source-generation reset.
        do {
            let gate=MediaReadAheadGate();gate.reset(generation:1,position:100)
            let done=DispatchSemaphore(value:0)
            DispatchQueue.global().async{_ = gate.wait(until:nil,generation:1);done.signal()}
            check(gate.waitForBlockedReader(timeout:2),"EOF blocks rather than polls")
            gate.reset(generation:2,position:0);check(done.wait(timeout:.now()+2) == .success,"EOF released by seek")
        }
        // The complete actual serialized input executor is used here.
        let preCancelled=FFmpegInputCancellationSignal();preCancelled.requestCancellation()
        do {_ = try FFmpegInputExecutor(url:url,cancellationSignal:preCancelled);check(false,"pre-cancelled open must throw")}
        catch {check((error as? FFmpegInputExecutorError) == .operationCancelled,"cancellation remains distinct from EOF")}
        do {
            let input=try FFmpegInputExecutor(url:url)
            check(!input.openWasPerformedOnMainThread,"open on owning executor")
            let kept=input.mediaInfo.subtitle
            let results=Box([(Int,Int)]()),errors=Box([String]())
            DispatchQueue.concurrentPerform(iterations:8){worker in
                for _ in 0..<32 {
                    do {
                        if let s=try input.readPacketStep(generation:worker,keepingStream:kept) {
                            results.withValue{$0.append((worker,s.generation))}
                        }
                    }catch{errors.withValue{$0.append(String(describing:error))}}
                }
            }
            check(errors.withValue{$0.isEmpty},"concurrent callers serialize without read failure")
            check(results.withValue{$0.count}==256,"all concurrent calls return packet progress")
            check(results.withValue{$0.allSatisfy{$0.0==$0.1}},"generation per operation")
            // Cancel when idle: the subsequent seek owns recovery and clears deferred cancellation.
            _ = input.cancelActiveOperation();try input.seek(to:input.mediaInfo.startTime,exact:true)
            check(try input.readPacketStep(generation:500,keepingStream:kept) != nil,"new seek permits progress")
        }
        // Read errors/terminal-corrupt signals are not hidden by payload suppression.
        for fault in ["exit","eagain","invalid","terminal-corrupt"] {
            let demux=try FFmpegDemuxer(url:url);var calls=0
            demux.labRead={ctx,pkt in
                calls+=1
                if fault=="exit" {return illiquid_averror_exit()}
                if fault=="eagain" {return illiquid_averror_eagain()}
                if fault=="invalid" {return illiquid_averror_invaliddata()}
                if calls==1 {
                    let allocation=av_new_packet(pkt,16)
                    pkt.pointee.stream_index=0;pkt.pointee.pts=1000;pkt.pointee.dts=1000;pkt.pointee.flags=AV_PKT_FLAG_CORRUPT
                    ctx.pointee.pb!.pointee.eof_reached=1
                    return allocation
                }
                return illiquid_averror_eof()
            }
            do {
                if fault=="terminal-corrupt" {check(try demux.readPacketStep(generation:1,keepingStream:99) != nil,"corrupt packet still advances once")}
                _ = try demux.readPacketStep(generation:1,keepingStream:99);check(false,"read must throw for "+fault)
            } catch let e as FFmpegError {
                let expected=fault=="exit" ? illiquid_averror_exit() : fault=="eagain" ? illiquid_averror_eagain() : illiquid_averror_invaliddata()
                check(e.code==expected,"read error preserved")
            }
            check(calls <= (fault=="invalid" ? 257 : fault=="eagain" ? 11 : fault=="terminal-corrupt" ? 2 : 1),"bounded retry")
        }
        // A timing-only handoff must release an unselected payload before a
        // future timestamp blocks the caller. Selected future payloads stay owned.
        var heldCounts:[Int]=[]
        for keepPayload in [false,true] {
            let demux=try FFmpegDemuxer(url:url)
            var observed:UnsafeMutablePointer<AVBufferRef>?
            demux.labRead={ctx,pkt in
                let result=av_new_packet(pkt,8*1024*1024)
                pkt.pointee.stream_index=0;pkt.pointee.pts=45000;pkt.pointee.dts=45000
                ctx.pointee.streams[0]!.pointee.time_base=AVRational(num:1,den:1000)
                observed=av_buffer_ref(pkt.pointee.buf)
                return result
            }
            let step=try demux.readPacketStep(generation:4,keepingStream:keepPayload ? 0 : 99)!
            let gate=MediaReadAheadGate();gate.reset(generation:4,position:0)
            let done=DispatchSemaphore(value:0)
            DispatchQueue.global().async {
                _ = gate.wait(until:step.decodeSeconds,generation:step.generation)
                withExtendedLifetime(step) {};done.signal()
            }
            check(gate.waitForBlockedReader(timeout:2),"future timestamp really blocks")
            let owners=Int(av_buffer_get_ref_count(observed));heldCounts.append(owners)
#if BASELINE
            check(owners==2,"baseline retains both selected and unwanted payload at gate")
#else
            check(owners==(keepPayload ? 2 : 1),"candidate releases only unselected payload before gate")
#endif
            gate.close();check(done.wait(timeout:.now()+2) == .success,"blocked packet released on close")
            withExtendedLifetime(step) {};av_buffer_unref(&observed)
        }
        // Real selected packet remains owned across later reads and input release.
        var retainedPacket:FFmpegPacket?
        do {
            let demux=try FFmpegDemuxer(url:url);let selected=demux.mediaInfo.subtitle
            while let step=try demux.readPacketStep(generation:9,keepingStream:selected) {
                if let packet=step.packet,packet.streamIndex==selected {retainedPacket=packet;break}
            }
            check(retainedPacket != nil,"selected packet exists")
            let original=retainedPacket!.data
            for _ in 0..<100{_ = try demux.readPacketStep(generation:10,keepingStream:selected)}
            check(retainedPacket!.data==original,"owned payload unchanged by later reads")
        }
        check(retainedPacket?.data != nil,"payload survives demux close")
        print("{\"checks\":\(count),\"passed\":true,\"gate_payload_refcounts\":\(heldCounts)}")
    }
}
