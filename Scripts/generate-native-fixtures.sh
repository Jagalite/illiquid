#!/bin/zsh
set -euo pipefail

fixture_dir="${1:-${PWD}/TestFixtures/Generated}"
mkdir -p "${fixture_dir}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/superplayr-fixtures.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

ffmpeg_bin="${FFMPEG_BIN:-$(command -v ffmpeg)}"
if [[ -z "${ffmpeg_bin}" ]]; then
    print -u2 "ffmpeg is required (brew install ffmpeg)"
    exit 1
fi

common_video=(
    -f lavfi -i "testsrc2=size=640x360:rate=30"
    -f lavfi -i "sine=frequency=440:sample_rate=48000"
    -t 3 -shortest
)

# Frame-threaded decoding may retain this only frame until decoder drain.
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=red:size=64x64:rate=30" -frames:v 1 \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    "${fixture_dir}/single-frame-h264.mp4"

"${ffmpeg_bin}" -hide_banner -loglevel error -y "${common_video[@]}" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac \
    "${fixture_dir}/h264-aac.mp4"

"${ffmpeg_bin}" -hide_banner -loglevel error -y "${common_video[@]}" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac \
    "${fixture_dir}/h264-aac.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y "${common_video[@]}" \
    -c:v libx265 -preset ultrafast -x265-params log-level=error -pix_fmt yuv420p \
    -c:a flac "${fixture_dir}/hevc-flac.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y "${common_video[@]}" \
    -c:v libx265 -preset ultrafast -x265-params log-level=error \
    -pix_fmt yuv420p10le -c:a aac "${fixture_dir}/hevc-10bit-aac.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y "${common_video[@]}" \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p \
    -c:a libopus "${fixture_dir}/vp9-opus.mkv"

if "${ffmpeg_bin}" -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1'; then
    "${ffmpeg_bin}" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=24" -t 1 \
        -c:v libsvtav1 -preset 13 -pix_fmt yuv420p -an \
        "${fixture_dir}/av1-video-only.mkv"
    "${ffmpeg_bin}" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=24" -t 1 \
        -vf "format=yuv420p10le" -c:v libsvtav1 -preset 13 -pix_fmt yuv420p10le -an \
        "${fixture_dir}/av1-10bit-video-only.mkv"
else
    print -u2 "libsvtav1 is required for the AV1 fixture matrix"
    exit 1
fi

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" -t 2 \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -pix_fmt yuv420p10le -an \
    "${fixture_dir}/vp9-10bit-video-only.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" -t 3 \
    -c:v libx264 -preset ultrafast -g 24 -keyint_min 24 -sc_threshold 0 -an \
    "${fixture_dir}/cfr-control.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -t 3 -map 0:v -map 1:a -map 2:a -c:v libx264 -preset veryfast \
    -c:a aac -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn \
    "${fixture_dir}/multiple-audio.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" \
    -f lavfi -i "sine=frequency=880:sample_rate=48000" \
    -t 3 -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast \
    -c:a aac -disposition:a:0 default -disposition:a:1 0 -disposition:a:2 comment \
    -metadata:s:a:0 language=eng -metadata:s:a:0 title=Main \
    -metadata:s:a:1 language=jpn -metadata:s:a:1 title=Alternate \
    -metadata:s:a:2 language=eng -metadata:s:a:2 title=Commentary \
    "${fixture_dir}/multiple-audio-flags.mkv"

printf '%s\n' \
    '1' '00:00:00,300 --> 00:00:01,500' 'Synthetic SRT subtitle' '' \
    '2' '00:00:01,600 --> 00:00:02,800' 'Seek and timing check' \
    > "${fixture_dir}/external.srt"

printf '%s\n' \
    '[Script Info]' 'ScriptType: v4.00+' 'PlayResX: 640' 'PlayResY: 360' '' \
    '[V4+ Styles]' \
    'Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding' \
    'Style: Default,Arial,30,&H00FFFFFF,&H0000FFFF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,24,1' '' \
    '[Events]' \
    'Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text' \
    'Dialogue: 0,0:00:00.20,0:00:02.80,Default,,0,0,0,,{\k30}Na{\k30}tive {\bord4\shad2}ASS animation' \
    > "${fixture_dir}/external.ass"

