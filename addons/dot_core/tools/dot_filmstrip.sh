#!/usr/bin/env bash
# One clip recorded by --write-movie into a contact sheet and an MP4, with ffmpeg only.
#   dot_filmstrip.sh <movie> <out-prefix> [--views fp,tp] [--cols 4] [--rows 4] [--width 320]
# The movie is its views side by side (equal widths); each view gets cols*rows frames spread
# over the clip, each stamped with its time, and the views sit side by side in <prefix>_sheet.png.
set -euo pipefail
movie=${1:?movie}; prefix=${2:?out prefix}; shift 2
views=fp cols=4 rows=4 width=320
while [[ $# -gt 0 ]]; do
  case $1 in
    --views) views=$2; shift 2 ;;
    --cols) cols=$2; shift 2 ;;
    --rows) rows=$2; shift 2 ;;
    --width) width=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
IFS=, read -ra names <<< "$views"
n=${#names[@]}
frames=$((cols * rows))
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$movie")
font=$(fc-match -f '%{file}' monospace 2>/dev/null || true)
[[ -f $font ]] || font=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
graph="[0:v]split=$n"
for ((i = 0; i < n; i++)); do graph+="[s$i]"; done
graph+=";"
for ((i = 0; i < n; i++)); do
  graph+="[s$i]crop=iw/$n:ih:iw/$n*$i:0,scale=$width:-2,"
  graph+="drawtext=fontfile=$font:text='%{pts\\:hms}':x=4:y=4:fontsize=16:fontcolor=white:box=1:boxcolor=black@0.6,"
  graph+="fps=$frames/$dur:round=down,tile=${cols}x${rows}[v$i];"
done
for ((i = 0; i < n; i++)); do graph+="[v$i]"; done
if ((n > 1)); then graph+="hstack=inputs=$n"; else graph+="copy"; fi
ffmpeg -v error -y -i "$movie" -filter_complex "$graph" -frames:v 1 "${prefix}_sheet.png"
ffmpeg -v error -y -i "$movie" -c:v libx264 -pix_fmt yuv420p -crf 20 "${prefix}.mp4"
echo "wrote ${prefix}_sheet.png ${prefix}.mp4 ($frames frames per view, ${dur}s)"
