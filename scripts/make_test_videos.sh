#!/bin/zsh
# Generate the self-made video test wallpapers (no copyrighted content) used by the regression suite.
# Each becomes a minimal Wallpaper Engine video project: <out>/<name>/{project.json, video file}.
#
#   scripts/make_test_videos.sh [out-dir]      (default: regression/videos; needs ffmpeg)
#
# Content: ffmpeg's testsrc2 pattern (moving gradient, colour bars, frame counter), 1280x720,
# 30 fps, 4 s, BT.709 limited range (tagged) — deterministic, so decoded frames can be compared exactly.
set -euo pipefail
export SVT_LOG=0   # silence SVT-AV1 banner
cd "${0:A:h}/.."
OUT=${1:-regression/videos}
SRC="testsrc2=size=1280x720:rate=30:duration=4"
mkdir -p $OUT

make() { # name, file, ffmpeg encoder args...   (MATRIX=bt470bg for BT.601 content)
  local name=$1 file=$2; shift 2
  local matrix=${MATRIX:-bt709}
  mkdir -p $OUT/$name
  # Convert with the BT.709 matrix and tag it (like real HD video), so every decoder agrees on colour.
  [[ -f $OUT/$name/$file ]] || ffmpeg -hide_banner -loglevel error -y -f lavfi -i $SRC \
    -vf "scale=out_color_matrix=$matrix:out_range=tv,format=yuv420p" \
    -colorspace $matrix -color_primaries $matrix -color_trc ${matrix/bt470bg/smpte170m} -color_range tv "$@" $OUT/$name/$file
  cat > $OUT/$name/project.json <<JSON
{
	"file" : "$file",
	"title" : "Test video ($name)",
	"type" : "video"
}
JSON
  printf "%-12s %s\n" $name "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames -of csv=p=0 $OUT/$name/$file)"
}

make h264_mp4   video.mp4  -c:v libx264 -preset medium -crf 18
make hevc_mp4   video.mp4  -c:v libx265 -preset medium -crf 20 -tag:v hvc1 -x265-params log-level=error
make h264_mov   video.mov  -c:v libx264 -preset medium -crf 18
make vp9_webm   video.webm -c:v libvpx-vp9 -b:v 0 -crf 30 -row-mt 1
# VP8 has no colour signalling and is defined as BT.601, so real VP8 files are BT.601 content.
MATRIX=bt470bg make vp8_webm video.webm -c:v libvpx -b:v 2M -crf 10
make av1_webm   video.webm -c:v libsvtav1 -crf 35 -preset 8
make av1_mp4    video.mp4  -c:v libsvtav1 -crf 35 -preset 8