printf '%s\n' \
    '[Script Info]' 'ScriptType: v4.00' 'PlayResX: 640' 'PlayResY: 360' '' \
    '[V4 Styles]' \
    'Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,TertiaryColour,BackColour,Bold,Italic,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,AlphaLevel,Encoding' \
    'Style: Default,Arial,28,&HFFFFFF,&H00FFFF,&H000000,&H000000,0,0,1,2,1,2,20,20,24,0,1' '' \
    '[Events]' \
    'Format: Marked,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text' \
    'Dialogue: Marked=0,0:00:00.25,0:00:02.50,Default,,0,0,0,,Synthetic SSA subtitle' \
    > "${fixture_dir}/external.ssa"

printf '%s\n' \
    'WEBVTT' '' \
    '00:00:00.300 --> 00:00:01.500 line:85% position:50% align:center' \
    '<b>Synthetic</b> WebVTT subtitle' '' \
    '00:00:01.600 --> 00:00:02.800' 'UTF-8: Καλημέρα 世界' \
    > "${fixture_dir}/external.vtt"

printf '%s\n' \
    '[Script Info]' 'ScriptType: v4.00+' 'PlayResX: 640' 'PlayResY: 360' '' \
    '[V4+ Styles]' \
    'Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding' \
    'Style: Default,Superplayr Fixture Missing Font,30,&H00FFFFFF,&H0000FFFF,&H00101010,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,24,1' '' \
    '[Events]' \
    'Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text' \
    'Dialogue: 0,0:00:00.20,0:00:02.80,Default,,0,0,0,,Missing font and glyph fallback: A \U00010FFFD' \
    > "${fixture_dir}/missing-glyph.ass"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "${fixture_dir}/h264-aac.mkv" -i "${fixture_dir}/external.srt" \
    -map 0 -map 1 -c copy -metadata:s:s:0 language=eng \
    "${fixture_dir}/embedded-srt.mkv"

# Use the bundled OFL font; never attach a macOS system font to a fixture.
script_dir="${0:A:h}"
font_path="${script_dir}/../TestFixtures/Fonts/NotoSans-Regular.ttf"
if [[ ! -f "${font_path}" ]]; then
    print -u2 "Missing licensed fixture font: ${font_path}"
    exit 1
fi
# Make the embedded subtitle select the attached font rather than a system font.
sed 's/Style: Default,Arial,/Style: Default,Noto Sans,/' \
    "${fixture_dir}/external.ass" > "${work_dir}/embedded-font.ass"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "${fixture_dir}/h264-aac.mkv" -i "${work_dir}/embedded-font.ass" \
    -map 0 -map 1 -c copy -attach "${font_path}" \
    -metadata:s:s:0 language=eng \
    -metadata:s:t:0 mimetype=application/x-truetype-font \
    -metadata:s:t:0 filename=NotoSans-Regular.ttf \
    "${fixture_dir}/embedded-ass-font.mkv"
cp "${script_dir}/../TestFixtures/Fonts/OFL.txt" "${fixture_dir}/embedded-ass-font.OFL.txt"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 3 -c:a flac \
    "${fixture_dir}/audio-only.flac"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=550:sample_rate=48000" -t 3 -c:a libopus \
    "${fixture_dir}/audio-only-opus.mka"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" -t 3 \
    -af "aformat=channel_layouts=stereo" -c:a vorbis -strict -2 \
    "${fixture_dir}/audio-only-vorbis.ogg"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=770:sample_rate=44100" -t 3 -c:a libmp3lame \
    "${fixture_dir}/audio-only.mp3"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=880:sample_rate=44100" -t 3 -c:a pcm_s16le \
    "${fixture_dir}/audio-only-pcm.wav"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" -t 3 \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -an \
    "${fixture_dir}/video-only.mp4"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" -t 3 \
    -vf "select='not(mod(n,7)) + not(mod(n,11))'" \
    -fps_mode vfr -c:v libx264 -preset veryfast -an \
    "${fixture_dir}/variable-frame-rate.mkv"

