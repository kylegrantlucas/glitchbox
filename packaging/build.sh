#!/bin/bash
# packaging/build.sh — no-Nix build of Glitchbox.app and its DMG.
#
#   packaging/build.sh [tools|app|dmg|all|verify]      (default: all)
#
#   tools   fetch + verify every input in packaging/sources.json, build the
#           toolchain, assemble it into build/stage/Contents, verify it.
#   app     tools (stamped stages are skipped) + xcodegen/xcodebuild + the
#           glitchbox CLI, merged with the staging into build/Glitchbox.app,
#           signed inside-out, verified.
#   dmg     build/dist/Glitchbox-<packaging/VERSION>.dmg from the app.
#   all     tools, app, dmg.
#   verify  re-run verification on build/Glitchbox.app (or the staging).
#
# Build machine: Xcode 27, cargo/rustc >= 1.96 (bender-rs needs 1.96), cmake,
# curl, jq. Nothing else: pkg-config is GStreamer devel's own, XcodeGen is
# pinned in sources.json. Compilers run under `env -i` with PATH=/usr/bin first
# and a private bin dir holding only cargo, rustc, cmake, and pkg-config, so
# nix-darwin/Homebrew tools on the caller's PATH cannot leak into products.
#
# Environment:
#   GLITCHBOX_SIGN_IDENTITY  codesign identity (default "-", ad-hoc). A real
#                            identity also enables the hardened runtime.
#   CARGO RUSTC CMAKE        override tool resolution.
#
# Stages stamp build/stamps/<stage> with a hash of their recipe, their pinned
# inputs, and their dependencies' stamps; a rerun skips stamped stages.
# Downloads are cached (and re-verified) in build/downloads. This script must
# stay runnable by macOS's /bin/bash 3.2.

set -euo pipefail
umask 022

# --- App and CLI inputs ------------------------------------------------------
# Paths are relative to the repository root.
APP_DIR=app                         # holds project.yml
APP_PROJECT=Glitchbox.xcodeproj     # generated in APP_DIR
APP_SCHEME=Glitchbox
APP_PRODUCT=Glitchbox.app
CLI_PACKAGE=app/GlitchboxKit
CLI_PRODUCT=glitchbox

SIGN_IDENTITY=${GLITCHBOX_SIGN_IDENTITY:--}
DEPLOYMENT_TARGET=26.0

# --- Layout ------------------------------------------------------------------
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PKG=$ROOT/packaging
LOCK=$PKG/sources.json
VERSION=$(tr -d '[:space:]' < "$PKG/VERSION")
BUILD=$ROOT/build
DL=$BUILD/downloads
WORK=$BUILD/work
PREFIX=$BUILD/prefix          # x264/frei0r install prefix + finished binaries
STAMPS=$BUILD/stamps
LOGS=$BUILD/logs
TOOLBIN=$BUILD/toolbin
STAGE=$BUILD/stage/Contents
APP=$BUILD/Glitchbox.app
DIST=$BUILD/dist
GST_V=Versions/1.0
GST_FULL=$BUILD/gst/full/GStreamer.framework       # official runtime, every component
GST_SDK=$BUILD/gst/sdk/GStreamer.framework         # runtime + devel headers/.pc; build only
GST_RUNTIME=$BUILD/gst/runtime/GStreamer.framework # arm64-only, allowlisted plugins: what ships
JOBS=$(sysctl -n hw.ncpu)

# The GStreamer plugins that ship; everything else in the runtime is left out,
# and the libraries are exactly what these plugins and the bundled tools link.
# Traced with GST_DEBUG=GST_PLUGIN_LOADING:4 over ntsc-rs-cli (ffv1 and PNG
# output), bender, and reactive-vcr (including --audio-mode mix) on
# MKV/MP4/MOV/AVI inputs with FFV1, H.264, HEVC, ProRes, MPEG-4 and MJPEG video,
# PNG/JPEG stills, and WAV/FLAC/AAC/MP3/Vorbis/Opus audio. x264 is the H.264
# encoder behind `ntsc-rs-cli -c h264`, `bender --codec h264`, and reactive-vcr
# .mp4 output (with isomp4's mp4mux and libav's avenc_aac); it is the one GPL
# plugin. Added untraced, for the same input families: interlace (ntsc-rs
# interlaced output), dav1d (AV1), mpegpsdemux/mpegtsdemux (.mpg/.ts), aiff,
# apetag, jpeg. Decoding goes through gst-libav's LGPL FFmpeg. applemedia
# (VideoToolbox) is left out: its vtdec fails on ProRes, and software decodes
# are the same on every Mac. verify_contents proves each plugin loads.
GST_PLUGINS="coreelements playback typefindfunctions
  videoconvertscale videorate imagefreeze interlace
  audioconvert audioresample audiomixer audiotestsrc volume
  libav dav1d matroska isomp4 avi mpegpsdemux mpegtsdemux ogg wavparse aiff flac
  audioparsers videoparsersbad id3demux apetag mpg123 opus vorbis
  png jpeg jpegformat multifile x264"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

JQ=$(command -v jq) || die "jq not found"
CMAKE_BIN=${CMAKE:-$(command -v cmake)} || die "cmake not found"
RUSTC_PROXY=${RUSTC:-$(command -v rustc)} || die "rustc not found"
# rustup's cargo/rustc are proxies that need ~/.rustup and its settings; use
# the toolchain they resolve to directly so the build runs with a private HOME.
RUST_SYSROOT=$("$RUSTC_PROXY" --print sysroot)
RUSTC_BIN=$RUST_SYSROOT/bin/rustc
CARGO_BIN=${CARGO:-$RUST_SYSROOT/bin/cargo}
[ -x "$CARGO_BIN" ] || CARGO_BIN=$(command -v cargo) || die "cargo not found"

# Minimal environment for every compiler and build tool.
menv() {
  env -i \
    HOME="$BUILD/home" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" \
    TMPDIR="$BUILD/tmp/" LANG=C LC_ALL=C TERM=dumb \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$TOOLBIN" \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    "$@"
}

# Same for xcodebuild/swift, which need the real HOME (DerivedData, caches).
menv_swift() {
  env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${USER:-$(id -un)}" \
    LANG=C LC_ALL=C TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@"
}

