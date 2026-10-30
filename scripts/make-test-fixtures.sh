#!/usr/bin/env bash
#
# Regenerates the small SYNTHETIC media fixtures committed for PlaybackKit's tests. Every picture and sound is made from
# FFmpeg's built-in sources (flat colors, a moving box, silence); recorded broadcast content never goes into git. The
# only bytes taken from real captures are header-only excerpts (see the end).
#
#   scripts/make-test-fixtures.sh
#
# Needs the ffmpeg command-line tool (`brew install ffmpeg`) and Swift. FFmpeg is only used here, never shipped or
# linked; byte surgery FFmpeg can't do (A/53 captions, a signalled splice, header-only excerpts) is in
# scripts/ts-fixture-tool.swift, written from the specs.
#
# Output (MPEG-2 video and AC-3 audio in MPEG-TS, like ATSC 1.0):
#   PlaybackKitTests/Fixtures/testsrc-480i.ts      decoder tests: 10 pictures of testsrc, 480i TFF
#   PlaybackKitTests/Fixtures/two-programs.ts      pipeline program selection: a copy of golden-two-programs.ts
#   MPEGTSTests/Fixtures/golden-1080i.ts           1080i TFF, open GOPs, AC-3 5.1 eng + 2.0 spa, A/53 608 captions
#   MPEGTSTests/Fixtures/golden-720p.ts            720p59.94, three GOPs (the later two open), AC-3 2.0
#   MPEGTSTests/Fixtures/golden-720p-mid-gop.ts    the 720p file cut at a packet partway through it
#   MPEGTSTests/Fixtures/golden-pts-wrap.ts        480i whose PTS, DTS and PCR wrap past 2^33 halfway through
#   MPEGTSTests/Fixtures/golden-discontinuity.ts   two segments spliced with discontinuity_indicator, PTS +60 s
#   MPEGTSTests/Fixtures/golden-two-programs.ts    a PAT with two programs, each with video and audio
#   MPEGTSTests/Fixtures/excerpts/*.ts             header-only excerpts of local captures, when present

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Packages/PlaybackKit/Tests/PlaybackKitTests/Fixtures"
GOLDEN="$ROOT/Packages/PlaybackKit/Tests/MPEGTSTests/Fixtures"
CAPTURES="$ROOT/localdata/captures"
TOOL=(swift "$ROOT/scripts/ts-fixture-tool.swift")
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }
mkdir -p "$OUT" "$GOLDEN/excerpts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FF=(ffmpeg -hide_banner -loglevel error -y)
# PIDs shaped like an ATSC program (PMT 0x30, streams from 0x31), PAT and PMT repeated every 50 ms so a cut file
# finds them again, and no SDT text beyond a fixed name.
TS=(-mpegts_pmt_start_pid 0x30 -mpegts_start_pid 0x31 -pat_period 0.05 -sdt_period 1
    -metadata service_provider=Synthetic -metadata service_name=Golden -f mpegts)
SILENCE_51="aevalsrc=0|0|0|0|0|0:c=5.1:s=48000"
SILENCE_20="aevalsrc=0|0:c=stereo:s=48000"

# 10 pictures of testsrc, 720x480 at 29.97, interlaced top field first, MPEG-2 Main profile with B-pictures, in a
# transport stream (one program, video only). A coarse quantiser keeps it to a few KB.
"${FF[@]}" \
    -f lavfi -i "testsrc=size=720x480:rate=30000/1001" -frames:v 10 \
    -vf "format=yuv420p,setfield=tff" -c:v mpeg2video -profile:v main -level:v main \
    -flags +ildct+ilme -alternate_scan 1 -g 10 -bf 2 -qscale:v 31 -an \
    -metadata service_provider="Synthetic" -metadata service_name="testsrc" \
    -f mpegts "$OUT/testsrc-480i.ts"

# A flat color with a moving box: `video <size> <rate> <frames> <gop> <interlaced 0|1> <out.m2v>`. No closed-GOP
# flag, so every GOP after the first is open: its leading B pictures reference the previous GOP.
video() {
    local filters="drawbox=x=t*720:y=ih/2:w=64:h=48:color=white:t=fill,format=yuv420p"
    local interlace=()
    if [[ "$5" == 1 ]]; then
        filters="$filters,setfield=tff"
        interlace=(-flags +ildct+ilme -alternate_scan 1)
    fi
    "${FF[@]}" -f lavfi -i "color=c=0x305070:size=$1:rate=$2" -frames:v "$3" -vf "$filters" \
        -c:v mpeg2video -profile:v main -level:v high ${interlace[@]+"${interlace[@]}"} -g "$4" -bf 2 -qscale:v 31 \
        -f mpeg2video "$6"
}