printf '%s\n' \
    ';FFMETADATA1' \
    '[CHAPTER]' 'TIMEBASE=1/1000' 'START=2000' 'END=3000' 'title=Normalized opening' \
    '[CHAPTER]' 'TIMEBASE=1/1000' 'START=3000' 'END=5000' 'title=Normalized ending' \
    > "${work_dir}/nonzero-chapters.ffmetadata"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -f ffmetadata -i "${work_dir}/nonzero-chapters.ffmetadata" \
    -t 3 -shortest \
    -vf "setpts=PTS+2/TB" -af "asetpts=PTS+2/TB" \
    -map 0:v -map 1:a -map_metadata 2 \
    -c:v libx264 -preset veryfast -c:a aac -copyts \
    "${fixture_dir}/nonzero-start.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel fatal -y \
    -f lavfi -i "testsrc2=size=320x180:rate=30" -t 3 \
    -c:v mpeg2video -bf 2 -copyts -muxpreload 0 -muxdelay 0 \
    -avoid_negative_ts disabled "${fixture_dir}/negative-origin.mpg"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=30" -t 2 \
    -c:v libx264 -preset ultrafast -g 30 -an -f h264 \
    "${fixture_dir}/unknown-duration.h264"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "${fixture_dir}/video-only.mp4" -map 0 -c copy \
    -bsf:v "noise=amount=100" "${fixture_dir}/corrupt-packets.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "${fixture_dir}/h264-aac.mp4" -map 0 -c copy -movflags +faststart \
    "${work_dir}/h264-aac-faststart.mp4"
source_size="$(stat -f %z "${work_dir}/h264-aac-faststart.mp4")"
retained_size="$((source_size - 4096))"
if (( retained_size <= 0 )); then
    print -u2 "h264-aac.mp4 is too small to create a deterministic truncation"
    exit 1
fi
/usr/bin/head -c "${retained_size}" "${work_dir}/h264-aac-faststart.mp4" \
    > "${fixture_dir}/truncated-h264.mp4"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=30:duration=2" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2.6" \
    -map 0:v -map 1:a -c:v libx264 -preset ultrafast -c:a aac \
    "${fixture_dir}/delayed-audio-tail.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=15" -t 1.5 \
    -c:v libx264 -preset ultrafast -g 15 -an -f h264 "${work_dir}/resolution-a.h264"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" -t 1.5 \
    -c:v libx264 -preset ultrafast -g 30 -an -f h264 "${work_dir}/resolution-b.h264"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "concat:${work_dir}/resolution-a.h264|${work_dir}/resolution-b.h264" \
    -c copy -f mpegts "${fixture_dir}/midstream-resolution-change.ts"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" -t 1.5 \
    -vf "format=yuv420p,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
    -c:v libx264 -preset ultrafast -g 24 -an -f h264 "${work_dir}/pixel-a.h264"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" -t 1.5 \
    -vf "format=yuv420p10le,setparams=range=tv:color_primaries=bt2020:color_trc=bt709:colorspace=bt2020nc" \
    -c:v libx264 -preset ultrafast -g 24 -an -f h264 "${work_dir}/pixel-b.h264"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "concat:${work_dir}/pixel-a.h264|${work_dir}/pixel-b.h264" \
    -c copy -f mpegts "${fixture_dir}/midstream-pixel-color-change.ts"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=440:sample_rate=44100" -t 1.5 \
    -af "aformat=channel_layouts=mono" -c:a aac -f adts "${work_dir}/audio-a.aac"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" -t 1.5 \
    -af "aformat=channel_layouts=stereo" -c:a aac -f adts "${work_dir}/audio-b.aac"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "concat:${work_dir}/audio-a.aac|${work_dir}/audio-b.aac" \
    -c copy -f mpegts "${fixture_dir}/audio-rate-layout-change.ts"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" -t 3 \
    -vf "setpts='if(gte(N,45),PTS-0.5/TB,PTS)'" \
    -c:v libx264 -preset veryfast -an \
    "${fixture_dir}/discontinuous-timestamps.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -display_rotation:v:0 90 -i "${fixture_dir}/video-only.mp4" -map 0 -c copy \
    "${fixture_dir}/rotated-90.mp4"