setup_toolbin() {
  rm -rf "$TOOLBIN"
  mkdir -p "$TOOLBIN" "$BUILD/home" "$BUILD/tmp" "$LOGS" "$STAMPS" "$PREFIX/bin"
  ln -s "$CARGO_BIN" "$TOOLBIN/cargo"
  ln -s "$RUSTC_BIN" "$TOOLBIN/rustc"
  ln -s "$CMAKE_BIN" "$TOOLBIN/cmake"
  ln -s "$GST_SDK/$GST_V/bin/pkg-config" "$TOOLBIN/pkg-config" # dangling until gst
}

# --- Pinned inputs -----------------------------------------------------------
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

lock_field() { # NAME FIELD -> value of the first lock entry with that name
  "$JQ" -er --arg n "$1" --arg f "$2" \
    'first(.sources[] | select(.name == $n)) | .[$f]' "$LOCK"
}
src() { printf '%s/%s\n' "$DL" "$(lock_field "$1" file)"; }

fetch() {
  mkdir -p "$DL"
  local file url sum got
  while IFS=$'\t' read -r file url sum; do
    if [ -f "$DL/$file" ] && [ "$(sha256 "$DL/$file")" = "$sum" ]; then continue; fi
    log "fetch $file"
    curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$DL/$file.part" "$url"
    got=$(sha256 "$DL/$file.part")
    if [ "$got" != "$sum" ]; then
      rm -f "$DL/$file.part"
      die "sha256 mismatch for $file: got $got, want $sum"
    fi
    mv "$DL/$file.part" "$DL/$file"
  done < <("$JQ" -r '.sources[] | [.file, .url, .sha256] | @tsv' "$LOCK")
  log "fetch: $("$JQ" '.sources | length' "$LOCK") inputs verified"
}

unpack() { # NAME DEST: extract a source tarball, stripping its top directory
  rm -rf "$2"
  mkdir -p "$2"
  tar -xf "$(src "$1")" -C "$2" --strip-components 1
}

# --- Stage runner ------------------------------------------------------------
stage_deps() {
  case $1 in
    gst) ;;
    gst_runtime) echo gst ;;
    x264 | frei0r | sox | bash) echo gst ;; # gst provides pkg-config
    ffmpeg) echo "gst x264 frei0r" ;;
    ntsc_rs | bender) echo gst ;;
  esac
}
stage_srcs() {
  case $1 in
    gst) echo "gstreamer-runtime gstreamer-devel" ;;
    gst_runtime) ;;
    ntsc_rs) echo ntsc-rs ;;
    bender) echo bender-rs ;;
    bash) echo "bash bash-patch" ;;
    *) echo "$1" ;;
  esac
}
stage_recipe() { # what else, besides build_<stage>, a stage's output depends on
  case $1 in
    gst) declare -f merge_pkg thin_arm64 ;;
    gst_runtime) declare -f gst_closure gst_copy_deps; echo "plugins: $GST_PLUGINS" ;;
    ntsc_rs | bender) declare -f cargo_build ;;
  esac
}
stage_key() {
  local s d
  {
    declare -f "build_$1" menv unpack
    stage_recipe "$1"
    for s in $(stage_srcs "$1"); do
      "$JQ" -c --arg n "$s" '.sources[] | select(.name == $n)' "$LOCK"
    done
    for d in $(stage_deps "$1"); do cat "$STAMPS/$d"; done
    echo "deployment target: $DEPLOYMENT_TARGET"
  } | shasum -a 256 | cut -d' ' -f1
}
run_stage() {
  local s=$1 key
  key=$(stage_key "$s")
  if [ -f "$STAMPS/$s" ] && [ "$(cat "$STAMPS/$s")" = "$key" ]; then
    log "$s: up to date"
    return 0
  fi
  rm -f "$STAMPS/$s"
  log "$s: building (log: build/logs/$s.log)"
  logged "$s" "build_$s"
  printf '%s\n' "$key" > "$STAMPS/$s"
}

logged() { # NAME CMD...: run CMD with errexit, output to build/logs/NAME.log
  local name=$1 rc
  shift
  # Not `( … ) || …`: errexit is ignored inside a compound command that is
  # part of an || list.
  set +e
  (set -e; "$@") > "$LOGS/$name.log" 2>&1
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    tail -n 40 "$LOGS/$name.log" >&2
    die "$name failed (exit $rc); full log: build/logs/$name.log"
  fi
}

# --- GStreamer -----------------------------------------------------------------
# The official installer, expanded with pkgutil (never installed system-wide).
# Its libraries already carry @rpath install names (@rpath/libgstreamer-1.0.0.dylib)
# and @loader_path/../lib rpaths, so the framework is relocatable as shipped.

# Expand an installer one component at a time (--expand, then --flatten and
# --expand-full each component) and merge its payload into FRAMEWORK, so peak
# disk use is one component, not the whole installer: the devel package alone
# expands to ~5 GB, nearly all static libraries, which are dropped here.
merge_pkg() { # PKG FRAMEWORK
  local pkg=$1 fw=$2 x=$WORK/pkg p c v
  v=$(lock_field gstreamer-runtime version)
  rm -rf "$x"
  mkdir -p "$x"
  /usr/sbin/pkgutil --expand "$pkg" "$x/flat"
  for p in "$x/flat/"*.pkg; do
    /usr/sbin/pkgutil --flatten "$p" "$x/one.pkg"
    rm -rf "$p"
    /usr/sbin/pkgutil --expand-full "$x/one.pkg" "$x/one"
    rm -f "$x/one.pkg"
    find "$x/one/Payload" -type f \( -name '*.a' -o -name '*.la' \) -delete
    c=$(basename "$p" "-$v-universal.pkg")
    case $c in
      osx-framework) ditto "$x/one/Payload" "$fw" ;; # framework root
      *) ditto "$x/one/Payload" "$fw/$GST_V" ;;
    esac
    rm -rf "$x/one"
  done
  rm -rf "$x"
  rm -f "$fw/.gitignore"
  chmod -R u+w,go-w,a+rX "$fw"
}

# Thin universal Mach-O to arm64 in place. Each slice keeps its own signature.
thin_arm64() { # DIR
  local f mode
  find "$1" -type f -print0 | while IFS= read -r -d '' f; do
    case $(lipo -archs "$f" 2>/dev/null) in
      *x86_64*arm64* | *arm64*x86_64*)
        mode=$(stat -f %Lp "$f")
        lipo -thin arm64 "$f" -output "$f.thin"
        mv -f "$f.thin" "$f"
        chmod "$mode" "$f"
        ;;
    esac
  done
}

