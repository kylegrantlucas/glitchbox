#!/bin/bash
# Tests FFglitch.xcframework against the macOS prebuilt FFglitch tools.
#
#   packaging/ios/ffglitch/test/run.sh [host] [sim] [ffmpeg]   (default: host)
#
#   host    macos-arm64 slice: mpeg2-mosh's and mv-script's pipe chains and
#           mv-mangle's file invocations in one process, each compared byte for
#           byte with the same command lines run through the prebuilt ffgac/
#           ffedit; then the failure/cancel paths (ffglitch_test.c `errors`).
#   sim     the same chains on the iOS simulator slice via `xcrun simctl spawn`
#           (boots an available iOS 27 simulator if none is booted, and shuts
#           it down again afterwards).
#   ffmpeg  ffgac -> ffedit -> gb_ffmpeg_run (GlitchFFmpeg.xcframework, FFmpeg
#           8.1) concurrently in one process; the output must decode.
#
# GLITCHBOX_HELPERS: the prebuilt toolchain's Contents/Helpers (ffmpeg, ffgac,
# ffedit; default build/Glitchbox.app/Contents/Helpers). Inputs are testsrc2
# clips made with that ffmpeg. Scratch and logs: $FFG_TEST_DIR (default a
# fresh mktemp -d), kept for inspection.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd -P)
XCF=$ROOT/build/ios/xcframeworks
FFG=$XCF/FFglitch.xcframework
HELPERS=${GLITCHBOX_HELPERS:-$ROOT/build/Glitchbox.app/Contents/Helpers}
T=${FFG_TEST_DIR:-$(mktemp -d /tmp/ffglitch-test.XXXXXX)}
TEST_SRC=$ROOT/packaging/ios/ffglitch/test/ffglitch_test.c
MOSH_JS=$ROOT/scripts/mosh.js
MANGLE_JS=$ROOT/scripts/mv-shuffle.js
MOSH_SP='{"tail":10,"h_scale":100,"v_scale":100,"pan_x":0,"pan_y":0}'
MVS_AMOUNT=5
DEPLOY=26.0
fail=0