for rotation in 180 270; do
    "${ffmpeg_bin}" -hide_banner -loglevel error -y \
        -display_rotation:v:0 "${rotation}" -i "${fixture_dir}/video-only.mp4" \
        -map 0 -c copy "${fixture_dir}/rotated-${rotation}.mp4"
done

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -display_hflip:v:0 -i "${fixture_dir}/video-only.mp4" -map 0 -c copy \
    "${fixture_dir}/mirrored-horizontal.mp4"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=720x480:rate=30" -t 2 \
    -vf "setsar=40/33" -c:v libx264 -preset ultrafast -an \
    "${fixture_dir}/anamorphic-sar.mkv"

for spec in \
    'color-bt601-limited.mkv:smpte170m:smpte170m:smpte170m:tv' \
    'color-bt601-full.mkv:smpte170m:smpte170m:smpte170m:pc' \
    'color-bt709-limited.mkv:bt709:bt709:bt709:tv' \
    'color-bt709-full.mkv:bt709:bt709:bt709:pc'
do
    parts=("${(@s/:/)spec}")
    "${ffmpeg_bin}" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=24" -t 2 \
        -vf "format=yuv420p,setparams=color_primaries=${parts[2]}:color_trc=${parts[3]}:colorspace=${parts[4]}:range=${parts[5]}" \
        -c:v libx264 -preset ultrafast -an "${fixture_dir}/${parts[1]}"
done

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" -t 2 \
    -vf "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=bt709:colorspace=bt2020nc:range=tv" \
    -c:v libx265 -preset ultrafast -x265-params log-level=error -an \
    "${fixture_dir}/sdr-bt2020.mkv"

for chroma in left center; do
    "${ffmpeg_bin}" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=24" -t 2 \
        -c:v libx264 -preset ultrafast -chroma_sample_location "${chroma}" -an \
        "${fixture_dir}/chroma-${chroma}.mkv"
done

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=50" -t 2 \
    -vf "tinterlace=interleave_top,setfield=tff" -r 25 \
    -c:v mpeg2video -flags +ildct+ilme -top 1 -an "${fixture_dir}/interlaced-tff.mpg"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=50" -t 2 \
    -vf "tinterlace=interleave_bottom,setfield=bff" -r 25 \
    -c:v mpeg2video -flags +ildct+ilme -top 0 -an "${fixture_dir}/interlaced-bff.mpg"

hdr_master_display='G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)'
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" -t 3 \
    -vf "format=yuv420p10le" -c:v libx265 -preset ultrafast \
    -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=${hdr_master_display}:max-cll=1000,400" \
    -pix_fmt yuv420p10le -an "${fixture_dir}/hdr10-pq-p010.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30" -t 3 \
    -vf "format=yuv420p10le" -c:v libx265 -preset ultrafast \
    -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
    -pix_fmt yuv420p10le -an "${fixture_dir}/hlg-p010.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.30*sin(2*PI*220*t)|0.30*sin(2*PI*330*t)|0.30*sin(2*PI*440*t)|0.20*sin(2*PI*55*t)|0.25*sin(2*PI*550*t)|0.25*sin(2*PI*660*t):s=48000:channel_layout=5.1" \
    -t 3 -c:a flac "${fixture_dir}/audio-5.1.flac"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.22*sin(2*PI*220*t)|0.22*sin(2*PI*330*t)|0.22*sin(2*PI*440*t)|0.15*sin(2*PI*55*t)|0.20*sin(2*PI*550*t)|0.20*sin(2*PI*660*t)|0.20*sin(2*PI*770*t)|0.20*sin(2*PI*880*t):s=48000:channel_layout=7.1" \
    -t 3 -c:a flac "${fixture_dir}/audio-7.1.flac"