# GST_FULL: every runtime component, arm64 only. GST_SDK: devel headers, .pc
# files and pkg-config, plus an APFS clone of GST_FULL. Devel goes first so its
# largest component expands while the runtime does not yet occupy the disk.
build_gst() {
  rm -rf "$BUILD/gst/full" "$BUILD/gst/sdk"
  mkdir -p "$GST_FULL" "$GST_SDK"
  merge_pkg "$(src gstreamer-devel)" "$GST_SDK"
  merge_pkg "$(src gstreamer-runtime)" "$GST_FULL"
  thin_arm64 "$GST_FULL"
  cp -cRP "$GST_FULL/" "$GST_SDK/"
  "$GST_SDK/$GST_V/bin/pkg-config" --version
  PKG_CONFIG_LIBDIR="$GST_SDK/$GST_V/lib/pkgconfig" \
    "$GST_SDK/$GST_V/bin/pkg-config" --modversion gstreamer-1.0 gstreamer-video-1.0
  du -sh "$GST_FULL" "$GST_SDK"
}

gst_closure() { # VDIR FILE...: ./lib/<name> for the FILEs' @rpath deps, transitively.
  # FILEs are relative to VDIR, or absolute; dependencies resolve in VDIR/lib.
  local v=$1 q=$2 seen f n id
  seen=$(mktemp)
  while [ -n "$q" ]; do
    f=${q%% *}
    case $q in *" "*) q=${q#* } ;; *) q= ;; esac
    case $f in /*) ;; *) f=$v/$f ;; esac
    # otool -L lists a dylib's own install name first; that is not a dependency.
    id=$(otool -D "$f" | sed -n 2p)
    for n in $(otool -L "$f" | awk -v id="$id" 'NR > 1 && $1 != id { print $1 }' \
               | sed -n 's|^@rpath/\(lib[^/]*\)$|lib/\1|p' | sort -u); do
      grep -qxF "./$n" "$seen" && continue
      echo "./$n" >> "$seen"
      q="${q:+$q }$n"
    done
  done
  cat "$seen"
  rm -f "$seen"
}

# Copy into DEST-VDIR/lib every library the FILEs need, from the full runtime.
gst_copy_deps() { # DEST-VDIR FILE...
  local dest=$1 f
  shift
  for f in $(gst_closure "$GST_FULL/$GST_V" "$*"); do
    [ -e "$dest/$f" ] || cp -cp "$GST_FULL/$GST_V/$f" "$dest/$f"
  done
}

# Shipping copy: the GST_PLUGINS, the plugin scanner, and their libraries. The
# bundled tools' own libraries are added at assembly (assemble_stage).
build_gst_runtime() {
  local v=$GST_RUNTIME/$GST_V full=$GST_FULL/$GST_V p f seeds=libexec/gstreamer-1.0/gst-plugin-scanner
  rm -rf "$BUILD/gst/runtime"
  mkdir -p "$v/lib/gstreamer-1.0" "$v/libexec/gstreamer-1.0"
  ditto "$full/Resources" "$v/Resources"
  ln -s 1.0 "$GST_RUNTIME/Versions/Current"
  ln -s Versions/Current/Resources "$GST_RUNTIME/Resources"
  ln -s Versions/Current/GStreamer "$GST_RUNTIME/GStreamer"
  cp -cp "$full/$seeds" "$v/$seeds"
  for p in $GST_PLUGINS; do
    f=lib/gstreamer-1.0/libgst$p.dylib
    [ -f "$full/$f" ] || die "gst_runtime: GStreamer has no plugin '$p'"
    cp -cp "$full/$f" "$v/$f"
    seeds="$seeds $f"
  done
  gst_copy_deps "$v" $seeds
  # Nothing links the umbrella library (the tools link lib/libgst*.dylib), and
  # the real one re-exports every library in the runtime. An empty stub with
  # the same install name keeps the framework a valid, signable bundle.
  menv xcrun clang -x c /dev/null -dynamiclib -arch arm64 \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -install_name "$(otool -D "$full/GStreamer" | tail -1)" -o "$v/GStreamer"
  du -sh "$GST_FULL" "$GST_RUNTIME"
  ls "$v/lib" | wc -l
}

# --- Native helpers ----------------------------------------------------------
build_x264() {
  local s=$WORK/x264
  unpack x264 "$s"
  cd "$s"
  menv ./configure --prefix="$PREFIX" --enable-static --enable-pic \
    --disable-cli --disable-opencl
  menv make -j"$JOBS"
  menv make install
  rm -rf "$s"
}

# Every plugin that builds without extra deps: OpenCV, Cairo, and gavl are
# switched off, and CMake may not search /usr/local, Homebrew, or its own
# (Nix) prefix. vf_frei0r looks for "<name>$SLIBSUF" — ".dylib" on darwin —
# but CMake names MODULE libraries ".so"; the staging renames them.
build_frei0r() {
  local s=$WORK/frei0r cmake_prefix
  cmake_prefix=$(cd "$(dirname "$(readlink -f "$CMAKE_BIN")")/.." && pwd -P)
  unpack frei0r "$s"
  menv cmake -S "$s" -B "$s/b" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DWITHOUT_OPENCV=ON -DWITHOUT_GAVL=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenCV=ON -DCMAKE_DISABLE_FIND_PACKAGE_Cairo=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
    -DCMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew;/opt/local;$cmake_prefix"
  menv cmake --build "$s/b" -j "$JOBS"
  rm -rf "$PREFIX/lib/frei0r-1"
  menv cmake --install "$s/b"
  ls "$PREFIX/lib/frei0r-1"
  rm -rf "$s"
}

# Static GPL build: libx264 (static) + frei0r, Apple's VideoToolbox and
# AudioToolbox, system zlib/bzip2/iconv only (--disable-autodetect). Every
# native filter, encoder, and muxer is compiled in (ffv1, png, pcm_s16le,
# libx264; matroska/mp4/avi; geq, lagfun, tblend, datascope, rgbashift, …).
# --prefix only seeds the data-dir string; nothing is installed there. With
# --disable-autodetect configure takes iconv to be libc's: its probe links,
# ffmpeg_g does not, so libiconv (/usr/lib) is named explicitly.
build_ffmpeg() {
  local s=$WORK/ffmpeg
  unpack ffmpeg "$s"
  cd "$s"
  menv CPATH="$PREFIX/include" ./configure \
    --prefix=/var/empty --cc=/usr/bin/clang --cxx=/usr/bin/clang++ \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --disable-autodetect --enable-static --disable-shared \
    --enable-gpl --enable-libx264 --enable-frei0r \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv \
    --disable-ffplay --disable-doc --disable-debug
  menv CPATH="$PREFIX/include" make -j"$JOBS"
  ./ffmpeg -hide_banner -buildconf > /dev/null
  install -m 755 ffmpeg ffprobe "$PREFIX/bin/"
  rm -rf "$s"
}

# sonify only reads/writes raw and WAV, so every optional format library and
# the ltdl plugin loader are off; CoreAudio stays (system framework).
# Upstream 14.4.2 (nixpkgs used an autoreconf'd 2021 git snapshot) needs two
# fixes for modern clang:
#  - its seek handlers take uint64_t where the handler type says sox_uint64_t
#    (unsigned long long vs unsigned long, the same 64-bit type on arm64);
#    clang makes that an error, so it is downgraded back to a warning.
#  - sox.h marks sox_version()/sox_version_info() __attribute__((pure)) though
#    they fill static buffers; clang drops the writes and `sox --version`
#    prints "SoX v" with no version. The attribute is removed.
build_sox() {
  local s=$WORK/sox
  unpack sox "$s"
  cd "$s"
  grep -q '^#define LSX_RETURN_PURE __attribute__ ((pure))' src/sox.h
  sed -i '' 's/^#define LSX_RETURN_PURE __attribute__ ((pure))/#define LSX_RETURN_PURE/' src/sox.h
  menv CFLAGS="-O2 -Wno-error=incompatible-function-pointer-types" \
    ./configure --prefix=/var/empty --disable-shared --enable-static \
    --without-libltdl --without-magic --without-png --without-ladspa \
    --without-mad --without-id3tag --without-lame --without-twolame \
    --without-oggvorbis --without-opus --without-flac --without-amrwb \
    --without-amrnb --without-wavpack --without-sndfile --without-mp3 \
    --without-ao --without-pulseaudio --without-alsa --without-oss \
    --without-sndio --without-sunaudio --with-coreaudio
  menv make -j"$JOBS"
  case $(./src/sox --version) in *"SoX v14.4.2") ;; *) exit 1 ;; esac
  install -m 755 src/sox "$PREFIX/bin/sox"
  rm -rf "$s"
}

build_bash() {
  local s=$WORK/bash p
  unpack bash "$s"
  cd "$s"
  for p in $("$JQ" -r '.sources[] | select(.name == "bash-patch") | .file' "$LOCK"); do
    patch -p0 -s < "$DL/$p"
  done
  menv ./configure --prefix=/var/empty --disable-nls
  menv make -j"$JOBS"
  ./bash -c 'echo "$BASH_VERSION"'
  install -m 755 bash "$PREFIX/bin/bash"
  rm -rf "$s"
}

# --- Rust tools against the bundled GStreamer ----------------------------------
# The framework's libraries are @rpath/lib*.dylib with @loader_path/../lib
# rpaths, so the executables need …/GStreamer.framework/Versions/1.0/lib on
# their rpath; @executable_path/../Frameworks is added for framework-style
# references. The registry cache lives in build/downloads (cached download).
# Release strip is off: cargo's default strip=debuginfo runs Xcode 27's
# `strip -S`, which on chained-fixup images (deployment targets 14.0, 15.0,
# 26.0 tried; 11.0 has no chained fixups and is fine) writes a LINKEDIT that
# dyld rejects ("mis-aligned LINKEDIT string pool"): every proc-macro dylib
# fails to load and the build dies with E0463.
# Source paths are remapped so panic messages carry /cargo/…, /build/…, and
# /rust/… instead of this checkout's or the toolchain's absolute path.
cargo_build() { # SRCDIR TARGETDIR CARGO-ARGS...
  local dir=$1 target=$2 flags
  shift 2
  local -a f=(
    -C "link-arg=-Wl,-rpath,@executable_path/../Frameworks/GStreamer.framework/$GST_V/lib"
    -C "link-arg=-Wl,-rpath,@executable_path/../Frameworks"
    "--remap-path-prefix=$DL/cargo-home=/cargo"
    "--remap-path-prefix=$WORK=/build"
    "--remap-path-prefix=$RUST_SYSROOT=/rust"
  )
  flags=$(IFS=$'\x1f'; printf '%s' "${f[*]}")
  (cd "$dir" && menv \
    CARGO_HOME="$DL/cargo-home" CARGO_TARGET_DIR="$target" CARGO_TERM_COLOR=never \
    CARGO_PROFILE_RELEASE_STRIP=false \
    RUSTC="$TOOLBIN/rustc" \
    PKG_CONFIG="$TOOLBIN/pkg-config" PKG_CONFIG_LIBDIR="$GST_SDK/$GST_V/lib/pkgconfig" \
    CARGO_ENCODED_RUSTFLAGS="$flags" \
    cargo build --release --locked "$@")
}

# There is no ntsc-rs-cli crate: the CLI is a [[bin]] of ntsc-rs-gui, so the
# GUI crates compile too. The lockfile's git dependencies (fontique,
# after-effects) are fetched by cargo itself.
build_ntsc_rs() {
  local s=$WORK/ntsc-rs
  unpack ntsc-rs "$s"
  cargo_build "$s" "$WORK/ntsc-rs-target" -p ntsc-rs-gui --bin ntsc-rs-cli
  install -m 755 "$WORK/ntsc-rs-target/release/ntsc-rs-cli" "$PREFIX/bin/"
  rm -rf "$WORK/ntsc-rs-target"
}

# bender-rs needs Rust >= 1.96. Its presets/ ship as Resources/bender-presets.
build_bender() {
  local s=$WORK/bender-rs
  unpack bender-rs "$s"
  cargo_build "$s" "$WORK/bender-target" -p bender-cli
  install -m 755 "$WORK/bender-target/release/bender" "$PREFIX/bin/"
  rm -rf "$WORK/bender-target"
}

TOOL_STAGES="gst gst_runtime x264 frei0r ffmpeg sox bash ntsc_rs bender"

# --- Staging -------------------------------------------------------------------
digest() { cat "$LOCK" "$PKG/build.sh" | shasum -a 256 | cut -d' ' -f1; }

# The runtime environment, each entry tested by running without it:
#   FREI0R_PATH       required: without it vf_frei0r searches only
#                     ~/.frei0r-1/lib and /usr/{local/,}lib{,64}/frei0r-1.
#   FFGLITCH_SCRIPTS  read by plugins/mv-script.json; BENDER_PRESETS by
#                     pipelines/bend (default --preset).
#   GST_PLUGIN_SYSTEM_PATH  hermeticity: the framework finds its own plugins
#                     and scanner relative to libgstreamer, but without this
#                     it also scans ~/.local/share/gstreamer-1.0/plugins.
#   GST_REGISTRY      isolation: the default ~/.cache/gstreamer-1.0/
#                     registry.aarch64.bin is shared with every other
#                     GStreamer; keyed by digest so each build rescans once.
# GST_PLUGIN_SCANNER is not set: the relocated scanner is found without it.
write_toolchain_json() { # OUT
  local d bashv
  d=$(digest)
  bashv=$("$PREFIX/bin/bash" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"')
  "$JQ" -n --arg digest "$d" --arg reg "@cache/gstreamer-${d:0:12}.bin" \
    --arg bash "$bashv" --slurpfile lock "$LOCK" '
    def v($n): first($lock[0].sources[] | select(.name == $n)) | .version;
    {
      schema: 1,
      digest: $digest,
      tools: {
        ffmpeg: v("ffmpeg"), ffglitch: v("ffglitch"), "ntsc-rs-cli": v("ntsc-rs"),
        bender: v("bender-rs"), "reactive-vcr": v("reactive-vcr"),
        gstreamer: v("gstreamer-runtime"), frei0r: v("frei0r"), x264: v("x264"),
        jq: v("jq"), sox: v("sox"), bash: $bash
      },
      path: ["@contents/Helpers"],
      environment: {
        FREI0R_PATH: "@contents/PlugIns/frei0r-1",
        FFGLITCH_SCRIPTS: "@contents/Resources/ffglitch-scripts",
        BENDER_PRESETS: "@contents/Resources/bender-presets",
        GST_PLUGIN_SYSTEM_PATH: "@contents/Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
        GST_REGISTRY: $reg
      }
    }' > "$1"
}

assemble_stage() {
  local c=$STAGE x=$WORK/assemble f n
  log "stage: assembling build/stage/Contents"
  rm -rf "$BUILD/stage" "$x"
  mkdir -p "$c/Helpers" "$c/Frameworks" "$c/PlugIns/frei0r-1" "$c/Resources" "$x"

  for n in ffmpeg ffprobe ntsc-rs-cli bender sox bash; do
    install -m 755 "$PREFIX/bin/$n" "$c/Helpers/$n"
  done
  # Upstream prebuilts, byte-for-byte: their ad-hoc linker signatures seal the
  # file contents, so stripping or rewriting them makes the kernel kill them.
  unzip -q "$(src ffglitch)" -d "$x/ffglitch"
  for n in ffgac ffedit fflive qjs; do cp -p "$x/ffglitch/"*/"$n" "$c/Helpers/$n"; done
  # reactive-vcr >= 0.4 is a GStreamer app bundle built against the same
  # official 1.28.8 runtime. Only its CLI ships: its rpath is
  # @executable_path/../Frameworks/GStreamer.framework/Versions/1.0/lib, which
  # from Helpers/ is our framework. Its own framework copy and GUI are dropped.
  mkdir -p "$x/rvcr"
  tar -xf "$(src reactive-vcr)" -C "$x/rvcr" --strip-components 1
  cp -p "$x/rvcr/reactive-vcr.app/Contents/MacOS/reactive-vcr" "$c/Helpers/reactive-vcr"
  cp "$(src jq)" "$c/Helpers/jq"
  chmod 755 "$c/Helpers/"*

  for f in "$PREFIX/lib/frei0r-1/"*.so; do
    install -m 755 "$f" "$c/PlugIns/frei0r-1/$(basename "$f" .so).dylib"
  done

  cp -cRP "$GST_RUNTIME" "$c/Frameworks/GStreamer.framework"
  # The libraries ntsc-rs-cli, bender, and reactive-vcr link directly.
  gst_copy_deps "$c/Frameworks/GStreamer.framework/$GST_V" "$c/Helpers/"*

  mkdir -p "$c/Resources/library"
  for n in plugins presets scripts pipelines; do
    cp -R "$ROOT/$n" "$c/Resources/library/$n"
  done
  find "$c/Resources/library" -name .DS_Store -delete
  mkdir -p "$c/Resources/ffglitch-scripts" "$x/bender"
  tar -xf "$(src ffglitch-scripts)" -C "$c/Resources/ffglitch-scripts" --strip-components 1
  tar -xf "$(src bender-rs)" -C "$x/bender" --strip-components 1
  cp -R "$x/bender/presets" "$c/Resources/bender-presets"
  write_toolchain_json "$c/Resources/toolchain.json"
  rm -rf "$x"
}

