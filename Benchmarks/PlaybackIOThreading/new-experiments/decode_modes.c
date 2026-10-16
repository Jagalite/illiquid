#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/md5.h>
#include <libavutil/pixdesc.h>
#include <libavutil/cpu.h>
#include "DecoderFactory.h"

static uint64_t clockns(clockid_t clockid) {
    struct timespec t; if (clock_gettime(clockid,&t)) {perror("clock_gettime");exit(1);}
    return (uint64_t)t.tv_sec*1000000000ULL+(uint64_t)t.tv_nsec;
}
static uint64_t wall(void){return clockns(CLOCK_MONOTONIC);}
static uint64_t cpu(void){return clockns(CLOCK_PROCESS_CPUTIME_ID);}
static void require(int result,const char*what){if(result<0){char e[AV_ERROR_MAX_STRING_SIZE];av_strerror(result,e,sizeof(e));fprintf(stderr,"%s: %s (%d)\n",what,e,result);exit(1);}}
// Linux getrusage high-water RSS can retain the fork/exec launcher floor.
// VmHWM belongs to the current executable's memory map; read outside timed phases.
static long peak_kib(void){
    FILE *f=fopen("/proc/self/status","r"); if(!f){perror("proc status");exit(1);}
    char line[256]; long result=-1;
    while(fgets(line,sizeof(line),f))if(sscanf(line,"VmHWM: %ld kB",&result)==1)break;
    fclose(f);if(result<0){fprintf(stderr,"VmHWM unavailable\n");exit(1);}return result;
}

