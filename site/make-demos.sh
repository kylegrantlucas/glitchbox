#!/bin/bash
# Regenerates every clip, poster, and layer still in site/assets/demos from the
# chain files in site/demos and synthetic lavfi sources (no files from disk).
#
#   site/make-demos.sh [TOOLCHAIN]
#
# TOOLCHAIN is a Glitchbox.app/Contents directory; the default is this checkout's
# build/Glitchbox.app/Contents. Renders go through the bundled glitchbox CLI with
# its user library and layer cache in a temp dir, so ~/Library is never touched.
# row-shift (in the stack demo) uses unseeded randomness, so that clip differs
# on every run; the rest are best-effort reproducible like any app render.
set -euo pipefail

site=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$site")
tc=$(cd "${1:-$root/build/Glitchbox.app/Contents}" && pwd)
ffmpeg=$tc/Helpers/ffmpeg
glitchbox=$tc/Helpers/glitchbox
jq=$tc/Helpers/jq
out=$site/assets/demos

work=$(mktemp -d "${TMPDIR:-/tmp}/glitchbox-demos.XXXXXX")
trap 'rm -rf "$work"' EXIT
export GLITCHBOX_DATA_DIR=$work/data GLITCHBOX_CACHE_DIR=$work/cache
mkdir -p "$GLITCHBOX_DATA_DIR" "$GLITCHBOX_CACHE_DIR" "$work/src" "$work/chains" "$out"

DUR=4 FPS=30 HEIGHT=360 SIZE=640x360

ff() { "$ffmpeg" -hide_banner -nostdin -loglevel error -y "$@"; }

# Maps luma onto the icon's palette: black -> no-signal blue, white -> bone.
BRAND="format=rgb24,lutrgb=r='val*247/255+(255-val)*31/255':g='val*243/255+(255-val)*43/255':b='val*234/255+(255-val)*216/255'"
# 120 bpm: a pitch-swept kick on every beat and a noise hat on the off-beat.
KICK_ENV="exp(-mod(t,0.5)*9)"
KICK="0.9*sin(2*PI*(45*t+3*(1-exp(-mod(t,0.5)*30))))*$KICK_ENV"
HAT="0.25*(random(0)*2-1)*exp(-mod(t+0.25,0.5)*60)"

echo "sources" >&2
s=$work/src
# SMPTE HD bars with a white bar rolling across once every 4 s, and a 1 kHz tone.
ff -f lavfi -i "smptehdbars=s=$SIZE:r=$FPS:d=$DUR" \
   -f lavfi -i "color=c=white:s=32x360:r=$FPS:d=$DUR" \
   -f lavfi -i "sine=f=1000:sample_rate=48000:d=$DUR" \
   -filter_complex "[0][1]overlay=x='mod(t*168,672)-32':y=0:shortest=1[v]" \
   -map '[v]' -map 2:a -c:v ffv1 -c:a pcm_s16le "$s/bars.mkv"
# Drifting linear gradient bands in the icon's colours.
ff -f lavfi -i "gradients=s=$SIZE:r=$FPS:c0=#0a1a70:c1=#f7f3ea:c2=#1f2bd8:c3=#00ead8:c4=#ff3b30:n=5:speed=0.05:seed=9:type=linear" \
   -t "$DUR" -c:v ffv1 "$s/bands.mkv"
# Mandelbrot zoom toward Seahorse Valley, mapped to blue and bone.
ff -f lavfi -i "mandelbrot=s=$SIZE:r=$FPS:start_x=-0.743643887037151:start_y=0.13182590420533:start_scale=0.3:end_scale=0.004:end_pts=$((DUR * FPS)):inner=black:outer=normalized_iteration_count" \
   -t "$DUR" -vf "format=gray,eq=contrast=1.4,$BRAND" -c:v ffv1 "$s/mandel.mkv"
# Conway's life with mould trails, bone cells on blue.
ff -f lavfi -i "life=s=160x90:r=$FPS:mold=10:life_color=#f2ecd8:death_color=#1a3cf0:mold_color=#0a1a70:ratio=0.18:seed=7" \
   -t "$DUR" -vf "scale=$SIZE:flags=neighbor" -c:v ffv1 "$s/life.mkv"
# ffmpeg's moving test card.
ff -f lavfi -i "testsrc2=s=$SIZE:r=$FPS" -t "$DUR" -c:v ffv1 "$s/testcard.mkv"
# A bone disc on blue that swells with each kick, over the kick-and-hat track.
ff -f lavfi -i "aevalsrc='$KICK+$HAT':s=48000:d=$DUR" \
   -f lavfi -i "color=c=black:s=$SIZE:r=$FPS:d=$DUR" \
   -filter_complex "[1]format=gray,geq=lum='if(lt(hypot(X-320,Y-180),50+110*exp(-mod(T,0.5)*9)),255,0)',${BRAND}[v]" \
   -map '[v]' -map 0:a -c:v ffv1 -c:a pcm_s16le -shortest "$s/pulse.mkv"
# Slow radial gradients in the icon's colours.
ff -f lavfi -i "gradients=s=$SIZE:r=$FPS:c0=#1a3cf0:c1=#f2ecd8:c2=#ff2a3c:c3=#00e5ff:n=4:speed=0.03:seed=3:type=radial" \
   -t "$DUR" -c:v ffv1 "$s/grad.mkv"

render() { # CHAIN SOURCE -> prints the rendered out.mkv
  "$glitchbox" --root "$root" --toolchain "$tc" render --chain "$1" \
    --duration "$DUR" --height "$HEIGHT" --fps "$FPS" "$2" </dev/null
}

# name source poster-seconds
while read -r name source poster; do
  echo "demo $name ($source)" >&2
  mkv=$(render "$site/demos/$name.json" "$s/$source.mkv")
  ff -i "$mkv" -an -c:v libx264 -preset slow -crf 26 -maxrate 1500k -bufsize 3000k \
     -profile:v high -pix_fmt yuv420p -map_metadata -1 -movflags +faststart "$out/$name.mp4"
  ff -ss "$poster" -i "$mkv" -frames:v 1 -q:v 3 "$out/$name.jpg"
done <<'EOF'
vhs-bars bars 1.5
mosh-bands bands 3.5
mv-zoom mandel 3.2
bend-life life 2.0
smear-testcard testcard 2.0
reactive-pulse pulse 2.0
stack grad 1.5
EOF

# One still per layer of the stack: render each prefix of the chain. The prefixes
# hit the layer cache from the full render above, so they show the same frames.
layers=$("$jq" '.layers | length' "$site/demos/stack.json")
k=0
while [ "$k" -le "$layers" ]; do
  "$jq" --argjson k "$k" '.layers |= .[:$k]' "$site/demos/stack.json" > "$work/chains/stack-$k.json"
  mkv=$(render "$work/chains/stack-$k.json" "$s/grad.mkv")
  ff -ss 1.5 -i "$mkv" -frames:v 1 -vf scale=480:-2 -q:v 3 "$out/stack-layer-$k.jpg"
  k=$((k + 1))
done