# --- Verification ----------------------------------------------------------------
is_macho() {
  case $(head -c 4 "$1" | od -An -tx1 | tr -d ' \n') in
    cffaedfe | cefaedfe | cafebabe | bebafeca) return 0 ;;
  esac
  return 1
}

# Every load command and rpath must be system, @rpath, or bundle-relative.
check_linkage() { # CONTENTS
  local f bad=0 n=0 out
  out=$WORK/verify-linkage.txt
  : > "$out"
  while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    n=$((n + 1))
    {
      otool -L "$f" | tail -n +2 | awk -v f="$f" '!/:$/ { print f "\tdylib\t" $1 }'
      otool -D "$f" | tail -n +2 | awk -v f="$f" '!/:$/ { print f "\tid\t" $1 }'
      otool -l "$f" | awk -v f="$f" '/cmd LC_RPATH/ { r = 1 } r && $1 == "path" { print f "\trpath\t" $2; r = 0 }'
    } >> "$out"
  done < <(find "$1" -type f -print0)
  if awk -F'\t' '$3 !~ /^(\/usr\/lib\/|\/System\/Library\/|@rpath\/|@loader_path(\/|$)|@executable_path(\/|$))/' "$out" | grep .; then
    bad=1
  fi
  if cut -f3 "$out" | grep -E '/nix/store|/opt/homebrew|/usr/local|'"$BUILD"; then bad=1; fi
  [ $bad -eq 0 ] || die "verify: forbidden load paths (above)"
  log "verify: $n Mach-O files, $(wc -l < "$out" | tr -d ' ') load commands/rpaths, all system or bundle-relative"
  check_rpath_resolution "$1" "$out"
}

