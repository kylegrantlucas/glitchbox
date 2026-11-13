#!/bin/bash
# packaging/build.sh — no-Nix build of Glitchbox.app and its DMG.
#
#   packaging/build.sh [tools|app|dmg|all|verify|notarize|sources]   (default: all)
#   packaging/build.sh [ios-tools|ios-app|ios-install|ios-archive|stage NAME...]
#
#   tools   fetch + verify every input in packaging/sources.json, build the
#           toolchain, assemble it into build/stage/Contents, verify it.
#   app     tools (stamped stages are skipped) + xcodegen/xcodebuild + the
#           glitchbox CLI, merged with the staging into build/Glitchbox.app,
#           signed inside-out, verified.
#   dmg     build/dist/Glitchbox-<packaging/VERSION>.dmg from the app.
#   all     tools, app, dmg.
#   verify  re-run verification on build/Glitchbox.app (or the staging).
#   notarize  notarize and staple build/Glitchbox.app, rebuild the DMG around
#           it, notarize and staple that (needs a Developer ID identity and
#           the GLITCHBOX_NOTARY_* key).
#   sources build/dist/Glitchbox-<VERSION>-sources.tar: the release's complete
#           corresponding source (git archive HEAD, every `mirror` input, the
#           Rust crates as a CARGO_HOME). Needs a clean, committed checkout.
#
#   ios-tools    build the iOS toolchain stages (packaging/ios/*.sh) into
#                build/ios/xcframeworks and app/GlitchboxInProcess/Artifacts.
#   ios-app      ios-tools + build/ios/Toolchain + xcodegen (with app/ios.yml)
#                + a signed Release device build: build/ios/Glitchbox.app.
#   ios-install  install build/ios/Glitchbox.app on $GLITCHBOX_DEVICE.
#   ios-archive  ios-tools + build/ios/Toolchain + an App Store archive,
#                exported to build/ios/export/Glitchbox.ipa.
#   stage NAME…  run the named stages only (e.g. ios_ffmpeg).
#
# Build machine: Xcode 27, cargo/rustc >= 1.97 (burns-rs needs 1.97), cmake,
# curl, jq. Nothing else: pkg-config is GStreamer devel's own, XcodeGen is
# pinned in sources.json. Compilers run under `env -i` with PATH=/usr/bin first
# and a private bin dir holding only cargo, rustc, cmake, and pkg-config, so
# nix-darwin/Homebrew tools on the caller's PATH cannot leak into products.
#
# Environment:
#   GLITCHBOX_SIGN_IDENTITY  codesign identity (default "-", ad-hoc). A real
#                            identity also enables the hardened runtime.
#   GLITCHBOX_NOTARY_KEY_FILE, GLITCHBOX_NOTARY_KEY_ID, GLITCHBOX_NOTARY_ISSUER
#                            App Store Connect API key (.p8 path, key ID,
#                            issuer ID) for `notarize`.
#   GLITCHBOX_BUILD_NUMBER   iOS build number for `ios-archive` (default: the
#                            commit count).
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
PREFIX=$BUILD/prefix          # frei0r install prefix + finished binaries
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
# PNG/JPEG stills, and WAV/FLAC/AAC/MP3/Vorbis/Opus audio. No H.264 encoder
# ships: x264 is gone, so the tools write FFV1/PNG (reactive-vcr .mp4 output,
# ntsc-rs-cli -c h264, and bender --codec h264 are unavailable). Added
# untraced, for the same input families: interlace (ntsc-rs
# interlaced output), dav1d (AV1), mpegpsdemux/mpegtsdemux (.mpg/.ts), aiff,
# apetag, jpeg. Decoding goes through gst-libav's LGPL FFmpeg. applemedia
# (VideoToolbox) is left out: its vtdec fails on ProRes, and software decodes
# are the same on every Mac. verify_contents proves each plugin loads.
GST_PLUGINS="coreelements playback typefindfunctions
  videoconvertscale videorate imagefreeze interlace
  audioconvert audioresample audiomixer audiotestsrc volume
  libav dav1d matroska isomp4 avi mpegpsdemux mpegtsdemux ogg wavparse aiff flac
  audioparsers videoparsersbad id3demux apetag mpg123 opus vorbis
  png jpeg jpegformat multifile"

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

# Idempotent (no rm -rf), so concurrent `build.sh stage` runs share it safely.
setup_toolbin() {
  mkdir -p "$TOOLBIN" "$BUILD/home" "$BUILD/tmp" "$LOGS" "$STAMPS" "$PREFIX/bin"
  ln -sfn "$CARGO_BIN" "$TOOLBIN/cargo"
  ln -sfn "$RUSTC_BIN" "$TOOLBIN/rustc"
  ln -sfn "$CMAKE_BIN" "$TOOLBIN/cmake"
  ln -sfn "$GST_SDK/$GST_V/bin/pkg-config" "$TOOLBIN/pkg-config" # dangling until gst
}

# --- Pinned inputs -----------------------------------------------------------
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

lock_field() { # NAME FIELD -> value of the first lock entry with that name
  "$JQ" -er --arg n "$1" --arg f "$2" \
    'first(.sources[] | select(.name == $n)) | .[$f]' "$LOCK"
}
src() { printf '%s/%s\n' "$DL" "$(lock_field "$1" file)"; }