heavy_ass="${fixture_dir}/heavy-animated.ass"
printf '%s\n' \
    '[Script Info]' 'ScriptType: v4.00+' 'PlayResX: 1920' 'PlayResY: 1080' \
    'ScaledBorderAndShadow: yes' '' '[V4+ Styles]' \
    'Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding' \
    'Style: Stress,Arial,42,&H00FFFFFF,&H0000FFFF,&H00101010,&H70000000,0,0,0,0,100,100,0,0,1,3,2,5,20,20,20,1' '' \
    '[Events]' \
    'Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text' \
    > "${heavy_ass}"
for event_index in {0..119}; do
    start_cs=$((event_index % 80))
    end_cs=${start_cs}
    x=$((80 + (event_index * 137) % 1760))
    y=$((80 + (event_index * 83) % 920))
    printf 'Dialogue: %d,0:00:00.%02d,0:00:02.%02d,Stress,,0,0,0,,{\\move(%d,%d,%d,%d)\\fad(100,200)\\t(0,1200,\\fscx150\\fscy150)\\bord4\\shad3\\k20}Stress %03d\n' \
        "$((event_index % 4))" "${start_cs}" "${end_cs}" \
        "${x}" "${y}" "$((1920 - x))" "$((1080 - y))" "${event_index}" \
        >> "${heavy_ass}"
done

qualification_duration="${SUPERPLAYR_NATIVE_QUALIFICATION_DURATION:-120}"
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t "${qualification_duration}" -shortest -c:v libx264 -preset ultrafast \
    -g 48 -pix_fmt yuv420p -c:a aac -b:a 96k \
    "${fixture_dir}/long-h264-av-sync.mkv"

cat > "${work_dir}/long-caption.srt" <<'SUBTITLES'
1
00:00:00,000 --> 00:00:10,000
Opening caption

2
00:01:10,000 --> 00:01:30,000
Caption after seeking
SUBTITLES
"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -i "${fixture_dir}/long-h264-av-sync.mkv" -i "${work_dir}/long-caption.srt" \
    -map 0 -map 1:0 -c copy -c:s srt "${fixture_dir}/long-caption.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=550:sample_rate=48000" \
    -t "${qualification_duration}" -shortest -vf "format=yuv420p10le" \
    -c:v libx265 -preset ultrafast \
    -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=${hdr_master_display}:max-cll=1000,400" \
    -g 48 -pix_fmt yuv420p10le -c:a aac -b:a 96k \
    "${fixture_dir}/long-hevc-p010-av-sync.mkv"

"${ffmpeg_bin}" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=30" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" \
    -t "${qualification_duration}" -shortest \
    -vf "select='if(lt(mod(t,4),2),not(mod(n,2)),not(mod(n,3)))'" \
    -fps_mode vfr -c:v libx264 -preset ultrafast -g 60 -pix_fmt yuv420p \
    -c:a aac -b:a 96k "${fixture_dir}/long-vfr-av-sync.mkv"

ln -sfn "long-h264-av-sync.mkv" "${fixture_dir}/long-av-sync.mkv"

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
generator_head="$(git -C "${repository_root}" rev-parse HEAD)"
generator_hash="$(shasum -a 256 "${repository_root}/Scripts/generate-native-fixtures.sh" \
    | awk '{print $1}')"
module_cache="${TMPDIR:-/tmp}/superplayr-fixture-module-cache"
mkdir -p "${module_cache}/clang" "${module_cache}/swiftpm"
env CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    swift run --disable-sandbox --package-path "${repository_root}" \
    SuperplayrDifferentialHarness fixture-manifest \
    --directory "${fixture_dir}" \
    --generator-revision "git:${generator_head};script-sha256:${generator_hash}"
env CLANG_MODULE_CACHE_PATH="${module_cache}/clang" \
    SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}/swiftpm" \
    swift run --disable-sandbox --package-path "${repository_root}" \
    SuperplayrDifferentialHarness fixture-matrix \
    --directory "${fixture_dir}"

print "Generated native playback fixtures in ${fixture_dir}"
