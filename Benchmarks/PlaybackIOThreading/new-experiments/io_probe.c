#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <libavformat/avformat.h>
#include <libavutil/md5.h>

typedef struct IO { int fd; uint64_t reads, bytes, seeks, size_queries; unsigned delay_us; } IO;
typedef struct Metrics { uint64_t reads,bytes,seeks; int64_t avio_bytes; } Metrics;
static uint64_t ns(clockid_t id) { struct timespec t; if(clock_gettime(id,&t))exit(1); return (uint64_t)t.tv_sec*1000000000ULL+(uint64_t)t.tv_nsec; }
static void check(int r,const char *s){if(r<0){char e[128];av_strerror(r,e,sizeof(e));fprintf(stderr,"%s: %s (%d)\n",s,e,r);exit(1);}}
static void pause_us(unsigned us){struct timespec t={us/1000000,(long)(us%1000000)*1000};while(nanosleep(&t,&t)&&errno==EINTR){}}
static int read_io(void *p,uint8_t *buf,int size){IO*s=p;if(s->delay_us)pause_us(s->delay_us);s->reads++;ssize_t n;do{n=read(s->fd,buf,(size_t)size);}while(n<0&&errno==EINTR);if(n<0)return AVERROR(errno);if(n==0)return AVERROR_EOF;s->bytes+=(uint64_t)n;return (int)n;}
static int64_t seek_io(void*p,int64_t offset,int whence){IO*s=p;if(whence==AVSEEK_SIZE){struct stat st;s->size_queries++;return fstat(s->fd,&st)?AVERROR(errno):st.st_size;}whence&=~AVSEEK_FORCE;if(whence!=SEEK_SET&&whence!=SEEK_CUR&&whence!=SEEK_END)return AVERROR(EINVAL);off_t old=lseek(s->fd,0,SEEK_CUR),n=lseek(s->fd,(off_t)offset,whence);if(n<0)return AVERROR(errno);if(n!=old)s->seeks++;return n;}
static Metrics snapshot(AVFormatContext*f,IO*i){return (Metrics){i->reads,i->bytes,i->seeks,f->pb?f->pb->bytes_read:0};}
static void delta(const char*name,Metrics a,Metrics b){printf("\"%s\":{\"callback_reads\":%"PRIu64",\"callback_bytes\":%"PRIu64",\"seek_moves\":%"PRIu64",\"avio_bytes\":%"PRId64"}",name,b.reads-a.reads,b.bytes-a.bytes,b.seeks-a.seeks,b.avio_bytes-a.avio_bytes);}
static void finish_hash(struct AVMD5*h,char out[33]){uint8_t d[16];av_md5_final(h,d);for(int i=0;i<16;i++)sprintf(out+2*i,"%02x",d[i]);av_free(h);}
static void hash_packet(struct AVMD5*h,AVPacket*p){char b[256];int n=snprintf(b,sizeof(b),"%d,%"PRId64",%"PRId64",%"PRId64",%d,%d;",p->stream_index,p->pts,p->dts,p->duration,p->flags,p->size);if(n<0||n>=(int)sizeof(b))exit(1);av_md5_update(h,(uint8_t*)b,(size_t)n);av_md5_update(h,p->data,(size_t)p->size);for(int k=0;k<p->side_data_elems;k++){int type=p->side_data[k].type;av_md5_update(h,(uint8_t*)&type,sizeof(type));av_md5_update(h,p->side_data[k].data,p->side_data[k].size);}}
static void metadata(AVFormatContext*f,char out[33]){struct AVMD5*h=av_md5_alloc();if(!h)exit(1);av_md5_init(h);for(unsigned i=0;i<f->nb_streams;i++){AVStream*s=f->streams[i];AVCodecParameters*p=s->codecpar;char b[512];int n=snprintf(b,sizeof(b),"%u,%d,%d,%d,%d,%d,%d,%d,%d,%d,%"PRId64";",i,p->codec_type,p->codec_id,p->width,p->height,p->sample_rate,p->ch_layout.nb_channels,s->time_base.num,s->time_base.den,s->disposition,s->duration);if(n<0||n>=(int)sizeof(b))exit(1);av_md5_update(h,(uint8_t*)b,(size_t)n);if(p->extradata_size>0)av_md5_update(h,p->extradata,(size_t)p->extradata_size);const AVDictionaryEntry*e=NULL;while((e=av_dict_iterate(s->metadata,e))){av_md5_update(h,(const uint8_t*)e->key,strlen(e->key)+1);av_md5_update(h,(const uint8_t*)e->value,strlen(e->value)+1);}}finish_hash(h,out);}
static void mask(AVFormatContext*f,int selected,bool enable){for(unsigned i=0;i<f->nb_streams;i++)f->streams[i]->discard=enable&&(int)i!=selected?AVDISCARD_ALL:AVDISCARD_DEFAULT;}
int main(int argc,char**argv){
 if(argc!=9){fprintf(stderr,"usage: io_probe file audio0|audio1|subtitle|video all|selected|read-only buffer-bytes(0=native) scan|frontier|global|stream target-seconds timing|verify callback-delay-us\n");return 2;}
 const char*role=argv[2],*mode=argv[3],*phase=argv[5];bool selected=!strcmp(mode,"selected")||!strcmp(mode,"read-only"),sandwich=!strcmp(mode,"read-only"),verify=!strcmp(argv[7],"verify");
 if(!selected&&strcmp(mode,"all"))return 2;if(!verify&&strcmp(argv[7],"timing"))return 2;
 int buffer=atoi(argv[4]);if(buffer!=0&&(buffer<4096||buffer>1048576))return 2;
 double target=atof(argv[6]);if(target<0||target>86400)return 2;
 IO input={.fd=-1,.delay_us=(unsigned)atoi(argv[8])};if(input.delay_us>100000||(!buffer&&input.delay_us))return 2;
 AVFormatContext*f=NULL;AVIOContext*io=NULL;av_log_set_level(AV_LOG_ERROR);uint64_t started=ns(CLOCK_MONOTONIC),c0=ns(CLOCK_PROCESS_CPUTIME_ID);
 if(buffer){input.fd=open(argv[1],O_RDONLY);if(input.fd<0){perror("open");return 1;}uint8_t*b=av_malloc((size_t)buffer);if(!b)return 1;io=avio_alloc_context(b,buffer,0,&input,read_io,NULL,seek_io);if(!io){av_free(b);return 1;}f=avformat_alloc_context();if(!f)return 1;f->pb=io;f->flags|=AVFMT_FLAG_CUSTOM_IO;}
 check(avformat_open_input(&f,argv[1],NULL,NULL),"open_input");uint64_t opened=ns(CLOCK_MONOTONIC);Metrics m1=snapshot(f,&input);
 check(avformat_find_stream_info(f,NULL),"stream_info");uint64_t probed=ns(CLOCK_MONOTONIC);Metrics m2=snapshot(f,&input);
 enum AVMediaType wanted=!strcmp(role,"video")?AVMEDIA_TYPE_VIDEO:!strcmp(role,"subtitle")?AVMEDIA_TYPE_SUBTITLE:AVMEDIA_TYPE_AUDIO;int nth=!strcmp(role,"audio1")?1:0,index=-1;
 for(unsigned i=0;i<f->nb_streams;i++)if(f->streams[i]->codecpar->codec_type==wanted&&nth--==0){index=(int)i;break;}
 if(index<0){fprintf(stderr,"Requested role unavailable\n");return 3;}
 if((wanted==AVMEDIA_TYPE_VIDEO&&f->streams[index]->codecpar->width<=0)||(wanted==AVMEDIA_TYPE_AUDIO&&f->streams[index]->codecpar->sample_rate<=0)){fprintf(stderr,"Incomplete metadata\n");return 1;}
 char meta[33];metadata(f,meta);mask(f,index,selected);
 int64_t origin=f->start_time==AV_NOPTS_VALUE?0:f->start_time,requested=origin+(int64_t)(target*AV_TIME_BASE);uint64_t seek_ns=0;
 Metrics m3=snapshot(f,&input);uint64_t read_start=ns(CLOCK_MONOTONIC),cpu_start=ns(CLOCK_PROCESS_CPUTIME_ID);
 if(!strcmp(phase,"global")||!strcmp(phase,"stream")){
  if(sandwich)mask(f,index,false);
  uint64_t s=ns(CLOCK_MONOTONIC);int stream=!strcmp(phase,"stream")?index:-1;int64_t ts=stream<0?requested:av_rescale_q(requested,AV_TIME_BASE_Q,f->streams[index]->time_base);
  check(avformat_seek_file(f,stream,INT64_MIN,ts,stream<0?INT64_MAX:ts,AVSEEK_FLAG_BACKWARD),"seek");avformat_flush(f);seek_ns=ns(CLOCK_MONOTONIC)-s;
  if(sandwich)mask(f,index,true);
 }else if(strcmp(phase,"scan")&&strcmp(phase,"frontier"))return 2;
 AVPacket*p=av_packet_alloc();if(!p)return 1;struct AVMD5*h=verify?av_md5_alloc():NULL;if(h)av_md5_init(h);
 uint64_t returned=0,kept=0,payload=0,ignored=0;int64_t first=AV_NOPTS_VALUE,last=AV_NOPTS_VALUE,crossed=AV_NOPTS_VALUE;int corrupt=0;
 for(;;){int rc=av_read_frame(f,p);if(rc==AVERROR_EOF)break;check(rc,"read");returned++;int64_t time=p->dts!=AV_NOPTS_VALUE?p->dts:p->pts;int64_t us=time==AV_NOPTS_VALUE?AV_NOPTS_VALUE:av_rescale_q(time,f->streams[p->stream_index]->time_base,AV_TIME_BASE_Q);
  if(!strcmp(phase,"frontier")&&us!=AV_NOPTS_VALUE&&us>requested){crossed=us;av_packet_unref(p);break;}
  if(p->stream_index==index){if(!kept)first=us;last=us;kept++;payload+=(uint64_t)p->size;if(p->flags&AV_PKT_FLAG_CORRUPT)corrupt++;if(h)hash_packet(h,p);}else ignored++;
  av_packet_unref(p);
  if(returned>10000000){fprintf(stderr,"Packet budget exceeded\n");return 1;}
 }
 uint64_t elapsed=ns(CLOCK_MONOTONIC)-read_start,cpu_ns=ns(CLOCK_PROCESS_CPUTIME_ID)-cpu_start;Metrics m4=snapshot(f,&input);char md5[33]="not-computed";if(h)finish_hash(h,md5);
 printf("{\"ffmpeg\":\"%s\",\"role\":\"%s\",\"mode\":\"%s\",\"phase\":\"%s\",\"buffer_bytes\":%d,\"callback_delay_us\":%u,\"verify\":%s,\"selected_stream\":%d,\"stream_count\":%u,\"origin_us\":%"PRId64",\"requested_us\":%"PRId64",\"first_us\":%"PRId64",\"last_us\":%"PRId64",\"frontier_cross_us\":%"PRId64",\"returned_packets\":%"PRIu64",\"selected_packets\":%"PRIu64",\"ignored_packets\":%"PRIu64",\"selected_payload_bytes\":%"PRIu64",\"corrupt_packets\":%d,\"metadata_md5\":\"%s\",\"packet_md5\":\"%s\",\"open_ns\":%"PRIu64",\"probe_ns\":%"PRIu64",\"seek_ns\":%"PRIu64",\"read_ns\":%"PRIu64",\"read_cpu_ns\":%"PRIu64",\"through_read_ns\":%"PRIu64",\"through_read_cpu_ns\":%"PRIu64",",av_version_info(),role,mode,phase,buffer,input.delay_us,verify?"true":"false",index,f->nb_streams,origin,requested,first,last,crossed,returned,kept,ignored,payload,corrupt,meta,md5,opened-started,probed-opened,seek_ns,elapsed,cpu_ns,ns(CLOCK_MONOTONIC)-started,ns(CLOCK_PROCESS_CPUTIME_ID)-c0);
 delta("open_io",(Metrics){0},m1);printf(",");delta("probe_io",m1,m2);printf(",");delta("read_io",m3,m4);puts("}");
 av_packet_free(&p);avformat_close_input(&f);if(io){av_freep(&io->buffer);avio_context_free(&io);}if(input.fd>=0)close(input.fd);return 0;
}