# `fetch` gets every build input; `fetch all` also the mirrorOnly ones (the
# source bundle's extra archives, never needed to build).
fetch() { # [all]
  mkdir -p "$DL"
  local file url sum got all=false n
  [ "${1:-}" != all ] || all=true
  local filter='.sources[] | select($all or (.mirrorOnly != true))'
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
  done < <("$JQ" -r --argjson all "$all" "$filter | [.file, .url, .sha256] | @tsv" "$LOCK")
  n=$("$JQ" --argjson all "$all" "[$filter] | length" "$LOCK")
  log "fetch: $n inputs verified"
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
    frei0r | sox | bash) echo gst ;; # gst provides pkg-config
    ffmpeg) echo "gst frei0r" ;;
    ntsc_rs | bender | burns) echo gst ;;
    licenses) echo gst ;; # GStreamer's share/licenses
  esac
}
stage_srcs() {
  case $1 in
    gst) echo "gstreamer-runtime gstreamer-devel" ;;
    gst_runtime) ;;
    ntsc_rs) echo ntsc-rs ;;
    bender) echo bender-rs ;;
    burns) echo burns-rs ;;
    bash) echo "bash bash-patch" ;;
    licenses) echo "ffmpeg frei0r sox bash ntsc-rs bender-rs burns-rs onnxruntime ffglitch ffglitch-src sdl2-src zlib-ng-src rtmidi-src zeromq-src ffglitch-scripts reactive-vcr" ;;
    ios_*) eval "printf '%s\n' \"\${${1}_srcs:-}\"" ;;
    *) echo "$1" ;;
  esac
}
stage_recipe() { # what else, besides build_<stage>, a stage's output depends on
  case $1 in
    gst) declare -f merge_pkg thin_arm64 ;;
    gst_runtime) declare -f gst_closure gst_copy_deps; echo "plugins: $GST_PLUGINS" ;;
    ntsc_rs | bender | burns) declare -f cargo_build ;;
    licenses)
      declare -f lic_copy crate_licenses
      cat "$PKG/about.toml" "$PKG/about.hbs" "$PKG/licenses/jq/COPYING"
      echo "cargo-about: $("$CARGO_ABOUT" --version 2>/dev/null || true)"
      ;;
    ios_licenses)
      ios_recipe "$1"
      declare -f lic_copy
      echo "cargo-about: $("$CARGO_ABOUT" --version 2>/dev/null || true)"
      ;;
    ios_*) ios_recipe "$1" ;;
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

# Static GPL build (frei0r is GPL): frei0r, Apple's VideoToolbox and
# AudioToolbox, system zlib/bzip2/iconv only (--disable-autodetect). No x264:
# H.264/HEVC encoding is VideoToolbox's. Every native filter, encoder, and
# muxer is compiled in (ffv1, png, pcm_s16le, h264_videotoolbox;
# matroska/mp4/avi; geq, lagfun, tblend, datascope, rgbashift, …).
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
    --enable-gpl --enable-frei0r \
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
# references. burns links no GStreamer; it shares the recipe. The registry
# cache lives in build/downloads (cached download).
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

# burns-rs needs Rust >= 1.97; burns-cli only (no GUI).
build_burns() {
  local s=$WORK/burns-rs
  unpack burns-rs "$s"
  cargo_build "$s" "$WORK/burns-target" -p burns-cli
  install -m 755 "$WORK/burns-target/release/burns" "$PREFIX/bin/"
  rm -rf "$WORK/burns-target"
}

# --- Licences ----------------------------------------------------------------
# Every bundled component's licence texts, the way ntsc-rs ships its own: the
# upstream files from each pinned input, GStreamer's share/licenses, and
# cargo-about credits for the Rust crates compiled into ntsc-rs-cli, bender,
# and burns (ntsc-rs-cli is a bin of the GPL-3.0 ntsc-rs-gui crate; its core
# is MIT/ISC/Apache). assemble_stage copies the tree to Contents/Resources/licenses and
# writes Credits.html, which the standard About panel shows.
CARGO_ABOUT=${CARGO_ABOUT:-$(command -v cargo-about || true)}
LIC=$PREFIX/share/glitchbox-licenses

lic_copy() { # NAME DIR FILE...: FILEs from the top of NAME's archive -> $LIC/DIR
  local name=$1 dir=$2 t=$WORK/lic-x f
  shift 2
  rm -rf "$t"
  mkdir -p "$t" "$LIC/$dir"
  local -a inc=()
  for f in "$@"; do inc+=(--include "*/$f"); done
  tar -xf "$(src "$name")" -C "$t" --strip-components 1 "${inc[@]}"
  for f in "$@"; do
    [ -f "$t/$f" ] || die "licenses: $name has no $f"
    cp "$t/$f" "$LIC/$dir/$f"
  done
  rm -rf "$t"
}

crate_licenses() { # NAME MANIFEST OUT: cargo-about over the crates of a Rust input
  local s=$WORK/lic-src
  unpack "$1" "$s"
  (cd "$s" && menv CARGO_HOME="$DL/cargo-home" "$CARGO_ABOUT" generate --locked \
    -c "$PKG/about.toml" -m "$s/$2" -o "$3" "$PKG/about.hbs")
  rm -rf "$s"
}