# 1080i like the 9.1 capture: two GOPs, captions, English 5.1 and Spanish stereo.
video 1920x1080 30000/1001 14 7 1 "$WORK/1080i.m2v"
"${TOOL[@]}" captions "$WORK/1080i.m2v" "$WORK/1080i-cc.m2v"
"${FF[@]}" -fflags +genpts -r 30000/1001 -i "$WORK/1080i-cc.m2v" \
    -f lavfi -t 0.45 -i "$SILENCE_51" -f lavfi -t 0.45 -i "$SILENCE_20" \
    -map 0:v -map 1:a -map 2:a -c:v copy -c:a ac3 -b:a:0 192k -b:a:1 96k \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa "${TS[@]}" "$GOLDEN/golden-1080i.ts"

# 720p59.94 like the 7.1 capture: three GOPs, the later two open; then the same file from a packet partway in.
video 1280x720 60000/1001 12 6 0 "$WORK/720p.m2v"
"${FF[@]}" -fflags +genpts -r 60000/1001 -i "$WORK/720p.m2v" -f lavfi -t 0.2 -i "$SILENCE_20" \
    -map 0:v -map 1:a -c:v copy -c:a ac3 -b:a 96k -metadata:s:a:0 language=eng "${TS[@]}" "$GOLDEN/golden-720p.ts"
PACKETS=$(( $(wc -c < "$GOLDEN/golden-720p.ts") / 188 ))
dd if="$GOLDEN/golden-720p.ts" of="$GOLDEN/golden-720p-mid-gop.ts" bs=188 skip=$(( PACKETS * 9 / 20 )) 2>/dev/null

# Small 480i segments for the timestamp and program-structure cases: `segment <frames> <offset s> <out.ts>`.
segment() {
    video 720x480 30000/1001 "$1" 10 1 "$WORK/480i.m2v"
    "${FF[@]}" -fflags +genpts -r 30000/1001 -i "$WORK/480i.m2v" -f lavfi -t 0.7 -i "$SILENCE_20" \
        -map 0:v -map 1:a -c:v copy -c:a ac3 -b:a 96k -metadata:s:a:0 language=eng \
        -output_ts_offset "$2" "${TS[@]}" "$3"
}

# 2^33 / 90 kHz = 95443.717 s. The muxer delays the first DTS by 1.4 s, so this starts 0.35 s before the wrap.
segment 20 95441.967 "$GOLDEN/golden-pts-wrap.ts"

segment 10 10 "$WORK/first.ts"
segment 10 70 "$WORK/second.ts"
"${TOOL[@]}" splice "$WORK/first.ts" "$WORK/second.ts" "$GOLDEN/golden-discontinuity.ts"

video 352x240 30000/1001 6 6 0 "$WORK/one.m2v"
video 352x240 30000/1001 6 6 0 "$WORK/two.m2v"
"${FF[@]}" -fflags +genpts -r 30000/1001 -i "$WORK/one.m2v" -fflags +genpts -r 30000/1001 -i "$WORK/two.m2v" \
    -f lavfi -t 0.2 -i "$SILENCE_20" -f lavfi -t 0.2 -i "$SILENCE_20" \
    -map 0:v -map 1:v -map 2:a -map 3:a -c:v copy -c:a ac3 -b:a 96k \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa \
    -program program_num=3:title=One:st=0:st=2 -program program_num=4:title=Two:st=1:st=3 \
    "${TS[@]}" -mpegts_start_pid 0x41 "$GOLDEN/golden-two-programs.ts"
cp "$GOLDEN/golden-two-programs.ts" "$OUT/two-programs.ts"

# Header-only excerpts of the gitignored local captures (see ts-fixture-tool.swift: PSI and headers only; every
# picture, sound and caption byte is zeroed and PSIP is dropped). Skipped where the captures are absent.
excerpt() {
    if [[ -f "$CAPTURES/$1" ]]; then
        "${TOOL[@]}" excerpt "$CAPTURES/$1" "$GOLDEN/excerpts/$2" "$3"
    else
        echo "skipping $2: $CAPTURES/$1 not found"
    fi
}
excerpt hdhr-9.1.ts excerpt-1080i.ts 16000
excerpt hdhr-7.1.ts excerpt-720p.ts 10000
excerpt s2_ch605.ts excerpt-multiplex.ts 8000

ls -l "$OUT" "$GOLDEN" "$GOLDEN/excerpts"