# Every @rpath dependency must exist under one of the file's own rpaths or,
# for a library, an rpath of some executable in the bundle. This is what
# proves the GStreamer prune left no plugin or library without its deps.
check_rpath_resolution() { # CONTENTS LINKAGE-FILE
  local -a a
  local i ok n=0 bad=0
  while IFS=$'\t' read -r -a a; do
    n=$((n + 1))
    ok=
    for ((i = 2; i < ${#a[@]}; i++)); do
      [ -e "${a[$i]}" ] && { ok=1; break; }
    done
    [ -n "$ok" ] || { printf 'unresolved: %s needs %s\n' "${a[0]}" "${a[1]}" >&2; bad=1; }
  done < <(awk -F'\t' -v c="$1" '
    function dir(p) { sub(/\/[^\/]*$/, "", p); return p }
    function isexe(p) { return p ~ ("^" c "/(Helpers|MacOS)/") || p ~ /\/libexec\/gstreamer-1\.0\/[^\/]*$/ || p ~ /\/Versions\/1\.0\/bin\/[^\/]*$/ }
    $2 == "rpath" { rp[$1] = rp[$1] "\t" $3; next }
    $2 == "id" { id[$1 "\t" $3] = 1; next }
    $2 == "dylib" && $3 ~ /^@rpath\// { dep[++nd] = $1 "\t" $3 }
    END {
      for (f in rp) if (isexe(f)) {
        k = split(substr(rp[f], 2), r, "\t")
        for (j = 1; j <= k; j++) { x = r[j]; sub(/^@loader_path|^@executable_path/, dir(f), x); exerp[x] = 1 }
      }
      for (i = 1; i <= nd; i++) {
        if (dep[i] in id) continue # the install name of the library itself
        split(dep[i], d, "\t"); f = d[1]; name = substr(d[2], 8); line = f "\t" d[2]
        k = split(substr(rp[f], 2), r, "\t")
        for (j = 1; j <= k; j++) {
          x = r[j]; sub(/^@loader_path/, dir(f), x)
          if (x ~ /^@executable_path/) {
            # A library sees the loading executable; covered by exerp below.
            if (isexe(f)) { sub(/^@executable_path/, dir(f), x); line = line "\t" x "/" name }
          } else line = line "\t" x "/" name
        }
        if (!isexe(f)) for (e in exerp) line = line "\t" e "/" name
        print line
      }
    }' "$2")
  [ $bad -eq 0 ] || die "verify: unresolved @rpath dependencies (above)"
  log "verify: all $n @rpath dependencies resolve inside the bundle"
}

# Run a command with nothing but HOME, a minimal PATH, and toolchain.json's
# environment (expanded), Helpers first on PATH.
tenv() { # CONTENTS CACHE CMD...
  local c=$1 cache=$2
  shift 2
  local -a vars=()
  local kv
  while IFS= read -r kv; do vars+=("$kv"); done < <(
    "$c/Helpers/jq" -r --arg c "$c" --arg k "$cache" '
      .environment | to_entries[]
      | "\(.key)=\(.value | gsub("@contents"; $c) | gsub("@cache"; $k))"' \
      "$c/Resources/toolchain.json")
  local path
  path=$("$c/Helpers/jq" -r --arg c "$c" '.path | map(gsub("@contents"; $c)) | join(":")' \
    "$c/Resources/toolchain.json")
  env -i HOME="$HOME" PATH="$path:/usr/bin:/bin" "${vars[@]}" "$@"
}

smoke_gst() { # CONTENTS CACHE DIR: ntsc-rs-cli, bender, reactive-vcr renders through the shipped plugins
  local c=$1 k=$2 d=$3
  local vhs=$c/Resources/library/presets/vhs.json
  [ -f "$d/in.mkv" ] || tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc=size=320x240:rate=30:duration=1 -pix_fmt yuv420p -c:v ffv1 "$d/in.mkv"
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    ntsc-rs-cli -i "$d/in.mkv" -o "$d/ntsc.mkv" -c ffv1 -y -j "$(cat "$vhs")" \
    > "$d/ntsc.log" 2>&1 || { tail -20 "$d/ntsc.log"; die "verify: ntsc-rs-cli failed"; }
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    bender -i "$d/in.mkv" -o "$d/bender.mkv" --codec ffv1 --scanlines 0 \
    --preset "$c/Resources/bender-presets/meltdown.json" --overwrite \
    > "$d/bender.log" 2>&1 || { tail -20 "$d/bender.log"; die "verify: bender failed"; }
  [ -f "$d/in.wav" ] || tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i sine=frequency=440:sample_rate=48000:duration=1 -c:a pcm_s16le "$d/in.wav"
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    reactive-vcr render --video "$d/in.mkv" --audio "$d/in.wav" \
    --map "$c/Resources/library/presets/reactive-vcr.toml" --audio-mode none -o "$d/rvcr.mkv" \
    > "$d/rvcr.log" 2>&1 || { tail -20 "$d/rvcr.log"; die "verify: reactive-vcr failed"; }
  # Inputs outside the FFV1 path, so the GST_PLUGINS allowlist is exercised:
  # H.264/AAC in MP4 and a PNG still into ntsc-rs, AAC (M4A) audio driving
  # reactive-vcr while it mixes in the MP4's own audio.
  [ -f "$d/in.mp4" ] || tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -f lavfi -i sine=frequency=330:duration=1 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac "$d/in.mp4"
  [ -f "$d/in.png" ] || tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240 -frames:v 1 "$d/in.png"
  [ -f "$d/in.m4a" ] || tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
    -i "$d/in.wav" -c:a aac "$d/in.m4a"
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    ntsc-rs-cli -i "$d/in.mp4" -o "$d/ntsc-mp4.mkv" -c ffv1 -y -j "$(cat "$vhs")" \
    > "$d/ntsc-mp4.log" 2>&1 || { tail -20 "$d/ntsc-mp4.log"; die "verify: ntsc-rs-cli on H.264/MP4 failed"; }
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    ntsc-rs-cli -i "$d/in.png" -o "$d/ntsc-png.mkv" -c ffv1 -y -j "$(cat "$vhs")" \
    > "$d/ntsc-png.log" 2>&1 || { tail -20 "$d/ntsc-png.log"; die "verify: ntsc-rs-cli on a PNG still failed"; }
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    reactive-vcr render --video "$d/in.mp4" --audio "$d/in.m4a" \
    --map "$c/Resources/library/presets/reactive-vcr.toml" --audio-mode mix -o "$d/rvcr-mp4.mkv" \
    > "$d/rvcr-mp4.log" 2>&1 || { tail -20 "$d/rvcr-mp4.log"; die "verify: reactive-vcr on MP4 + M4A failed"; }
  # H.264 output (x264enc + mp4mux) from each tool.
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    ntsc-rs-cli -i "$d/in.mkv" -o "$d/ntsc-h264.mp4" -c h264 -y -j "$(cat "$vhs")" \
    > "$d/ntsc-h264.log" 2>&1 || { tail -20 "$d/ntsc-h264.log"; die "verify: ntsc-rs-cli H.264 output failed"; }
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    bender -i "$d/in.mkv" -o "$d/bender-h264.mp4" --codec h264 --scanlines 0 \
    --preset "$c/Resources/bender-presets/meltdown.json" --overwrite \
    > "$d/bender-h264.log" 2>&1 || { tail -20 "$d/bender-h264.log"; die "verify: bender H.264 output failed"; }
  tenv "$c" "$k" env GST_DEBUG=GST_PLUGIN_LOADING:2,GST_REGISTRY:2 \
    reactive-vcr render --video "$d/in.mp4" --audio "$d/in.wav" \
    --map "$c/Resources/library/presets/reactive-vcr.toml" --audio-mode mix -o "$d/rvcr-h264.mp4" \
    > "$d/rvcr-h264.log" 2>&1 || { tail -20 "$d/rvcr-h264.log"; die "verify: reactive-vcr .mp4 output failed"; }
  if grep -h 'Failed to load plugin\|WARN.*GST_PLUGIN_LOADING' "$d/"*.log; then
    die "verify: GStreamer plugins failed to load (above)"
  fi
  [ -f "${k}/gstreamer-$(digest | cut -c1-12).bin" ] || die "verify: GST_REGISTRY not written to $k"
  local o fr
  for o in ntsc bender rvcr ntsc-mp4 rvcr-mp4; do
    fr=$(tenv "$c" "$k" ffprobe -v error -count_frames -select_streams v:0 \
      -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$d/$o.mkv")
    case $fr in ffv1,2[89] | ffv1,3[01]) ;; *) die "verify: $o output is '$fr', want ffv1,~30 frames" ;; esac
    log "verify: $o render from $c: $fr frames"
  done
  for o in ntsc-h264 bender-h264 rvcr-h264; do
    fr=$(tenv "$c" "$k" ffprobe -v error -count_frames -select_streams v:0 \
      -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$d/$o.mp4")
    case $fr in h264,2[89] | h264,3[01]) ;; *) die "verify: $o output is '$fr', want h264,~30 frames" ;; esac
    log "verify: $o render from $c: $fr frames"
  done
  fr=$(tenv "$c" "$k" ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$d/ntsc-png.mkv")
  case $fr in ffv1,[1-9]*) ;; *) die "verify: ntsc-png output is '$fr', want ffv1 frames" ;; esac
  log "verify: ntsc-png render from $c: $fr frames"
}

first_line() { # CMD...: run CMD, print its first output line (no SIGPIPE)
  local o
  o=$("$@")
  printf '%s\n' "${o%%$'\n'*}"
}

smoke_all() { # CONTENTS
  local c=$1 d k f out
  d=$(mktemp -d "$BUILD/tmp/verify.XXXXXX")
  k=$d/cache
  mkdir -p "$k"
  tenv "$c" "$k" ffmpeg -hide_banner -filters | grep frei0r
  for f in vertigo glitch0r; do
    for out in mkv:ffv1 mp4:libx264; do
      tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 \
        -vf "frei0r=filter_name=$f,format=yuv420p" -c:v "${out#*:}" "$d/$f.${out%%:*}"
      log "verify: ffmpeg frei0r $f -> ${out#*:}/${out%%:*}: $(tenv "$c" "$k" ffprobe -v error \
        -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$d/$f.${out%%:*}") frames"
    done
  done
  for f in ffgac ffedit; do first_line tenv "$c" "$k" "$f" -version; done
  tenv "$c" "$k" reactive-vcr --version
  tenv "$c" "$k" jq --version
  tenv "$c" "$k" sox --version
  out=$(first_line tenv "$c" "$k" bash --version)
  echo "$out"
  case $out in *"version 5."*) ;; *) die "verify: bash is not 5.x" ;; esac
  smoke_gst "$c" "$k" "$d"
  rm -rf "$d"
}