build_licenses() {
  [ -n "$CARGO_ABOUT" ] || die "licenses: cargo-about not found (cargo install cargo-about --locked --version 0.9.2)"
  rm -rf "$LIC"
  lic_copy ffmpeg ffmpeg COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md
  lic_copy frei0r frei0r COPYING
  # kaleid0sc0pe and vertigo are GPL-3.0-or-later; frei0r ships no GPLv3 text.
  lic_copy ffmpeg frei0r COPYING.GPLv3
  lic_copy sox sox COPYING LICENSE.GPL LICENSE.LGPL
  lic_copy bash bash COPYING
  lic_copy ntsc-rs ntsc-rs LICENSE-MIT LICENSE-APACHE-2.0 LICENSE-ISC
  lic_copy bender-rs bender-rs LICENSE-MIT LICENSE-APACHE
  lic_copy burns-rs burns-rs LICENSE-MIT LICENSE-APACHE
  lic_copy onnxruntime onnxruntime LICENSE ThirdPartyNotices.txt
  lic_copy ffglitch-scripts ffglitch-scripts LICENSE
  lic_copy reactive-vcr reactive-vcr LICENSE THIRD_PARTY_LICENSES.html GSTREAMER-NOTICE.txt
  # The prebuilt FFglitch is configured --enable-gpl; its own files are
  # LGPL-2.1-or-later or MIT. readme.txt lists what it links statically
  # (SDL2, zlib-ng, RtMidi, ZeroMQ), whose licences sit beside it.
  lic_copy ffglitch-src ffglitch COPYING.LGPLv2.1 COPYING.GPLv2 LICENSE.md
  mkdir -p "$LIC/ffglitch/quickjs" "$LIC/jq" "$WORK/lic-qjs"
  unzip -p "$(src ffglitch)" '*/readme.txt' > "$LIC/ffglitch/readme.txt"
  tar -xf "$(src ffglitch-src)" -C "$WORK/lic-qjs" --strip-components 1 '*/libavutil/quickjs/LICENSE'
  cp "$WORK/lic-qjs/libavutil/quickjs/LICENSE" "$LIC/ffglitch/quickjs/LICENSE"
  rm -rf "$WORK/lic-qjs"
  lic_copy sdl2-src ffglitch/sdl2 LICENSE.txt
  lic_copy zlib-ng-src ffglitch/zlib-ng LICENSE.md
  lic_copy rtmidi-src ffglitch/rtmidi LICENSE
  lic_copy zeromq-src ffglitch/zeromq COPYING COPYING.LESSER
  cp "$PKG/licenses/jq/COPYING" "$LIC/jq/COPYING"
  cp -R "$GST_SDK/$GST_V/share/licenses" "$LIC/gstreamer"
  # The x264 plugin is not in GST_PLUGINS, so its licence does not apply.
  rm -rf "$LIC/gstreamer/x264"
  crate_licenses ntsc-rs crates/gui/Cargo.toml "$LIC/ntsc-rs/crates.html"
  crate_licenses bender-rs crates/bender-cli/Cargo.toml "$LIC/bender-rs/crates.html"
  crate_licenses burns-rs crates/burns-cli/Cargo.toml "$LIC/burns-rs/crates.html"
}

# Credits.html rows: sources.json name|shown name|licence|role|source (empty:
# its pinned URL)|licenses/ dir. Versions come from sources.json.
CREDITS='ffmpeg|FFmpeg|GPL-2.0-or-later (built with --enable-gpl)|decoding, encoding, and the ffmpeg filters||ffmpeg
frei0r|frei0r|GPL-2.0-or-later; kaleid0sc0pe and vertigo GPL-3.0-or-later|the frei0r effect plugins||frei0r
gstreamer-runtime|GStreamer|LGPL-2.1-or-later; plugins under their own licences|media framework for ntsc-rs, bender, and reactive-vcr|https://gstreamer.freedesktop.org/src/|gstreamer
ntsc-rs|ntsc-rs|GPL-3.0 (ntsc-rs-cli); core MIT, ISC, or Apache-2.0|NTSC and VHS emulation||ntsc-rs
bender-rs|bender-rs|MIT or Apache-2.0|circuit-bent video hardware||bender-rs
burns-rs|burns|MIT or Apache-2.0|still-image camera motion (Still Motion)||burns-rs
onnxruntime|ONNX Runtime|MIT|on-device depth estimation for burns|https://github.com/microsoft/onnxruntime|onnxruntime
reactive-vcr|reactive-vcr|MIT|audio-reactive VCR artifacts|https://github.com/kylegrantlucas/reactive-vcr|reactive-vcr
ffglitch|FFglitch|GPL-2.0-or-later; includes QuickJS (MIT); statically includes SDL2 (Zlib), zlib-ng (Zlib), RtMidi (MIT), ZeroMQ 4.3.1 (LGPL-3.0-or-later with static-linking exception)|bitstream editing: ffgac, ffedit, fflive, qjs|https://ffglitch.org/pub/src/ffglitch-{v}.tar.xz|ffglitch
ffglitch-scripts|ffglitch-scripts|Unlicense|the DD-GlitchAssist scripts behind MV Script||ffglitch-scripts
sox|SoX|GPL-2.0-or-later|audio in the pipelines||sox
bash|GNU Bash|GPL-3.0-or-later|runs the pipeline and plugin scripts||bash
jq|jq|MIT|JSON in the pipelines|https://github.com/jqlang/jq|jq'

# Where the complete corresponding source of a build is: the release's
# Glitchbox-<VERSION>-sources.tar (packaging/build.sh sources).
RELEASE_URL=https://github.com/kylegrantlucas/glitchbox/releases/tag/v$VERSION
SOURCE_OFFER="The complete corresponding source of this build, including every bundled tool, is attached to its release: <a href=\"$RELEASE_URL\">${RELEASE_URL#https://}</a>."

