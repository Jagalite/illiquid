import CFFmpeg
import Foundation

@main struct Probe {
    static func main() throws {
        let a=CommandLine.arguments
        guard a.count == 6 else { fatalError("probe <file> <audio|subtitle|all|absent> <full|horizon|resume> <direct|executor> <generation>") }
        let url=URL(fileURLWithPath:a[1]), role=a[2], mode=a[3], route=a[4], generation=Int(a[5])!
        let setup=DispatchTime.now().uptimeNanoseconds
        let demux:FFmpegDemuxer? = route == "direct" ? try FFmpegDemuxer(url:url) : nil
        let input:FFmpegInputExecutor? = route == "executor" ? try FFmpegInputExecutor(url:url) : nil
        let info=demux?.mediaInfo ?? input!.mediaInfo
        let selected:Int32 = role == "subtitle" ? info.subtitle : role == "audio" ? info.audio : -999
        precondition(role == "all" || role == "absent" || selected >= 0,"Missing selected stream")
        func bytes()->Int64 { demux?.labBytes ?? input!.labBytes }
        func next() throws -> FFmpegPacketReadStep? {
            if role == "all" {
                return try (demux != nil ? demux!.readPacket(generation:generation) : input!.readPacket(generation:generation)).map(FFmpegPacketReadStep.packet)
            }
            return try demux != nil ? demux!.readPacketStep(generation:generation,keepingStream:selected) : input!.readPacketStep(generation:generation,keepingStream:selected)
        }
        let setupNS=DispatchTime.now().uptimeNanoseconds-setup
        let initialBytes=bytes()
        var total=0, kept=0, progress=0, selectedBytes=0, terminal="EOF", generationOK=true
        var boundaries:[[String:Any]]=[]
        var horizon=mode == "full" ? Double.infinity : 30.0
        var pending:FFmpegPacketReadStep?
#if VERIFY
        var packets:[[String:Any]]=[], events:[[String:Any]]=[]
#endif
        let cpu=lab_cpu_seconds(), start=DispatchTime.now().uptimeNanoseconds
#if METER
        meter_begin()
#endif
        while true {
            let step:FFmpegPacketReadStep
            if let held=pending { step=held;pending=nil }
            else {
                guard let read=try next() else { break };step=read;total+=1
                generationOK = generationOK && step.generation == generation
                if step.packet == nil { progress+=1 }
#if VERIFY
                let index:Int32, pts:Int64, dts:Int64, tb:FFmpegRational
                switch step {
                case .packet(let p):index=p.streamIndex;pts=p.presentationTimestamp;dts=p.decodeTimestamp;tb=p.timeBase
                case .progress(let p):index=p.streamIndex;pts=p.presentationTimestamp;dts=p.decodeTimestamp;tb=p.timeBase
                }
                events.append(["stream":index,"pts":pts,"dts":dts,"num":tb.numerator,"den":tb.denominator,"generation":step.generation])
#endif
            }
            if let t=step.decodeSeconds ?? step.presentationSeconds,t.isFinite,t-info.startTime > horizon {
                boundaries.append(["horizon":horizon,"timestamp":t-info.startTime,"bytes":bytes()-initialBytes,"events":total])
                if mode == "horizon" {terminal="horizon";break}
                pending=step;horizon = horizon == 30 ? 40 : horizon == 40 ? 55 : .infinity;continue
            }
            guard let packet=step.packet, role == "all" || packet.streamIndex == selected else { continue }
            kept+=1;selectedBytes+=packet.byteCount
#if VERIFY
            var chars=[CChar](repeating:0,count:65);lab_hash_packet(packet.pointer!,&chars)
            let hash=chars.withUnsafeBufferPointer {String(cString:$0.baseAddress!)}
            packets.append(["stream":packet.streamIndex,"pts":packet.presentationTimestamp,"dts":packet.decodeTimestamp,"duration":packet.duration,"size":packet.byteCount,"generation":packet.generation,"num":packet.timeBase.numerator,"den":packet.timeBase.denominator,"corrupt":packet.isCorrupt,"key":packet.isKeyframe,"hash":hash])
#endif
        }
#if METER
        meter_end()
#endif
        let elapsed=DispatchTime.now().uptimeNanoseconds-start, cpuSeconds=lab_cpu_seconds()-cpu, finalBytes=bytes()-initialBytes
        var output:[String:Any]=["file":url.lastPathComponent,"role":role,"mode":mode,"route":route,"events":total,"kept":kept,"progress":progress,"selectedBytes":selectedBytes,"readBytes":finalBytes,"setupNS":setupNS,"elapsedNS":elapsed,"cpuSeconds":cpuSeconds,"terminal":terminal,"boundaries":boundaries,"generationOK":generationOK]
#if VERIFY
        output["packets"]=packets;output["eventSequence"]=events
        if terminal == "EOF" { output["repeatedEOF"] = try next() == nil && next() == nil }
#endif
#if METER
        output["allocationRequests"]=meter_requests();output["allocationBytes"]=meter_bytes()
#endif
        let data=try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self))
    }
}