static uint64_t arrival_interval_ns = 0;
static void wait_until(uint64_t deadline) {
    for (;;) { uint64_t now=wall(); if(now>=deadline)return; uint64_t remaining=deadline-now; struct timespec t={(time_t)(remaining/1000000000ULL),(long)(remaining%1000000000ULL)}; nanosleep(&t,NULL); }
}
typedef struct Phase {
 const char *name;
 int64_t target_us;
 int keep_limit;
 int decoded, kept, sent, corrupt;
 int first_packets;
 int64_t first_pts, target_pts, last_pts;
 uint64_t start,cpu_start,first_ns,target_ns,total_ns,cpu_ns,seek_ns;
 struct AVMD5 *hash;
 char digest[33];
} Phase;
static void hash_frame(struct AVMD5 *h,const AVFrame *f){
 const AVPixFmtDescriptor *desc=av_pix_fmt_desc_get(f->format);
 if(!desc || (desc->flags & (AV_PIX_FMT_FLAG_HWACCEL|AV_PIX_FMT_FLAG_PAL))){fprintf(stderr,"unsupported checksum format\n");exit(1);}
 char meta[512];int n=snprintf(meta,sizeof(meta),"%d,%d,%d,%"PRId64",%"PRId64",%d,%d,%d,%d,%d,%d;",f->width,f->height,f->format,f->best_effort_timestamp,f->duration,f->color_range,f->color_primaries,f->color_trc,f->colorspace,f->chroma_location,f->flags);
 if(n<0 || n>=(int)sizeof(meta))exit(1);
 av_md5_update(h,(const uint8_t*)meta,(size_t)n);
 const int planes=av_pix_fmt_count_planes(f->format);
 for(int p=0;p<planes;p++){
   int height=f->height;
   if((p==1 || p==2) && !(desc->flags & AV_PIX_FMT_FLAG_RGB))height=AV_CEIL_RSHIFT(height,desc->log2_chroma_h);
   int width=av_image_get_linesize(f->format,f->width,p);require(width,"image linesize");
   for(int y=0;y<height;y++)av_md5_update(h,f->data[p]+(ptrdiff_t)y*f->linesize[p],(size_t)width);
 }
}
static bool receive(AVCodecContext *decoder,AVFrame *frame,AVRational timebase,Phase *s){
 for(;;){
  int r=avcodec_receive_frame(decoder,frame);
  if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)return false;
  require(r,"receive_frame");
  if(frame->best_effort_timestamp==AV_NOPTS_VALUE){fprintf(stderr,"missing frame time\n");exit(1);}
  int64_t pts=av_rescale_q(frame->best_effort_timestamp,timebase,AV_TIME_BASE_Q);
  uint64_t now=wall();s->decoded++;
  if(s->decoded==1){s->first_ns=now-s->start;s->first_pts=pts;s->first_packets=s->sent;}
  if(frame->flags & AV_FRAME_FLAG_CORRUPT)s->corrupt++;
  if(s->target_us<0 || pts>=s->target_us){
    if(s->kept==0){s->target_ns=now-s->start;s->target_pts=pts;}
    s->last_pts=pts;s->kept++;
    if(s->hash)hash_frame(s->hash,frame);
  }
  av_frame_unref(frame);
  if(s->keep_limit && s->kept>=s->keep_limit)return true;
 }
}
static void run_phase(AVFormatContext *fmt,AVCodecContext *dec,int video,AVFrame *frame,Phase *s,bool hashing){
 AVPacket *packet=av_packet_alloc();if(!packet)exit(1);
 if(hashing){s->hash=av_md5_alloc();if(!s->hash)exit(1);av_md5_init(s->hash);}
 s->cpu_start=cpu();s->start=wall();
 if(s->target_us>=0){
  avcodec_flush_buffers(dec);
  // Same global-time seek bounds and flags as the production demuxer.
  require(avformat_seek_file(fmt,-1,INT64_MIN,s->target_us,INT64_MAX,AVSEEK_FLAG_BACKWARD),"seek_file");
  avformat_flush(fmt);
  s->seek_ns=wall()-s->start;
 }
 bool done=false;
 while(!done){
  int r=av_read_frame(fmt,packet);
  if(r==AVERROR_EOF){
    r=avcodec_send_packet(dec,NULL);
    if(r==AVERROR(EAGAIN)){done=receive(dec,frame,fmt->streams[video]->time_base,s);r=avcodec_send_packet(dec,NULL);}
    if(r!=AVERROR_EOF)require(r,"send drain");
    if(!done)receive(dec,frame,fmt->streams[video]->time_base,s);
    break;
  }
  require(r,"read frame");
  if(packet->stream_index==video){
    if(arrival_interval_ns)wait_until(s->start+(uint64_t)s->sent*arrival_interval_ns);
    r=avcodec_send_packet(dec,packet);
    if(r==AVERROR(EAGAIN)){
      done=receive(dec,frame,fmt->streams[video]->time_base,s);
      if(!done)r=avcodec_send_packet(dec,packet);
    }
    if(!done){require(r,"send packet");s->sent++;done=receive(dec,frame,fmt->streams[video]->time_base,s);}
  }
  av_packet_unref(packet);
 }
 s->total_ns=wall()-s->start;s->cpu_ns=cpu()-s->cpu_start;
 if(!s->kept || s->corrupt || (s->keep_limit && s->kept!=s->keep_limit)){fprintf(stderr,"incomplete/corrupt phase %s\n",s->name);exit(1);}
 if(s->hash){uint8_t digest[16];av_md5_final(s->hash,digest);for(int i=0;i<16;i++)sprintf(s->digest+2*i,"%02x",digest[i]);av_freep(&s->hash);}
 else strcpy(s->digest,"not-computed");
 av_packet_free(&packet);
}
int main(int argc,char **argv){
 if(argc!=6){fprintf(stderr,"usage: DecodeProbe media 1|2|4 verify|timing frame|slice|default packet-arrival-microseconds\n");return 2;}
 laboratory_thread_type=!strcmp(argv[4],"slice")?FF_THREAD_SLICE:!strcmp(argv[4],"frame")?FF_THREAD_FRAME:FF_THREAD_FRAME|FF_THREAD_SLICE;
 arrival_interval_ns=(uint64_t)strtoul(argv[5],NULL,10)*1000;
 if(arrival_interval_ns>100000000ULL)return 2;
 av_log_set_level(AV_LOG_ERROR);
 const char *mode=argv[2];bool automatic=!strcmp(mode,"auto"),defaults=!strcmp(mode,"default"),hashing=!strcmp(argv[3],"verify");
 if(!hashing && strcmp(argv[3],"timing"))return 2;
 int request=0;
 if(!automatic&&!defaults){char *end=NULL;errno=0;long n=strtol(mode,&end,10);if(errno||!end||*end||n<1||n>16)return 2;request=(int)n;}
 AVFormatContext *fmt=NULL;AVCodecContext *dec=NULL;AVFrame *frame=av_frame_alloc();if(!frame)return 1;
 const uint64_t load_start=wall();
 require(avformat_open_input(&fmt,argv[1],NULL,NULL),"open input");uint64_t open_ns=wall()-load_start;
 uint64_t start=wall();require(avformat_find_stream_info(fmt,NULL),"probe");uint64_t probe_ns=wall()-start;
 int video=av_find_best_stream(fmt,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);require(video,"video stream");
 int hardware=0;start=wall();
 if(automatic)require(probe_create_decoder_explicit_auto(fmt->streams[video]->codecpar,0,0,&dec,&hardware),"auto decoder");
 else require(illiquid_create_decoder_with_thread_count(fmt->streams[video]->codecpar,0,request,&dec,&hardware),"production software decoder");
 uint64_t decoder_open_ns=wall()-start;
 if(hardware){fprintf(stderr,"Unexpected hardware route\n");return 1;}
 const int configured=dec->thread_count,active_type=dec->active_thread_type;
 Phase phases[3]={{.name="full",.target_us=-1},{.name="seek-forward",.target_us=1750000,.keep_limit=5},{.name="seek-backward",.target_us=250000,.keep_limit=5}};
 // Container timestamps may start above zero (e.g. MPEG-TS).
 int64_t origin=fmt->start_time==AV_NOPTS_VALUE?0:fmt->start_time;
 phases[1].target_us+=origin;phases[2].target_us+=origin;
 long peak_before=peak_kib();
 for(int p=0;p<3;p++)run_phase(fmt,dec,video,frame,&phases[p],hashing);
 printf("{\"thread_strategy\":\"%s\",\"arrival_interval_ns\":%"PRIu64",\"ffmpeg_version\":\"%s\",\"request\":\"%s\",\"configured_threads\":%d,\"active_thread_type\":%d,\"cpu_count_seen\":%d,\"rss_metric\":\"proc-self-status-VmHWM\",\"codec\":\"%s\",\"width\":%d,\"height\":%d,\"verify\":%s,\"open_ns\":%"PRIu64",\"probe_ns\":%"PRIu64",\"decoder_open_ns\":%"PRIu64",\"peak_rss_before_kib\":%ld,\"peak_rss_after_kib\":%ld,\"phases\":[",argv[4],arrival_interval_ns,av_version_info(),mode,configured,active_type,av_cpu_count(),dec->codec->name,dec->width,dec->height,hashing?"true":"false",open_ns,probe_ns,decoder_open_ns,peak_before,peak_kib());
 for(int p=0;p<3;p++){
  Phase*s=&phases[p];printf("%s{\"name\":\"%s\",\"requested_target_us\":%"PRId64",\"decoded\":%d,\"kept\":%d,\"sent\":%d,\"packets_to_first\":%d,\"first_pts_us\":%"PRId64",\"target_pts_us\":%"PRId64",\"last_pts_us\":%"PRId64",\"first_ns\":%"PRIu64",\"target_ns\":%"PRIu64",\"wall_ns\":%"PRIu64",\"cpu_ns\":%"PRIu64",\"seek_ns\":%"PRIu64",\"corrupt\":%d,\"md5\":\"%s\"}",p?",":"",s->name,s->target_us,s->decoded,s->kept,s->sent,s->first_packets,s->first_pts,s->target_pts,s->last_pts,s->first_ns,s->target_ns,s->total_ns,s->cpu_ns,s->seek_ns,s->corrupt,s->digest);
 }
 puts("]}");av_frame_free(&frame);avcodec_free_context(&dec);avformat_close_input(&fmt);return 0;
}
