#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/md5.h>
#include <libavutil/samplefmt.h>

/* Verification-only: raw decoder samples in [target,target+40ms) and the
 * following 160ms, without resampling, audio output, or any native timing policy. */
static void check(int r,const char *name) { if (r < 0) { char s[128]; av_strerror(r,s,sizeof(s)); fprintf(stderr,"%s: %s\n",name,s); exit(1); } }
static void mask(AVFormatContext *f,int selected,int on) { for(unsigned i=0;i<f->nb_streams;i++)f->streams[i]->discard=on&&(int)i!=selected?AVDISCARD_ALL:AVDISCARD_DEFAULT; }
static void finish(struct AVMD5 *m,char hex[33]) { unsigned char digest[16];av_md5_final(m,digest);for(int i=0;i<16;i++)sprintf(hex+2*i,"%02x",digest[i]);av_free(m); }
int main(int argc,char **argv) {
 if(argc!=5) { fprintf(stderr,"usage: audio_seek_probe file stream-ordinal all|selected|read-only relative-target\n");return 2; }
 av_log_set_level(AV_LOG_ERROR);
 AVFormatContext *f=NULL;check(avformat_open_input(&f,argv[1],NULL,NULL),"open");check(avformat_find_stream_info(f,NULL),"probe");
 int ordinal=atoi(argv[2]),index=-1;for(unsigned i=0;i<f->nb_streams;i++)if(f->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO&&ordinal--==0){index=(int)i;break;}
 if(index<0)return 3;AVStream *stream=f->streams[index];const AVCodec *codec=avcodec_find_decoder(stream->codecpar->codec_id);if(!codec)return 4;
 AVCodecContext *dec=avcodec_alloc_context3(codec);if(!dec)return 1;check(avcodec_parameters_to_context(dec,stream->codecpar),"params");dec->pkt_timebase=stream->time_base;check(avcodec_open2(dec,codec,NULL),"decoder");
 int selected=strcmp(argv[3],"all")!=0,sandwich=!strcmp(argv[3],"read-only");if(selected&&!sandwich&&strcmp(argv[3],"selected"))return 2;
 int64_t origin=f->start_time==AV_NOPTS_VALUE?0:f->start_time,target=origin+(int64_t)llround(atof(argv[4])*AV_TIME_BASE);
 mask(f,index,selected&&!sandwich);check(avformat_seek_file(f,-1,INT64_MIN,target,INT64_MAX,AVSEEK_FLAG_BACKWARD),"seek");avformat_flush(f);mask(f,index,selected);
 AVPacket *packet=av_packet_alloc();AVFrame *frame=av_frame_alloc();struct AVMD5 *early=av_md5_alloc(),*late=av_md5_alloc();if(!packet||!frame||!early||!late)return 1;av_md5_init(early);av_md5_init(late);
 int64_t early_samples=0,late_samples=0,first_packet=AV_NOPTS_VALUE,first_sample=AV_NOPTS_VALUE;int eof=0,done=0,packets=0,frames=0;
 while(!done) {
  int r=av_read_frame(f,packet);if(r==AVERROR_EOF){eof=1;check(avcodec_send_packet(dec,NULL),"drain");}else{check(r,"read");if(packet->stream_index!=index){av_packet_unref(packet);continue;}if(!packets)first_packet=av_rescale_q(packet->pts,stream->time_base,AV_TIME_BASE_Q);packets++;check(avcodec_send_packet(dec,packet),"send");av_packet_unref(packet);}
  for(;;) {
   r=avcodec_receive_frame(dec,frame);if(r==AVERROR(EAGAIN)||r==AVERROR_EOF)break;check(r,"receive");frames++;
   if(frame->best_effort_timestamp==AV_NOPTS_VALUE||frame->sample_rate<=0||frame->ch_layout.nb_channels<=0)return 5;
   int bytes=av_get_bytes_per_sample(frame->format),planar=av_sample_fmt_is_planar(frame->format),channels=frame->ch_layout.nb_channels;if(bytes<=0)return 6;
   int64_t start=av_rescale_q(frame->best_effort_timestamp,stream->time_base,AV_TIME_BASE_Q);
   for(int s=0;s<frame->nb_samples;s++) {
    int64_t at=start+av_rescale_q(s,(AVRational){1,frame->sample_rate},AV_TIME_BASE_Q);
    if(at<target)continue;if(at>=target+200000){done=1;break;}if(first_sample==AV_NOPTS_VALUE)first_sample=at;
    struct AVMD5 *h=at<target+40000?early:late;if(at<target+40000)early_samples++;else late_samples++;
    for(int ch=0;ch<channels;ch++){const uint8_t *data=planar?frame->extended_data[ch]+(size_t)s*bytes:frame->extended_data[0]+((size_t)s*channels+ch)*bytes;av_md5_update(h,data,(size_t)bytes);}
   }
   av_frame_unref(frame);if(done)break;
  }
  if(eof)break;
 }
 char a[33],b[33];finish(early,a);finish(late,b);
 printf("{\"ffmpeg\":\"%s\",\"mode\":\"%s\",\"selected_index\":%d,\"target_us\":%"PRId64",\"first_packet_us\":%"PRId64",\"first_sample_us\":%"PRId64",\"early_samples\":%"PRId64",\"late_samples\":%"PRId64",\"early_md5\":\"%s\",\"late_md5\":\"%s\",\"packets\":%d,\"frames\":%d,\"sample_rate\":%d,\"sample_format\":%d}\n",av_version_info(),argv[3],index,target,first_packet,first_sample,early_samples,late_samples,a,b,packets,frames,dec->sample_rate,dec->sample_fmt);
 av_packet_free(&packet);av_frame_free(&frame);avcodec_free_context(&dec);avformat_close_input(&f);return early_samples>0&&late_samples>0?0:7;
}
