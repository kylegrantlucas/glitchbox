# packaging/ios/ffmpeg.sh — stage ios_ffmpeg: GlitchFFmpeg.xcframework.
# Sourced by packaging/build.sh (runs under /bin/bash 3.2).
#
# One static library per slice (ios-arm64, ios-arm64-simulator, macos-arm64)
# holding FFmpeg 8.1.2's libraries, LGPL-2.1-or-later only (no --enable-gpl:
# no x264, no frei0r, no GPL filters; VideoToolbox, AudioToolbox, system
# zlib/bzip2/iconv), and the ffmpeg and ffprobe tools as functions
# (gb_ffmpeg_run / gb_ffprobe_run, ffmpeg/gb_ffmpeg.h). configure's config.h
# is checked to be the LGPL configuration, so a GPL component cannot slip in.
# The App Store build depends on that: the GPL's terms conflict with Apple's.
#
#  - fftools: ffmpeg/patches/ffmpeg-8.1.2-inprocess.patch renames the mains,
#    drops signal handlers, terminal and stdin handling, setvbuf, setrlimit,
#    and every exit(), and polls the host's cancel atom where a SIGTERM would
#    land. ffmpeg/gb_fftools_prefix.h (force-included) sends the tools'
#    stdout/stderr to the run's log. Each tool (with its own cmdutils,
#    opt_common, and text formatters) is linked into one relocatable object
#    exporting only its main, with __DATA,__data/__bss/__common renamed to
#    __DATA,__gbft_data/__gbft_bss; gb_ffmpeg.c restores those sections before
#    every run, which resets every fftools global.
#  - ffmpeg/gb_thread_tag.h is force-included into every C file of the
#    libav* libraries and the fftools (appended to their config.mak CFLAGS
#    after configure, so configure's own test programs are unchanged; they
#    link ffmpeg/gb_thread_tag.c's object through --extra-libs): threads
#    inherit their creator's run tag, which gb_ffmpeg.c uses to send each
#    av_log line to the run that logged it (see there).
#  - libavformat/file.c (same patch) marks the descriptors it opens or dups
#    F_SETNOSIGPIPE: a closed pipe reader must give EPIPE, not kill the host.
#
# Output: build/ios/xcframeworks/GlitchFFmpeg.xcframework; its Headers hold the
# public libav*/libsw* headers and GlitchFFmpeg/{module.modulemap,
# GlitchFFmpeg.h, gb_ffmpeg.h} (module GlitchFFmpeg, found by clang's
# <search path>/<Module>/module.modulemap lookup; the subdirectory keeps the
# module map from colliding with other static xcframeworks' Headers).
# Host tests: packaging/ios/ffmpeg/test (not part of the stage).

ios_ffmpeg_srcs="ffmpeg"
ios_ffmpeg_inputs="packaging/ios/ffmpeg/patches packaging/ios/ffmpeg/gb_ffmpeg.c packaging/ios/ffmpeg/gb_ffmpeg.h packaging/ios/ffmpeg/gb_fftools_prefix.h packaging/ios/ffmpeg/gb_thread_tag.h packaging/ios/ffmpeg/gb_thread_tag.c packaging/ios/ffmpeg/GlitchFFmpeg.h packaging/ios/ffmpeg/module.modulemap"
ios_ffmpeg_slices="ios-arm64 ios-arm64-simulator macos-arm64"
ios_ffmpeg_libs="libavdevice libavfilter libavformat libavcodec libswresample libswscale libavutil"

# The compilers take the OS and version from -target; menv's
# MACOSX_DEPLOYMENT_TARGET would only contradict it on the iOS slices.
ios_ffmpeg_env() { menv /usr/bin/env -u MACOSX_DEPLOYMENT_TARGET "$@"; }

ios_ffmpeg_sdk() { # SLICE -> xcrun SDK name
  case $1 in
    ios-arm64) echo iphoneos ;;
    ios-arm64-simulator) echo iphonesimulator ;;
    macos-arm64) echo macosx ;;
  esac
}
ios_ffmpeg_target() { # SLICE -> clang target triple
  case $1 in
    ios-arm64) echo "arm64-apple-ios$DEPLOYMENT_TARGET" ;;
    ios-arm64-simulator) echo "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" ;;
    macos-arm64) echo "arm64-apple-macos$DEPLOYMENT_TARGET" ;;
  esac
}

