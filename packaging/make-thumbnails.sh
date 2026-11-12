#!/bin/bash
# Regenerates presets/thumbnails, the pictures in the app's Simple mode: one JPEG
# per Look (presets/chains/*.json -> looks/<file stem>.jpg) and one per plugin that
# has a "simple" block (its defaults -> effects/<id>.jpg), rendered over ffmpeg's
# test card (no files from disk).
#
#   packaging/make-thumbnails.sh [TOOLCHAIN]
#
# TOOLCHAIN is a Glitchbox.app/Contents directory; the default is this checkout's
# build/Glitchbox.app/Contents. Renders go through the bundled glitchbox CLI with
# its user library and layer cache in a temp dir, so ~/Library is never touched.
# A chain whose first layer reads a still gets the test card's frame at 1 s. The
# test card carries a 120 bpm kick-and-hat track for the sound-driven effects;
# the thumbnail frame sits on a kick.
# block-glitch and row-shift use unseeded frei0r randomness, so their thumbnails
# (and those of the Looks containing them) differ on every run; the rest are
# best-effort reproducible like any app render. Both folders are rebuilt from
# scratch: commit all outputs together.
set -euo pipefail

packaging=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$packaging")
tc=$(cd "${1:-$root/build/Glitchbox.app/Contents}" && pwd)
ffmpeg=$tc/Helpers/ffmpeg
glitchbox=$tc/Helpers/glitchbox
jq=$tc/Helpers/jq
out=$root/presets/thumbnails

work=$(mktemp -d "${TMPDIR:-/tmp}/glitchbox-thumbnails.XXXXXX")
trap 'rm -rf "$work"' EXIT
export GLITCHBOX_DATA_DIR=$work/data GLITCHBOX_CACHE_DIR=$work/cache
mkdir -p "$GLITCHBOX_DATA_DIR" "$GLITCHBOX_CACHE_DIR" "$work/chains"

DUR=4 FPS=30 HEIGHT=360 SIZE=640x360 AT=2.5

ff() { "$ffmpeg" -hide_banner -nostdin -loglevel error -y "$@"; }
fail() { echo "make-thumbnails: $*" >&2; exit 1; }

echo "sources" >&2
# 120 bpm, like site/make-demos.sh: a pitch-swept kick on every beat and a noise hat on the off-beat.
KICK="0.9*sin(2*PI*(45*t+3*(1-exp(-mod(t,0.5)*30))))*exp(-mod(t,0.5)*9)"
HAT="0.25*(random(0)*2-1)*exp(-mod(t+0.25,0.5)*60)"
ff -f lavfi -i "testsrc2=s=$SIZE:r=$FPS" -f lavfi -i "aevalsrc='$KICK+$HAT':s=48000" \
   -t "$DUR" -c:v ffv1 -c:a pcm_s16le "$work/src.mkv"
ff -ss 1 -i "$work/src.mkv" -frames:v 1 "$work/still.png"

rm -rf "$out/looks" "$out/effects"
mkdir -p "$out/looks" "$out/effects"

thumbnail() { # CHAIN OUT.jpg
  local chain=$1 jpg=$2 first input source mkv
  first=$("$jq" -r '.layers[0].plugin // empty' "$chain")
  input=$("$jq" -r '.input // empty' "$root/plugins/$first.json" 2>/dev/null || true)
  source=$work/src.mkv
  if [ "$input" = still ]; then source=$work/still.png; fi
  mkv=$("$glitchbox" --root "$root" --toolchain "$tc" render --chain "$chain" \
    --duration "$DUR" --height "$HEIGHT" --fps "$FPS" "$source" </dev/null) || fail "render failed: $chain"
  ff -ss "$AT" -i "$mkv" -frames:v 1 -vf scale=320:180 -q:v 4 "$jpg" || fail "no frame at $AT s: $chain"
  [ -s "$jpg" ] || fail "empty thumbnail: $chain"
}

for chain in "$root"/presets/chains/*.json; do
  name=$(basename "$chain" .json)
  echo "look $name" >&2
  thumbnail "$chain" "$out/looks/$name.jpg"
done

for manifest in "$root"/plugins/*.json; do
  "$jq" -e '.simple | type == "object"' "$manifest" >/dev/null || continue
  id=$(basename "$manifest" .json)
  echo "effect $id" >&2
  "$jq" -n --arg id "$id" '{schema: 1, name: $id, layers: [{plugin: $id, enabled: true, params: {}}]}' \
    > "$work/chains/$id.json"
  thumbnail "$work/chains/$id.json" "$out/effects/$id.jpg"
done