# The bundle must run from anywhere: copy it to /tmp, rerun the GStreamer
# smoke there, and check dyld loaded nothing from outside the copy or the OS.
smoke_relocated() { # BUNDLE-DIR (the .app, or build/stage)
  local t c d real
  t=$(mktemp -d /tmp/glitchbox-verify.XXXXXX)
  cp -cRP "$1" "$t/"
  c=$t/$(basename "$1")/Contents
  d=$t/run
  mkdir -p "$d/cache"
  smoke_gst "$c" "$d/cache" "$d"
  # A render with a fresh registry, so the plugin scanner runs too.
  mkdir -p "$d/cache2"
  tenv "$c" "$d/cache2" env DYLD_PRINT_LIBRARIES=1 ntsc-rs-cli -i "$d/in.mkv" -o "$d/dyld.mkv" \
    -c ffv1 -y -j "$(cat "$c/Resources/library/presets/vhs.json")" > /dev/null 2> "$d/dyld.log"
  real=$(cd "$t" && pwd -P)
  awk '/^dyld\[[0-9]+\]: <[0-9A-F-]+> / { print $3 }' "$d/dyld.log" > "$d/images.txt"
  if grep -v -e "^$real/" -e '^/usr/lib/' -e '^/System/' "$d/images.txt"; then
    die "verify: relocated ntsc-rs-cli loaded images from outside the copy (above)"
  fi
  log "verify: relocated render at $t: dyld loaded $(grep -c "^$real/" "$d/images.txt") images from the copy, $(grep -vc "^$real/" "$d/images.txt") from the OS, none elsewhere"
  rm -rf "$t"
}