# Links the fftools objects of TOOL into one relocatable object exporting only
# gb_fftool_<tool>_main, its writable data renamed into the reset sections.
ios_ffmpeg_fftool() { # FFMPEG-SRC TOOL OUT CFLAGS
  local s=$1 tool=$2 out=$3 objs sects
  # make 3.81 has no --eval: a second makefile adds the printing rule.
  printf 'gb-print-%%:\n\t@echo $($*)\n' > "$s/gb-print.mk"
  objs=$(cd "$s" && make -f Makefile -f gb-print.mk "gb-print-OBJS-$tool")
  [ -n "$objs" ] || die "no OBJS-$tool"
  (cd "$s" && ios_ffmpeg_env make -j"$JOBS" ECFLAGS="-include $PKG/ios/ffmpeg/gb_fftools_prefix.h" $objs)
  (cd "$s" && ios_ffmpeg_env /usr/bin/clang $4 -r -nostdlib \
    -Wl,-exported_symbol,"_gb_fftool_${tool}_main" \
    -Wl,-rename_section,__DATA,__data,__DATA,__gbft_data \
    -Wl,-rename_section,__DATA,__bss,__DATA,__gbft_bss \
    -Wl,-rename_section,__DATA,__common,__DATA,__gbft_bss \
    -o "$out" $objs)
  # Every writable byte must be in a reset section (__DATA,__const is
  # read-only once fixed up); thread-locals would escape the reset.
  sects=$(otool -l "$out" |
    awk '/^ *sectname/ {s=$2; next} /^ *segname/ && s != "" {print $2 "," s; s=""}' |
    grep -v -e '^__TEXT,' -e '^__LD,' |
    grep -v -e '^__DATA,__gbft_data$' -e '^__DATA,__gbft_bss$' -e '^__DATA,__const$' || true)
  [ -z "$sects" ] || die "$tool: unexpected writable sections: $sects"
  [ "$(nm -gU "$out" | awk '{print $3}')" = "_gb_fftool_${tool}_main" ] ||
    die "$tool: unexpected exported symbols: $(nm -gU "$out")"
}

ios_ffmpeg_slice() { # SLICE
  local slice=$1 sdk target sysroot cflags w out f
  sdk=$(ios_ffmpeg_sdk "$slice")
  target=$(ios_ffmpeg_target "$slice")
  sysroot=$(ios_ffmpeg_env xcrun --sdk "$sdk" --show-sdk-path)
  cflags="-target $target -isysroot $sysroot"
  w=$WORK/ios_ffmpeg/$slice
  out=$IOS/ffmpeg/$slice
  log "ios_ffmpeg: $slice ($target)"
  rm -rf "$w" "$out"
  mkdir -p "$w" "$out/lib" "$out/include"

  ios_ffmpeg_env /usr/bin/clang $cflags -O2 -Wall \
    -c "$PKG/ios/ffmpeg/gb_thread_tag.c" -o "$w/gb_thread_tag.o"
  unpack ffmpeg "$w/ffmpeg"
  cd "$w/ffmpeg"
  patch -p1 -s < "$PKG/ios/ffmpeg/patches/ffmpeg-8.1.2-inprocess.patch"
  ios_ffmpeg_env ./configure \
    --prefix=/var/empty --enable-cross-compile --target-os=darwin --arch=aarch64 \
    --cc=/usr/bin/clang --cxx=/usr/bin/clang++ \
    --extra-cflags="$cflags" --extra-cxxflags="$cflags" --extra-ldflags="$cflags" \
    --disable-autodetect --enable-static --disable-shared \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs="-liconv $w/gb_thread_tag.o" \
    --disable-ffplay --disable-doc --disable-debug
  grep -q '^#define CONFIG_GPL 0' config.h && grep -q 'FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h ||
    die "ios_ffmpeg: not an LGPL-2.1 configuration"
  grep '^EXTRALIBS' ffbuild/config.mak
  echo "CFLAGS += -include $PKG/ios/ffmpeg/gb_thread_tag.h" >> ffbuild/config.mak
  for f in $ios_ffmpeg_libs; do
    ios_ffmpeg_env make -j"$JOBS" "$f/$f.a"
  done
  ios_ffmpeg_fftool "$w/ffmpeg" ffmpeg "$w/fftools-ffmpeg.o" "$cflags"
  ios_ffmpeg_fftool "$w/ffmpeg" ffprobe "$w/fftools-ffprobe.o" "$cflags"
  ios_ffmpeg_env make install-headers DESTDIR="$w/hdr"
  cp -R "$w/hdr/var/empty/include/." "$out/include/"

  ios_ffmpeg_env /usr/bin/clang $cflags -O2 -Wall -I"$out/include" \
    -c "$PKG/ios/ffmpeg/gb_ffmpeg.c" -o "$w/gb_ffmpeg.o"

  ios_ffmpeg_env libtool -static -no_warning_for_no_symbols -o "$out/lib/libGlitchFFmpeg.a" \
    $(for f in $ios_ffmpeg_libs; do echo "$w/ffmpeg/$f/$f.a"; done) \
    "$w/fftools-ffmpeg.o" "$w/fftools-ffprobe.o" "$w/gb_ffmpeg.o" "$w/gb_thread_tag.o"

  mkdir -p "$out/include/GlitchFFmpeg"
  cp "$PKG/ios/ffmpeg/gb_ffmpeg.h" "$PKG/ios/ffmpeg/GlitchFFmpeg.h" \
    "$PKG/ios/ffmpeg/module.modulemap" "$out/include/GlitchFFmpeg/"
  cd "$ROOT"
  rm -rf "$w"
}

build_ios_ffmpeg() {
  local s args xcf=$IOS_XCF/GlitchFFmpeg.xcframework
  for s in $ios_ffmpeg_slices; do ios_ffmpeg_slice "$s"; done
  args=
  for s in $ios_ffmpeg_slices; do
    args="$args -library $IOS/ffmpeg/$s/lib/libGlitchFFmpeg.a -headers $IOS/ffmpeg/$s/include"
  done
  mkdir -p "$IOS_XCF"
  rm -rf "$xcf"
  menv_swift xcodebuild -create-xcframework $args -output "$xcf"
  find "$xcf" -maxdepth 2 | LC_ALL=C sort
  rm -rf "$WORK/ios_ffmpeg"
}