# Shared by both apps: TABLE (default $CREDITS), WHERE, the sentence saying
# where the licence texts are, and OFFER, where the source is.
write_credits() { # OUT [TABLE [WHERE [OFFER]]]
  local name shown lic role url dir ver table=${2:-$CREDITS}
  local where=${3:-'Their full licence texts are in Help &gt; Third-Party Licenses (Glitchbox.app/Contents/Resources/licenses).'}
  local offer=${4:-$SOURCE_OFFER}
  {
    printf '%s\n' '<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font:11px -apple-system,sans-serif}td{vertical-align:top;padding:2px 6px 2px 0}</style></head><body>'
    printf '<p>Glitchbox is MIT licensed: <a href="https://github.com/kylegrantlucas/glitchbox">github.com/kylegrantlucas/glitchbox</a>. It runs these tools, each under its own licence. %s %s</p>\n<table>\n' "$where" "$offer"
    while IFS='|' read -r name shown lic role url dir; do
      ver=$(lock_field "$name" version)
      [ -n "$url" ] || url=$(lock_field "$name" url)
      url=${url//\{v\}/$ver}
      printf '<tr><td><a href="%s">%s</a> %s</td><td>%s</td><td>%s</td></tr>\n' "$url" "$shown" "$ver" "$lic" "$role"
    done <<< "$table"
    printf '</table></body></html>\n'
  } > "$1"
}

TOOL_STAGES="gst gst_runtime frei0r ffmpeg sox bash ntsc_rs bender burns licenses"

# --- iOS toolchain -------------------------------------------------------------
# The iOS app cannot spawn processes, so its tools are libraries. Each
# packaging/ios/<name>.sh defines the stage build_ios_<name>, which writes
# build/ios/xcframeworks/<Name>.xcframework with ios-arm64, ios-arm64-simulator,
# and macos-arm64 slices (the last only for host tests of app/GlitchboxInProcess).
# A recipe may set ios_<name>_srcs (the sources.json names it unpacks) and
# ios_<name>_inputs (repo-relative files or directories, e.g. patches or a
# crate, whose contents key the stage); the recipe file itself keys it too.
IOS=$BUILD/ios
IOS_XCF=$IOS/xcframeworks
IOS_STAGES="ios_ffmpeg ios_ffglitch ios_fx ios_burns ios_licenses"
for f in "$PKG"/ios/*.sh; do [ -e "$f" ] && . "$f"; done

ios_recipe() { # STAGE: the recipe file and its input files, for stage_key
  local inputs p f
  cat "$PKG/ios/${1#ios_}.sh"
  eval "inputs=\${${1}_inputs:-}"
  for p in $inputs; do
    find "$ROOT/$p" -type f ! -path '*/target/*' ! -name .DS_Store | LC_ALL=C sort |
      while IFS= read -r f; do printf '%s\n' "${f#$ROOT/}"; cat "$f"; done
  done
}

ios_frameworks() { # STAGE: the xcframeworks it writes
  case $1 in
    ios_ffmpeg) echo GlitchFFmpeg ;;
    ios_ffglitch) echo FFglitch ;;
    ios_fx) echo GlitchboxFX ;;
    ios_burns) echo "GlitchboxBurns onnxruntime" ;;
  esac
}

# app/GlitchboxInProcess's binary targets (gitignored; SwiftPM refuses binary
# targets outside the package directory): STAGEs' xcframeworks, each replaced
# through its own temporary copy so a `swift build` never sees half of one.
IOS_ARTIFACTS=$ROOT/app/GlitchboxInProcess/Artifacts
ios_sync_artifacts() { # STAGE...
  local s n t
  mkdir -p "$IOS_ARTIFACTS"
  for s in "$@"; do
    for n in $(ios_frameworks "$s"); do
      [ -d "$IOS_XCF/$n.xcframework" ] || die "ios: $s left no $n.xcframework"
      t=$(mktemp -d "$IOS_ARTIFACTS/.sync.XXXXXX")
      cp -cR "$IOS_XCF/$n.xcframework" "$t/"
      rm -rf "${IOS_ARTIFACTS:?}/$n.xcframework"
      mv "$t/$n.xcframework" "$IOS_ARTIFACTS/"
      rmdir "$t"
    done
  done
}

ios_tools_build() {
  local s
  setup_toolbin
  fetch
  for s in $IOS_STAGES; do run_stage "$s"; done
  ios_sync_artifacts $IOS_STAGES
}

# Credits.html rows for the iOS app (same format as CREDITS).
CREDITS_IOS='ffmpeg|FFmpeg|LGPL-2.1-or-later; modified for in-process use (see its MODIFICATIONS.txt)|decoding, encoding, and the ffmpeg filters, linked in-process||ffmpeg
ffglitch-src|FFglitch|LGPL-2.1-or-later, its own additions LGPL-2.1-or-later or MIT; includes QuickJS (MIT); modified for in-process use|bitstream editing: ffgac and ffedit, built from source and linked in-process|https://ffglitch.org/pub/src/ffglitch-{v}.tar.xz|ffglitch
ffglitch-scripts|ffglitch-scripts|Unlicense|the DD-GlitchAssist scripts behind MV Script||ffglitch-scripts
ntsc-rs|ntsc-rs|core MIT, ISC, or Apache-2.0|NTSC and VHS emulation (its core library)||ntsc-rs
bender-rs|bender-rs|MIT or Apache-2.0|circuit-bent video hardware||bender-rs
reactive-vcr|reactive-vcr|MIT|audio-reactive VCR artifacts|https://github.com/kylegrantlucas/reactive-vcr|reactive-vcr
burns-rs|burns|MIT or Apache-2.0|still-image camera motion (Still Motion)||burns-rs
onnxruntime-c-pod|ONNX Runtime|MIT|on-device depth estimation for Still Motion|https://github.com/microsoft/onnxruntime|onnxruntime'

# The iOS app's written offer, on top of the release link (LGPL-2.1 §6).
SOURCE_OFFER_IOS="$SOURCE_OFFER For at least three years after this build, kyle@klr.dev will also send the complete corresponding source of FFmpeg and FFglitch as built into this app, including Glitchbox's modifications, on request, for no more than the cost of distribution."

# The iOS toolchain's identity: the pins, this script, every iOS stage's stamp
# (which already hash each recipe, its patches, and its crates), and
# GlitchboxInProcess's sources, which implement the native steps whose
# manifests carry only an id.
ios_digest() {
  local s f
  {
    cat "$LOCK" "$PKG/build.sh"
    for s in $IOS_STAGES; do cat "$STAMPS/$s"; done
    cat "$ROOT/app/GlitchboxInProcess/Package.swift"
    find "$ROOT/app/GlitchboxInProcess/Sources" -type f ! -name .DS_Store | LC_ALL=C sort |
      while IFS= read -r f; do printf '%s\n' "${f#$ROOT/}"; cat "$f"; done
  } | shasum -a 256 | cut -d' ' -f1
}

# Same schema as the macOS toolchain.json; `@contents` is the app's Toolchain/
# folder and `@cache` the app's cache. Nothing is on a PATH: GlitchboxInProcess
# runs ffmpeg, ffprobe, ffgac, and ffedit in-process and implements the script
# plugins natively. BURNS_CACHE holds Still Motion's depth model (downloaded on
# first use) and depth maps.
write_ios_toolchain_json() { # OUT
  "$JQ" -n --arg digest "$(ios_digest)" --slurpfile lock "$LOCK" '
    def v($n): first($lock[0].sources[] | select(.name == $n)) | .version;
    {
      schema: 1,
      digest: $digest,
      tools: {
        ffmpeg: v("ffmpeg"), ffglitch: v("ffglitch-src"), "ntsc-rs": v("ntsc-rs"),
        bender: v("bender-rs"), "reactive-vcr": v("reactive-vcr"), burns: v("burns-rs"),
        onnxruntime: v("onnxruntime-c-pod")
      },
      path: [],
      environment: {
        FFGLITCH_SCRIPTS: "@contents/ffglitch-scripts",
        BENDER_PRESETS: "@contents/bender-presets",
        BURNS_CACHE: "@cache/burns"
      }
    }' > "$1"
}

# build/ios/Toolchain: the folder the iOS app bundles as Glitchbox.app/Toolchain.
assemble_ios() {
  local t=$IOS/Toolchain x=$WORK/assemble-ios n
  log "ios: assembling build/ios/Toolchain"
  rm -rf "$t" "$x"
  mkdir -p "$t/library" "$t/ffglitch-scripts" "$x"
  for n in plugins presets scripts pipelines; do
    cp -R "$ROOT/$n" "$t/library/$n"
  done
  find "$t/library" -name .DS_Store -delete
  tar -xf "$(src ffglitch-scripts)" -C "$t/ffglitch-scripts" --strip-components 1
  tar -xf "$(src bender-rs)" -C "$x" --strip-components 1
  cp -R "$x/presets" "$t/bender-presets"
  cp -R "$IOS/licenses" "$t/licenses"
  write_credits "$t/Credits.html" "$CREDITS_IOS" 'Their full licence texts are under Licenses in the app.' "$SOURCE_OFFER_IOS"
  write_ios_toolchain_json "$t/toolchain.json"
  rm -rf "$x"
}

IOS_APP=$IOS/Glitchbox.app
IOS_SCHEME="Glitchbox iOS"

# xcodegen with the iOS spec included (app/ios.yml, enabled by GLITCHBOX_IOS),
# then a signed Release build for devices with the team's development
# certificate. -allowProvisioningUpdates lets xcodebuild use the Apple Account
# signed into Xcode to create or refresh the provisioning profile, and
# -allowProvisioningDeviceRegistration registers the destination device with the
# team. The profile lists only registered devices, so with GLITCHBOX_DEVICE set
# the build targets that device (same arm64 product) to get it into the profile.
compile_ios_app() {
  local xg=$WORK/xcodegen dest=generic/platform=iOS
  [ -z "${GLITCHBOX_DEVICE:-}" ] || dest="id=$GLITCHBOX_DEVICE"
  rm -rf "$xg"
  mkdir -p "$xg"
  unzip -q "$(src xcodegen)" -d "$xg"
  (cd "$ROOT/$APP_DIR" && menv_swift GLITCHBOX_IOS=YES "$xg/xcodegen/bin/xcodegen" generate)
  menv_swift xcodebuild -project "$ROOT/$APP_DIR/$APP_PROJECT" -scheme "$IOS_SCHEME" \
    -configuration Release -destination "$dest" -derivedDataPath "$WORK/xcode-ios" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    MARKETING_VERSION="$VERSION" build
  [ -d "$WORK/xcode-ios/Build/Products/Release-iphoneos/$APP_PRODUCT" ]
}

build_ios_app() {
  ios_tools_build
  assemble_ios
  log "ios: xcodegen, xcodebuild $IOS_SCHEME Release (log: build/logs/ios-app.log)"
  logged ios-app compile_ios_app
  rm -rf "$IOS_APP"
  cp -cRP "$WORK/xcode-ios/Build/Products/Release-iphoneos/$APP_PRODUCT" "$IOS_APP"
  codesign --verify --deep --strict "$IOS_APP"
  [ -f "$IOS_APP/Toolchain/toolchain.json" ] || die "ios: the app has no Toolchain/toolchain.json"
  log "ios: build/ios/Glitchbox.app ($(du -sh "$IOS_APP" | cut -f1)), signed: $(codesign -dvv "$IOS_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
}

# Installs build/ios/Glitchbox.app on GLITCHBOX_DEVICE (a UDID from `xcrun
# devicectl list devices`; build with the same GLITCHBOX_DEVICE so it's registered).
install_ios_app() {
  [ -d "$IOS_APP" ] || die "ios-install: build/ios/Glitchbox.app missing; run build.sh ios-app"
  [ -n "${GLITCHBOX_DEVICE:-}" ] || die "ios-install: set GLITCHBOX_DEVICE (see xcrun devicectl list devices)"
  xcrun devicectl device install app --device "$GLITCHBOX_DEVICE" "$IOS_APP"
}

# App Store build: a Release archive of the iOS scheme, exported for App Store
# Connect with packaging/ios/ExportOptions.plist (automatic signing for the
# team). The build number is GLITCHBOX_BUILD_NUMBER, else the commit count.
archive_ios_app() {
  local xg=$WORK/xcodegen build_number
  build_number=${GLITCHBOX_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}
  rm -rf "$xg" "$IOS/Glitchbox.xcarchive" "$IOS/export"
  mkdir -p "$xg"
  unzip -q "$(src xcodegen)" -d "$xg"
  (cd "$ROOT/$APP_DIR" && menv_swift GLITCHBOX_IOS=YES "$xg/xcodegen/bin/xcodegen" generate)
  menv_swift xcodebuild archive -project "$ROOT/$APP_DIR/$APP_PROJECT" -scheme "$IOS_SCHEME" \
    -configuration Release -destination generic/platform=iOS -derivedDataPath "$WORK/xcode-ios-archive" \
    -archivePath "$IOS/Glitchbox.xcarchive" -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$build_number"
  menv_swift xcodebuild -exportArchive -archivePath "$IOS/Glitchbox.xcarchive" \
    -exportOptionsPlist "$PKG/ios/ExportOptions.plist" -exportPath "$IOS/export" -allowProvisioningUpdates
}

build_ios_archive() {
  ios_tools_build
  assemble_ios
  log "ios-archive: xcodebuild archive + export (log: build/logs/ios-archive.log)"
  logged ios-archive archive_ios_app
  [ -f "$IOS/export/Glitchbox.ipa" ] || die "ios-archive: no build/ios/export/Glitchbox.ipa"
  log "ios-archive: build/ios/export/Glitchbox.ipa ($(du -h "$IOS/export/Glitchbox.ipa" | cut -f1))"
}

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
#   ORT_DYLIB_PATH    required for burns --auto-depth: burns otherwise looks
#                     only in Helpers/runtime/lib and Contents/lib.
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
        burns: v("burns-rs"), onnxruntime: v("onnxruntime"),
        gstreamer: v("gstreamer-runtime"), frei0r: v("frei0r"),
        jq: v("jq"), sox: v("sox"), bash: $bash
      },
      path: ["@contents/Helpers"],
      environment: {
        FREI0R_PATH: "@contents/PlugIns/frei0r-1",
        FFGLITCH_SCRIPTS: "@contents/Resources/ffglitch-scripts",
        BENDER_PRESETS: "@contents/Resources/bender-presets",
        GST_PLUGIN_SYSTEM_PATH: "@contents/Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
        GST_REGISTRY: $reg,
        ORT_DYLIB_PATH: "@contents/Frameworks/libonnxruntime.dylib"
      }
    }' > "$1"
}

assemble_stage() {
  local c=$STAGE x=$WORK/assemble f n
  log "stage: assembling build/stage/Contents"
  rm -rf "$BUILD/stage" "$x"
  mkdir -p "$c/Helpers" "$c/Frameworks" "$c/PlugIns/frei0r-1" "$c/Resources" "$x"

  for n in ffmpeg ffprobe ntsc-rs-cli bender burns sox bash; do
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
  # ONNX Runtime for burns --auto-depth; dlopen'd via ORT_DYLIB_PATH, never linked.
  mkdir -p "$x/ort"
  tar -xf "$(src onnxruntime)" -C "$x/ort" --strip-components 1
  install -m 755 "$x/ort/lib/libonnxruntime.dylib" "$c/Frameworks/libonnxruntime.dylib"

  cp -cRP "$GST_RUNTIME" "$c/Frameworks/GStreamer.framework"
  # The libraries ntsc-rs-cli, bender, and reactive-vcr link directly (burns links none).
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
  cp -R "$LIC" "$c/Resources/licenses"
  mkdir -p "$c/Resources/licenses/glitchbox"
  cp "$ROOT/LICENSE" "$c/Resources/licenses/glitchbox/LICENSE"
  write_credits "$c/Resources/Credits.html"
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
  # reactive-vcr while it mixes in the MP4's own audio. H.264 comes from
  # VideoToolbox; without it (some CI runners) the MP4 is MPEG-4 Part 2.
  if [ ! -f "$d/in.mp4" ]; then
    tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -f lavfi -i sine=frequency=330:duration=1 \
      -c:v h264_videotoolbox -b:v 2M -pix_fmt yuv420p -c:a aac_at "$d/in.mp4" ||
      {
        tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
          -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -f lavfi -i sine=frequency=330:duration=1 \
          -c:v mpeg4 -q:v 3 -c:a aac "$d/in.mp4"
        log "verify: VideoToolbox unavailable; in.mp4 is MPEG-4 Part 2"
      }
  fi
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
  fr=$(tenv "$c" "$k" ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$d/ntsc-png.mkv")
  case $fr in ffv1,[1-9]*) ;; *) die "verify: ntsc-png output is '$fr', want ffv1 frames" ;; esac
  log "verify: ntsc-png render from $c: $fr frames"
}

smoke_burns() { # CONTENTS CACHE DIR: burns 2D render, and a depth render through the shipped ONNX Runtime
  local c=$1 k=$2 d=$3 o fr model h=$3/burns-home
  model=$(src depth-anything-v2-small)
  [ -f "$model" ] || die "verify: $model missing (run packaging/build.sh tools to fetch it)"
  [ -f "$d/in.png" ] || tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240 -frames:v 1 "$d/in.png"
  # A pre-seeded model cache: burns verifies it by hash and never touches the network.
  mkdir -p "$h/Library/Caches/burns/models"
  cp -c "$model" "$h/Library/Caches/burns/models/$(lock_field depth-anything-v2-small sha256).onnx"
  tenv "$c" "$k" env HOME="$h" burns render -i "$d/in.png" -o "$d/burns.mkv" --preset kenburns \
    --width 320 --height 240 --fps 30 --duration 1 --codec ffv1 --overwrite \
    > "$d/burns.log" 2>&1 || { tail -20 "$d/burns.log"; die "verify: burns render failed"; }
  tenv "$c" "$k" env HOME="$h" burns render -i "$d/in.png" -o "$d/burns-depth.mkv" --preset dolly-out \
    --auto-depth --width 320 --height 240 --fps 30 --duration 1 --codec ffv1 --overwrite \
    > "$d/burns-depth.log" 2>&1 || { tail -20 "$d/burns-depth.log"; die "verify: burns --auto-depth render failed"; }
  ! grep -q 'downloading model' "$d/burns-depth.log" || die "verify: burns downloaded the depth model"
  for o in burns burns-depth; do
    fr=$(tenv "$c" "$k" ffprobe -v error -count_frames -select_streams v:0 \
      -show_entries stream=codec_name,nb_read_frames -of csv=p=0 "$d/$o.mkv")
    case $fr in ffv1,30) ;; *) die "verify: $o output is '$fr', want ffv1,30 frames" ;; esac
    log "verify: $o render from $c: $fr frames"
  done
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
    tenv "$c" "$k" ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 \
      -vf "frei0r=filter_name=$f,format=yuv420p" -c:v ffv1 "$d/$f.mkv"
    log "verify: ffmpeg frei0r $f -> ffv1/mkv: $(tenv "$c" "$k" ffprobe -v error \
      -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$d/$f.mkv") frames"
  done
  for f in ffgac ffedit; do first_line tenv "$c" "$k" "$f" -version; done
  tenv "$c" "$k" reactive-vcr --version
  tenv "$c" "$k" jq --version
  tenv "$c" "$k" sox --version
  out=$(first_line tenv "$c" "$k" bash --version)
  echo "$out"
  case $out in *"version 5."*) ;; *) die "verify: bash is not 5.x" ;; esac
  smoke_gst "$c" "$k" "$d"
  smoke_burns "$c" "$k" "$d"
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
  smoke_burns "$c" "$d/cache" "$d"
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

check_licenses() { # CONTENTS: every credited component ships its licence texts
  local c=$1 name shown lic role url dir
  [ -s "$c/Resources/Credits.html" ] || die "verify: no Resources/Credits.html"
  [ -s "$c/Resources/licenses/glitchbox/LICENSE" ] || die "verify: no Glitchbox LICENSE"
  while IFS='|' read -r name shown lic role url dir; do
    [ -n "$(ls -A "$c/Resources/licenses/$dir" 2>/dev/null)" ] || die "verify: no licence texts for $shown"
  done <<< "$CREDITS"
  for dir in ntsc-rs bender-rs burns-rs; do
    grep -q '<pre>' "$c/Resources/licenses/$dir/crates.html" || die "verify: empty crate licences for $dir"
  done
  log "verify: licence texts for $(printf '%s\n' "$CREDITS" | wc -l | tr -d ' ') components plus Rust crates"
}

verify_contents() { # BUNDLE-DIR
  local c=$1/Contents
  log "verify: $c"
  check_licenses "$c"
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
  sign "$c/Frameworks/libonnxruntime.dylib"
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

# --- Notarization --------------------------------------------------------------
# notarytool with an App Store Connect API key (GLITCHBOX_NOTARY_KEY_FILE, a .p8;
# GLITCHBOX_NOTARY_KEY_ID; GLITCHBOX_NOTARY_ISSUER). The app is submitted and
# stapled first, then the DMG is rebuilt around the stapled app, signed,
# submitted, and stapled.
notary_submit() { # FILE NAME: submit and wait; dies unless Accepted
  local f=$1 n=$2 status id
  local -a key=(--key "$GLITCHBOX_NOTARY_KEY_FILE" --key-id "$GLITCHBOX_NOTARY_KEY_ID"
    --issuer "$GLITCHBOX_NOTARY_ISSUER")
  log "notarize: submitting $(basename "$f") (log: build/logs/notary-$n.json)"
  xcrun notarytool submit "$f" "${key[@]}" --wait --timeout 2h --output-format json \
    > "$LOGS/notary-$n.json" || true
  status=$("$JQ" -r '.status // empty' "$LOGS/notary-$n.json" 2>/dev/null || true)
  if [ "$status" != Accepted ]; then
    id=$("$JQ" -r '.id // empty' "$LOGS/notary-$n.json" 2>/dev/null || true)
    [ -z "$id" ] || xcrun notarytool log "$id" "${key[@]}" > "$LOGS/notary-$n-log.json" || true
    die "notarize: $(basename "$f") was not accepted (status '${status:-none}'; build/logs/notary-$n.json, notary-$n-log.json)"
  fi
}

build_notarize() {
  local v zip=$WORK/Glitchbox-notarize.zip dmg=$DIST/Glitchbox-$VERSION.dmg
  [ "$SIGN_IDENTITY" != - ] || die "notarize: set GLITCHBOX_SIGN_IDENTITY to a Developer ID Application identity"
  for v in GLITCHBOX_NOTARY_KEY_FILE GLITCHBOX_NOTARY_KEY_ID GLITCHBOX_NOTARY_ISSUER; do
    [ -n "${!v:-}" ] || die "notarize: $v is not set"
  done
  [ -d "$APP" ] || die "notarize: build/Glitchbox.app missing; run build.sh app"
  mkdir -p "$LOGS" "$WORK"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  notary_submit "$zip" app
  rm -f "$zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  build_dmg
  notary_submit "$dmg" dmg
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl -a -vv -t exec "$APP" 2>&1 | grep -q 'source=Notarized Developer ID' ||
    die "notarize: Gatekeeper does not accept build/Glitchbox.app as notarized"
  spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 |
    grep -q 'source=Notarized Developer ID' || die "notarize: Gatekeeper does not accept $dmg as notarized"
  log "notarize: app and DMG notarized and stapled"
}

# --- Source bundle -------------------------------------------------------------
# build/dist/Glitchbox-<VERSION>-sources.tar (+ .sha256): the complete
# corresponding source of a release. The repository at HEAD, every `mirror`
# input from sources.json under its pinned file name, and cargo-home.tar.gz: a
# fresh CARGO_HOME holding every crate the lockfiles of ntsc-rs (ntsc-rs-cli is
# GPL-3.0) and the two iOS libraries name (registry index and .crate files, git
# dependencies' bare repos). Not `cargo vendor`: glitchbox-fx pulls ntsc-rs
# 0.1.2 from two git sources, which one vendor directory cannot hold. Unpacked,
# third-party/ goes into build/downloads (cargo-home.tar.gz extracted there
# becomes the build's CARGO_HOME) and the usual build runs.
cargo_sources() { # DIR...: $out/third-party/cargo-home.tar.gz for the DIRs' Cargo.lock files
  local h=$t/cargo-home d
  rm -rf "$h"
  mkdir -p "$h"
  for d in "$@"; do
    (cd "$d" && menv CARGO_HOME="$h" CARGO_TERM_COLOR=never cargo fetch --locked)
  done
  tar -czf "$out/third-party/cargo-home.tar.gz" -C "$t" \
    cargo-home/registry/index cargo-home/registry/cache cargo-home/git/db
  rm -rf "$h"
}

build_sources() {
  local out=$DIST/Glitchbox-$VERSION-sources t=$WORK/sources file
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "sources: commit first (the source bundle is git archive HEAD)"
  setup_toolbin
  fetch all
  rm -rf "$out" "$t" "$out.tar" "$out.tar.sha256"
  mkdir -p "$out/third-party" "$t"
  log "sources: git archive HEAD ($(git -C "$ROOT" rev-parse --short HEAD))"
  git -C "$ROOT" archive --format=tar.gz --prefix="glitchbox-$VERSION/" -o "$out/glitchbox-$VERSION.tar.gz" HEAD
  while IFS= read -r file; do
    cp -c "$DL/$file" "$out/third-party/$file"
  done < <("$JQ" -r '.sources[] | select(.mirror == true) | .file' "$LOCK")
  log "sources: cargo fetch (ntsc-rs, glitchbox-fx, glitchbox-burns)"
  unpack ntsc-rs "$t/ntsc-rs"
  cargo_sources "$t/ntsc-rs" "$ROOT/app/rust/glitchbox-fx" "$ROOT/app/rust/glitchbox-burns"
  {
    printf '# Glitchbox %s: complete corresponding source\n\n' "$VERSION"
    printf 'Unpack glitchbox-%s.tar.gz, copy third-party/* into its build/downloads/ and extract cargo-home.tar.gz there (it becomes build/downloads/cargo-home, the build'"'"'s CARGO_HOME), then run packaging/build.sh all (macOS) or packaging/build.sh ios-app (iOS); fetch verifies every file by sha256. cargo-home.tar.gz holds every Rust crate of ntsc-rs-cli (GPL-3.0) and of the iOS libraries.\n\n' "$VERSION"
    printf '| File | Name | Version | Upstream | sha256 |\n|---|---|---|---|---|\n'
    "$JQ" -r '.sources[] | select(.mirror == true)
      | "| third-party/\(.file) | \(.name) | \(.version) | \(.url) | \(.sha256) |"' "$LOCK"
    printf '| third-party/cargo-home.tar.gz | Rust crates | | crates.io / git (cargo fetch --locked) | %s |\n' \
      "$(sha256 "$out/third-party/cargo-home.tar.gz")"
  } > "$out/SOURCES.md"
  tar -cf "$out.tar" -C "$DIST" "$(basename "$out")"
  (cd "$DIST" && shasum -a 256 "$(basename "$out").tar" > "$(basename "$out").tar.sha256")
  rm -rf "$out" "$t"
  log "sources: $out.tar ($(du -h "$out.tar" | cut -f1))"
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
  local cmd=${1:-all} s
  case $cmd in
    tools | app | dmg | all | verify | notarize | sources | ios-tools | ios-app | ios-install | ios-archive) ;;
    stage) [ $# -gt 1 ] || die "usage: packaging/build.sh stage NAME..." ;;
    *) die "usage: packaging/build.sh [tools|app|dmg|all|verify|notarize|sources|ios-tools|ios-app|ios-install|ios-archive|stage NAME...]" ;;
  esac
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
    notarize) build_notarize ;;
    sources) build_sources ;;
    ios-tools) ios_tools_build ;;
    ios-app) build_ios_app ;;
    ios-install) install_ios_app ;;
    ios-archive) build_ios_archive ;;
    stage)
      shift
      setup_toolbin
      fetch
      for s in "$@"; do run_stage "$s"; done
      ios_sync_artifacts "$@"
      ;;
  esac
  log "$cmd: done"
}

# One line, parsed whole before it runs: editing this file mid-build cannot
# make bash execute shifted bytes.
main "$@"; exit $?