verify_contents() { # BUNDLE-DIR
  local c=$1/Contents
  log "verify: $c"
  check_linkage "$c"
  smoke_all "$c"
  smoke_relocated "$1"
}

# --- App ---------------------------------------------------------------------------
sign() { # PATH...
  if [ "$SIGN_IDENTITY" = - ]; then
    codesign --force --sign - "$@"
  else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"
  fi
}

# Inside-out: Helpers, PlugIns, Frameworks, then the app.
sign_app() {
  local c=$APP/Contents f
  local -a machos=()
  for f in "$c/Helpers/"*; do
    case $(basename "$f") in
      # Upstream prebuilts keep their own ad-hoc linker signature unless a
      # real identity is requested (re-signing them was verified to keep them
      # runnable; verify reruns them afterwards either way).
      ffgac | ffedit | fflive | qjs | reactive-vcr | jq) [ "$SIGN_IDENTITY" = - ] && continue ;;
    esac
    sign "$f"
  done
  sign "$c/PlugIns/frei0r-1/"*.dylib
  while IFS= read -r -d '' f; do
    is_macho "$f" && machos+=("$f")
  done < <(find "$c/Frameworks/GStreamer.framework/$GST_V" -type f -print0)
  sign "${machos[@]}"
  sign "$c/Frameworks/GStreamer.framework"
  sign "$APP"
}