die() { printf 'run.sh: %s\n' "$*" >&2; exit 1; }
xenv() { env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"; }
same() { # LABEL OURS REF
  if cmp -s "$2" "$3"; then
    echo "  $1: byte-identical to the prebuilt ($(wc -c < "$2" | tr -d ' ') bytes)"
  else
    echo "  $1: DIFFERS from the prebuilt ($(wc -c < "$2" | tr -d ' ') vs $(wc -c < "$3" | tr -d ' ') bytes)"
    fail=1
  fi
}

[ -d "$FFG" ] || die "missing $FFG (packaging/build.sh stage ios_ffglitch)"
for t in ffmpeg ffgac ffedit; do [ -x "$HELPERS/$t" ] || die "missing $HELPERS/$t (set GLITCHBOX_HELPERS)"; done
mkdir -p "$T/logs"
echo "scratch: $T"

# --- inputs and prebuilt references -----------------------------------------
prepare() {
  [ -f "$T/ref-mosh.m2v" ] && return 0
  "$HELPERS/ffmpeg" -hide_banner -loglevel error -y -f lavfi \
    -i testsrc2=size=320x240:rate=25:duration=2 -c:v ffvhuff "$T/in.mkv"
  "$HELPERS/ffmpeg" -hide_banner -loglevel error -y -f lavfi \
    -i testsrc2=size=640x480:rate=25:duration=60 -c:v ffvhuff "$T/long.mkv"
  mkdir -p "$T/ffglitch-scripts"
  tar -xzf "$ROOT/build/downloads/$(jq -r '.sources[] | select(.name == "ffglitch-scripts") | .file' "$ROOT/packaging/sources.json")" \
    -C "$T/ffglitch-scripts" --strip-components 1
  gac=("$HELPERS/ffgac" -hide_banner -nostdin -loglevel error -i "$T/in.mkv" -an
       -mpv_flags +nopimb+forcemv -qscale:v 0 -g max -bf 0 -sc_threshold max
       -vcodec mpeg2video -f rawvideo -)
  "${gac[@]}" | "$HELPERS/ffedit" -i - -f mv -s "$MOSH_JS" -sp "$MOSH_SP" -o - \
    > "$T/ref-mosh.m2v" 2> "$T/logs/ref-mosh.log"
  "${gac[@]}" | "$HELPERS/ffedit" -i - -f mv -s "$MVS_JS" -sp "$MVS_AMOUNT" -o - \
    > "$T/ref-mvscript.m2v" 2> "$T/logs/ref-mvscript.log"
  "$HELPERS/ffgac" -hide_banner -nostdin -loglevel error -i "$T/in.mkv" -an \
    -flags +bitexact -fflags +bitexact -mpv_flags +forcemv+nopimb -qscale:v 3 -g 12 \
    -vcodec mpeg4 -f avi -y "$T/ref-enc.avi"
  "$HELPERS/ffedit" -t -i "$T/ref-enc.avi" -f mv -s "$MANGLE_JS" \
    -sp '{"seed":42,"amount":50}' -o "$T/ref-glitched.avi" 2> "$T/logs/ref-mangle.log"
}
MVS_JS=$T/ffglitch-scripts/free-for-all/dd-glitch-assist-scriptsv10/instant_damage/dd_gravity.js

# RUNNER BIN DIR: the comparison chains (RUNNER runs BIN with its args)
chains() {
  local runner=$1 bin=$2 d=$3
  mkdir -p "$d"
  $runner "$bin" mosh "$T/in.mkv" "$MOSH_JS" "$d/mosh.m2v"
  same "mpeg2-mosh chain (ffgac | ffedit mosh.js)" "$d/mosh.m2v" "$T/ref-mosh.m2v"
  $runner "$bin" mvscript "$T/in.mkv" "$MVS_JS" "$MVS_AMOUNT" "$d/mvscript.m2v"
  same "mv-script chain (ffgac | ffedit dd_gravity.js -sp $MVS_AMOUNT)" "$d/mvscript.m2v" "$T/ref-mvscript.m2v"
  $runner "$bin" mangle "$T/in.mkv" "$MANGLE_JS" "$d/enc.avi" "$d/glitched.avi"
  same "mv-mangle ffgac (mpeg4 avi)" "$d/enc.avi" "$T/ref-enc.avi"
  same "mv-mangle ffedit -t (mv-shuffle.js)" "$d/glitched.avi" "$T/ref-glitched.avi"
}

host_run() { FFG_TEST_LOGDIR=$T/logs "$@"; }

test_host() {
  local fw=$FFG/macos-arm64
  echo "== host (macos-arm64)"
  prepare
  xenv /usr/bin/clang -O2 -Wall -Werror -target arm64-apple-macos$DEPLOY \
    -F"$fw" -framework FFglitch -Wl,-rpath,"$fw" -o "$T/ffglitch_test" "$TEST_SRC"
  chains host_run "$T/ffglitch_test" "$T/host"
  mkdir -p "$T/host/errors"
  host_run "$T/ffglitch_test" errors "$T/in.mkv" "$T/long.mkv" "$MOSH_JS" "$T/host/errors" || fail=1
}

SIM_UDID=
sim_run() { SIMCTL_CHILD_FFG_TEST_LOGDIR=$T/logs xenv xcrun simctl spawn "$SIM_UDID" "$@"; }

test_sim() {
  local fw=$FFG/ios-arm64-simulator sdk booted=
  echo "== iOS simulator (ios-arm64-simulator)"
  prepare
  sdk=$(xenv xcrun --sdk iphonesimulator --show-sdk-path)
  xenv /usr/bin/clang -O2 -Wall -Werror -target arm64-apple-ios$DEPLOY-simulator -isysroot "$sdk" \
    -F"$fw" -framework FFglitch -Wl,-rpath,"$fw" -o "$T/ffglitch_test-sim" "$TEST_SRC"
  SIM_UDID=$(xenv xcrun simctl list devices booted -j |
    jq -r '[.devices | to_entries[] | select(.key | test("iOS-27")) | .value[]] | first | .udid // empty')
  if [ -z "$SIM_UDID" ]; then
    SIM_UDID=$(xenv xcrun simctl list devices available -j |
      jq -r '[.devices | to_entries[] | select(.key | test("iOS-27")) | .value[] | select(.name | test("iPhone"))] | first | .udid // empty')
    [ -n "$SIM_UDID" ] || die "no available iOS 27 iPhone simulator"
    xenv xcrun simctl boot "$SIM_UDID"
    booted=1
  fi
  echo "  simulator $SIM_UDID"
  chains sim_run "$T/ffglitch_test-sim" "$T/sim"
  mkdir -p "$T/sim/errors"
  sim_run "$T/ffglitch_test-sim" errors "$T/in.mkv" "$T/long.mkv" "$MOSH_JS" "$T/sim/errors" || fail=1
  [ -z "$booted" ] || xenv xcrun simctl shutdown "$SIM_UDID"
}

test_ffmpeg() {
  local fw=$FFG/macos-arm64 gb=$XCF/GlitchFFmpeg.xcframework/macos-arm64 frames
  echo "== ffgac -> ffedit -> gb_ffmpeg_run (FFglitch + GlitchFFmpeg in one process)"
  [ -d "$gb" ] || die "missing $gb (packaging/build.sh stage ios_ffmpeg)"
  prepare
  # Any duplicate-symbol diagnostic fails the test (FFglitch's libav* must
  # stay private to its framework).
  xenv /usr/bin/clang -O2 -Wall -Werror -DWITH_GLITCH_FFMPEG -target arm64-apple-macos$DEPLOY \
    -F"$fw" -I"$gb/Headers" -o "$T/ffglitch_test-ffmpeg" "$TEST_SRC" \
    -framework FFglitch -Wl,-rpath,"$fw" "$gb/libGlitchFFmpeg.a" \
    -framework VideoToolbox -framework AudioToolbox -framework CoreMedia -framework CoreVideo \
    -framework CoreFoundation -framework CoreServices -framework CoreAudio \
    -lz -lbz2 -liconv -lc++ 2> "$T/logs/link-ffmpeg.log" || { cat "$T/logs/link-ffmpeg.log"; die "link failed"; }
  if grep -i "duplicate" "$T/logs/link-ffmpeg.log"; then fail=1; fi
  echo "  link diagnostics: $(grep -c . "$T/logs/link-ffmpeg.log" || true) lines"
  host_run "$T/ffglitch_test-ffmpeg" ffmpeg "$T/in.mkv" "$MOSH_JS" "$T/host/ffmpeg.mkv" || fail=1
  frames=$("$HELPERS/ffmpeg" -hide_banner -v error -i "$T/host/ffmpeg.mkv" -map 0:v -f framemd5 - | grep -vc '^#' || true)
  echo "  output decodes: $frames frames (input has 50)"
  [ "$frames" = 50 ] || fail=1
}

[ $# -gt 0 ] || set -- host
for what in "$@"; do
  case $what in
    host) test_host ;;
    sim) test_sim ;;
    ffmpeg) mkdir -p "$T/host"; test_ffmpeg ;;
    *) die "unknown test: $what" ;;
  esac
done
[ $fail = 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
