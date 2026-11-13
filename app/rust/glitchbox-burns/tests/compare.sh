#!/bin/bash
# Pixel parity of GlitchboxBurns (macOS slice) with the burns CLI at the same burns-rs commit.
#   tests/compare.sh BURNS FFMPEG ORT-DYLIB [WORKDIR]
# BURNS is a `burns` binary (e.g. Glitchbox.app/Contents/Helpers/burns), FFMPEG one with
# ffv1, ORT-DYLIB the libonnxruntime.dylib burns uses (ORT_DYLIB_PATH). Renders the
# still-motion plugin's default (Ken Burns) project and its depth-parallax variant at
# 320x180, 30 fps, 1 s from a testsrc2 PNG, then compares every frame:
#   RGBA: GlitchboxBurns frames vs `burns frame` PNGs (burns's exact RGBA output);
#   YUV:  GlitchboxBurns frames through burns's encoder colour conversion vs the decoded
#         `burns render --codec ffv1` (lossless FFV1) clip.
# The depth project uses --auto-depth (model pre-seeded from build/downloads), and
# GlitchboxBurns's own estimation loads the ONNX Runtime beside it in the xcframework.
set -euo pipefail
BURNS=$1 FFMPEG=$2 ORT=$3
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd -P)
W=${4:-$(mktemp -d)}
XCF=$ROOT/build/ios/xcframeworks
MODEL=$ROOT/build/downloads/depth-anything-v2-small-4472b736.onnx
SHA=afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c
mkdir -p "$W/Frameworks" "$W/ref/Library/Caches/burns/models" "$W/our/models"
cd "$W"
rm -rf Frameworks/* ref/Library/Caches/burns/depth our/depth
cp -R "$XCF/GlitchboxBurns.xcframework/macos-arm64/GlitchboxBurns.framework" \
  "$XCF/onnxruntime.xcframework/macos-arm64/onnxruntime.framework" Frameworks/
cp -c "$MODEL" "ref/Library/Caches/burns/models/$SHA.onnx" 2>/dev/null || cp "$MODEL" "ref/Library/Caches/burns/models/$SHA.onnx"
cp -c "$MODEL" "our/models/$SHA.onnx" 2>/dev/null || cp "$MODEL" "our/models/$SHA.onnx"
xcrun -sdk macosx clang -O2 "$ROOT/app/rust/glitchbox-burns/tests/smoke.c" -F Frameworks \
  -framework GlitchboxBurns -Wl,-rpath,@executable_path/Frameworks -o smoke
"$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x480 -frames:v 1 in.png

# The plugin's own project builder (its jq program) over its parameter defaults.
plugin=$ROOT/plugins/still-motion.json
filter=$(jq -r '.steps[0].script' "$plugin" | awk "/^jq '\\{/{f=1;sub(/^jq '/,\"\");print;next} f&&/^}' /{print \"}\";exit} f{print}")
jq '[.params[] | {(.key): .default}] | add' "$plugin" > p-transform.json
jq '.motion = "depth"' p-transform.json > p-depth.json

flags=(--fps 30 --duration 1 --width 320 --height 180)
yuv=(-vf "scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p" -f rawvideo -pix_fmt yuv420p)
status=0
for m in transform depth; do
  jq "$filter" "p-$m.json" > "proj-$m.json"
  d=() o=()
  if [ $m = depth ]; then d=(--auto-depth); o=(auto "$W/our"); fi
  env HOME="$W/ref" ORT_DYLIB_PATH="$ORT" PATH="$(dirname "$FFMPEG"):/usr/bin:/bin" \
    "$BURNS" render -i in.png -o "ref-$m.mkv" --config "proj-$m.json" "${flags[@]}" --codec ffv1 \
    --overwrite ${d[@]+"${d[@]}"} 2> "ref-$m.log"
  "$FFMPEG" -hide_banner -loglevel error -y -i "ref-$m.mkv" -f rawvideo -pix_fmt yuv420p "ref-$m.yuv"
  : > "ref-$m.rgba"
  for i in $(seq 0 29); do
    env HOME="$W/ref" ORT_DYLIB_PATH="$ORT" "$BURNS" frame -i in.png -o f.png --frame "$i" \
      --config "proj-$m.json" "${flags[@]}" --overwrite ${d[@]+"${d[@]}"} 2> /dev/null
    "$FFMPEG" -v error -i f.png -f rawvideo -pix_fmt rgba - >> "ref-$m.rgba"
  done
  ./smoke in.png "proj-$m.json" "our-$m.rgba" 320 180 30 1 ${o[@]+"${o[@]}"}
  "$FFMPEG" -hide_banner -loglevel error -y -f rawvideo -pixel_format rgba -video_size 320x180 \
    -framerate 30 -i "our-$m.rgba" "${yuv[@]}" "our-$m.yuv"
  for k in rgba yuv; do
    if cmp -s "ref-$m.$k" "our-$m.$k"; then
      echo "$m $k: identical ($(wc -c < "our-$m.$k") bytes, 30 frames)"
    else
      status=1
      fmt=rgba; [ $k = yuv ] && fmt=yuv420p
      psnr=$("$FFMPEG" -hide_banner -f rawvideo -pixel_format $fmt -video_size 320x180 -i "ref-$m.$k" \
        -f rawvideo -pixel_format $fmt -video_size 320x180 -i "our-$m.$k" \
        -lavfi psnr -f null - 2>&1 | grep -o 'average:[^ ]*' || true)
      echo "$m $k: DIFFERENT (PSNR $psnr)"
    fi
  done
done
if [ -d "$W/our/depth" ] && cmp -s "$W"/our/depth/*.png "$W"/ref/Library/Caches/burns/depth/*.png; then
  echo "depth map: identical"
else
  echo "depth map: DIFFERENT"; status=1
fi
exit $status