# xcodegen + xcodebuild for the app, swift build for the CLI; records the CLI
# product path in build/work/cli-path.
compile_app() {
  local xg=$WORK/xcodegen bin
  rm -rf "$xg"
  mkdir -p "$xg"
  unzip -q "$(src xcodegen)" -d "$xg"
  (cd "$ROOT/$APP_DIR" && menv_swift "$xg/xcodegen/bin/xcodegen" generate)
  menv_swift xcodebuild -project "$ROOT/$APP_DIR/$APP_PROJECT" -scheme "$APP_SCHEME" \
    -configuration Release -derivedDataPath "$WORK/xcode" build
  menv_swift swift build -c release --package-path "$ROOT/$CLI_PACKAGE" \
    --product "$CLI_PRODUCT" --scratch-path "$WORK/swiftpm"
  bin=$(menv_swift swift build -c release --package-path "$ROOT/$CLI_PACKAGE" \
    --scratch-path "$WORK/swiftpm" --show-bin-path)
  [ -d "$WORK/xcode/Build/Products/Release/$APP_PRODUCT" ]
  [ -x "$bin/$CLI_PRODUCT" ]
  printf '%s\n' "$bin/$CLI_PRODUCT" > "$WORK/cli-path"
}

build_app() {
  [ -f "$ROOT/$APP_DIR/project.yml" ] || die "app: $APP_DIR/project.yml not found"
  [ -d "$STAGE" ] || die "app: no toolchain staging; run build.sh tools"
  local product=$WORK/xcode/Build/Products/Release/$APP_PRODUCT cli
  log "app: xcodegen, xcodebuild $APP_SCHEME Release, swift build $CLI_PRODUCT (log: build/logs/app.log)"
  logged app compile_app
  cli=$(cat "$WORK/cli-path")

  log "app: assembling build/Glitchbox.app"
  rm -rf "$APP"
  cp -cRP "$product" "$APP"
  cp -cRP "$STAGE/Helpers" "$STAGE/Frameworks" "$STAGE/PlugIns" "$APP/Contents/"
  mkdir -p "$APP/Contents/Resources"
  cp -cRP "$STAGE/Resources/" "$APP/Contents/Resources/"
  install -m 755 "$cli" "$APP/Contents/Helpers/glitchbox"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  log "app: signing inside-out (identity: $SIGN_IDENTITY; log: build/logs/sign.log)"
  logged sign sign_app
  verify_app
}

verify_app() {
  verify_contents "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
  log "verify: codesign --verify --deep --strict passed"
}

build_dmg() {
  [ -d "$APP" ] || die "dmg: build/Glitchbox.app missing; run build.sh app"
  local r=$WORK/dmg out=$DIST/Glitchbox-$VERSION.dmg m
  rm -rf "$r"
  mkdir -p "$r" "$DIST"
  cp -cRP "$APP" "$r/"
  ln -s /Applications "$r/Applications"
  rm -f "$out"
  log "dmg: hdiutil create $out"
  hdiutil create -quiet -volname "Glitchbox $VERSION" -srcfolder "$r" -format UDZO -ov "$out"
  [ "$SIGN_IDENTITY" = - ] || codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out"
  rm -rf "$r"
  hdiutil verify -quiet "$out"
  m=$(mktemp -d /tmp/glitchbox-dmg.XXXXXX)
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$m" "$out"
  codesign --verify --deep --strict "$m/Glitchbox.app" && [ -L "$m/Applications" ]
  hdiutil detach -quiet "$m"
  rmdir "$m"
  log "dmg: $out ($(du -h "$out" | cut -f1)); mounted copy passes codesign --verify --deep --strict"
}

# --- Entry points ------------------------------------------------------------------
tools_build() {
  local s
  setup_toolbin
  fetch
  for s in $TOOL_STAGES; do run_stage "$s"; done
  assemble_stage
}

main() {
  local cmd=${1:-all}
  case $cmd in tools | app | dmg | all | verify) ;; *) die "usage: packaging/build.sh [tools|app|dmg|all|verify]" ;; esac
  # build/ ignores itself, so VCS snapshots never pick up gigabytes of output
  # even before the repository's .gitignore lists it.
  mkdir -p "$BUILD"
  [ -f "$BUILD/.gitignore" ] || printf '*\n' > "$BUILD/.gitignore"
  case $cmd in
    tools)
      tools_build
      verify_contents "$BUILD/stage"
      ;;
    app)
      tools_build
      build_app
      ;;
    dmg)
      [ -d "$APP" ] || { tools_build; build_app; }
      build_dmg
      ;;
    all)
      tools_build
      verify_contents "$BUILD/stage"
      build_app
      build_dmg
      ;;
    verify)
      mkdir -p "$BUILD/tmp" "$WORK"
      if [ -d "$APP" ]; then verify_app; else verify_contents "$BUILD/stage"; fi
      ;;
  esac
  log "$cmd: done"
}

# One line, parsed whole before it runs: editing this file mid-build cannot
# make bash execute shifted bytes.
main "$@"; exit $?
