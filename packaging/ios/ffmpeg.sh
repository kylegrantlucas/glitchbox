# packaging/ios/ffmpeg.sh — stage ios_ffmpeg: GlitchFFmpeg.xcframework.
# Sourced by packaging/build.sh (runs under /bin/bash 3.2).
#
# One static library per slice (ios-arm64, ios-arm64-simulator, macos-arm64)
# holding FFmpeg 8.1.2's libraries (the macOS build_ffmpeg feature set: GPL,
# static libx264, frei0r, VideoToolbox, AudioToolbox, system zlib/bzip2/iconv),
# x264, the five frei0r plugins plugins/*.json use, and the ffmpeg and ffprobe
# tools as functions (gb_ffmpeg_run / gb_ffprobe_run, ffmpeg/gb_ffmpeg.h).
#
#  - frei0r: each plugin is compiled with its f0r_* entry points renamed to
#    gbf0r_<plugin>_<entry> and linked (ld -r) into one object that exports
#    only those; ffmpeg/gb_frei0r_table.c maps module names to them, and the
#    patched vf_frei0r.c looks plugins up there instead of dlopen/FREI0R_PATH.
#    Compiler flags are frei0r's CMake Release ones (-O3 -DNDEBUG), as on macOS.
#    ffmpeg/patches/frei0r-2.5.1-ios.patch keeps pixs0r's row blocks at least
#    one row tall (a 0-row block looped forever: in-process nothing can kill
#    it) and vertigo's clamped source index inside its frame buffer.
#  - fftools: ffmpeg/patches/ffmpeg-8.1.2-inprocess.patch renames the mains,
#    drops signal handlers, terminal and stdin handling, setvbuf, setrlimit,
#    and every exit(), and polls the host's cancel atom where a SIGTERM would
#    land. ffmpeg/gb_fftools_prefix.h (force-included) sends the tools'
#    stdout/stderr to the run's log. Each tool (with its own cmdutils,
#    opt_common, and text formatters) is linked into one relocatable object
#    exporting only its main, with __DATA,__data/__bss/__common renamed to
#    __DATA,__gbft_data/__gbft_bss; gb_ffmpeg.c restores those sections before
#    every run, which resets every fftools global.
#  - ffmpeg/gb_thread_tag.h is force-included into every C file of x264, the
#    libav* libraries and the fftools (appended to their config.mak CFLAGS
#    after configure, so configure's own test programs are unchanged; they
#    link ffmpeg/gb_thread_tag.c's object through --extra-libs, as x264 needs
#    it): threads inherit their creator's run tag, which gb_ffmpeg.c uses to
#    send each av_log line to the run that logged it (see there).
#  - libavformat/file.c (same patch) marks the descriptors it opens or dups
#    F_SETNOSIGPIPE: a closed pipe reader must give EPIPE, not kill the host.
#  - FFmpeg's configure finds x264 through pkg-config; a shim answering for
#    x264 alone stands in, so the stage needs no other stage.
#
# Output: build/ios/xcframeworks/GlitchFFmpeg.xcframework; its Headers hold the
# public libav*/libsw* headers and GlitchFFmpeg/{module.modulemap,
# GlitchFFmpeg.h, gb_ffmpeg.h} (module GlitchFFmpeg, found by clang's
# <search path>/<Module>/module.modulemap lookup; the subdirectory keeps the
# module map from colliding with other static xcframeworks' Headers).
# Host tests: packaging/ios/ffmpeg/test (not part of the stage).

ios_ffmpeg_srcs="ffmpeg x264 frei0r"
ios_ffmpeg_inputs="packaging/ios/ffmpeg/patches packaging/ios/ffmpeg/gb_ffmpeg.c packaging/ios/ffmpeg/gb_ffmpeg.h packaging/ios/ffmpeg/gb_fftools_prefix.h packaging/ios/ffmpeg/gb_thread_tag.h packaging/ios/ffmpeg/gb_thread_tag.c packaging/ios/ffmpeg/gb_frei0r_table.c packaging/ios/ffmpeg/GlitchFFmpeg.h packaging/ios/ffmpeg/module.modulemap"
ios_ffmpeg_slices="ios-arm64 ios-arm64-simulator macos-arm64"
ios_ffmpeg_frei0r_plugins="glitch0r kaleid0sc0pe distort0r pixs0r vertigo"
ios_ffmpeg_f0r_entries="init deinit get_plugin_info get_param_info construct destruct set_param_value get_param_value update update2"
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

ios_ffmpeg_x264() { # SRC PREFIX CFLAGS
  cd "$1"
  ios_ffmpeg_env CC=/usr/bin/clang ./configure --prefix="$2" \
    --host=aarch64-apple-darwin --enable-static --enable-pic \
    --disable-cli --disable-opencl \
    --extra-cflags="$3" --extra-asflags="$3" --extra-ldflags="$3"
  echo "CFLAGS += -include $PKG/ios/ffmpeg/gb_thread_tag.h" >> config.mak
  ios_ffmpeg_env make -j"$JOBS"
  ios_ffmpeg_env make install
}

# Writes OUT/frei0r.o (the plugins, exporting only gbf0r_*) and
# OUT/gb_frei0r_table.o.
ios_ffmpeg_frei0r() { # SRC OUT CFLAGS
  local src=$1 out=$2 cflags=$3 p e f defs objs std
  mkdir -p "$out/obj"
  : > "$out/exports"
  {
    echo '/* generated by packaging/ios/ffmpeg.sh */'
    printf '#define GB_FREI0R_PLUGINS(X)'
    for p in $ios_ffmpeg_frei0r_plugins; do printf ' X(%s)' "$p"; done
    echo
  } > "$out/gb_frei0r_plugins.h"
  objs=
  for p in $ios_ffmpeg_frei0r_plugins; do
    defs=
    for e in $ios_ffmpeg_f0r_entries; do
      defs="$defs -Df0r_$e=gbf0r_${p}_$e"
      [ "$e" = update2 ] || printf '_gbf0r_%s_%s\n' "$p" "$e" >> "$out/exports"
    done
    # kaleid0sc0pe's CMakeLists pins C++11; the others use the default.
    std=
    [ "$p" != kaleid0sc0pe ] || std=-std=c++11
    for f in "$src/src/filter/$p"/*.c "$src/src/filter/$p"/*.cpp "$src/src/filter/$p"/*.cc; do
      [ -e "$f" ] || continue
      case $f in
        *.c) ios_ffmpeg_env /usr/bin/clang $cflags -O3 -DNDEBUG -fPIC $defs \
               -I"$src/include" -c "$f" -o "$out/obj/$p-$(basename "$f").o" ;;
        *) ios_ffmpeg_env /usr/bin/clang++ $cflags $std -O3 -DNDEBUG -fPIC $defs \
             -I"$src/include" -c "$f" -o "$out/obj/$p-$(basename "$f").o" ;;
      esac
      objs="$objs $out/obj/$p-$(basename "$f").o"
    done
  done
  # One object; everything but the renamed entry points becomes local, so the
  # plugins' helpers and frei0r.hpp statics cannot collide.
  ios_ffmpeg_env /usr/bin/clang $cflags -r -nostdlib \
    -Wl,-exported_symbols_list,"$out/exports" -o "$out/frei0r.o" $objs
  ios_ffmpeg_env /usr/bin/clang $cflags -O2 -I"$src/include" -I"$out" \
    -c "$PKG/ios/ffmpeg/gb_frei0r_table.c" -o "$out/gb_frei0r_table.o"
  [ "$(nm -gU "$out/frei0r.o" | wc -l | tr -d ' ')" = "$(wc -l < "$out/exports" | tr -d ' ')" ] ||
    die "frei0r.o exports differ from $out/exports"
}

# The x264-only pkg-config FFmpeg's configure asks.
ios_ffmpeg_pkgconfig() { # X264-PREFIX OUT
  cat > "$2" <<EOF
#!/bin/sh
# generated by packaging/ios/ffmpeg.sh: pkg-config for x264 only
out=
for a in "\$@"; do
  case \$a in
    --version) echo 0.29.2; exit 0 ;;
    --cflags) out="\$out -I$1/include" ;;
    --libs) out="\$out -L$1/lib -lx264 -lpthread -lm" ;;
    --modversion) out="\$out \$(sed -n 's/^Version: //p' '$1/lib/pkgconfig/x264.pc')" ;;
    --*) ;;
    x264) ;;
    *) exit 1 ;;
  esac
done
[ -z "\$out" ] || echo \$out
EOF
  chmod 755 "$2"
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
  mkdir -p "$w/bin" "$out/lib" "$out/include"

  ios_ffmpeg_env /usr/bin/clang $cflags -O2 -Wall \
    -c "$PKG/ios/ffmpeg/gb_thread_tag.c" -o "$w/gb_thread_tag.o"
  unpack x264 "$w/x264"
  ios_ffmpeg_x264 "$w/x264" "$w/x264-prefix" "$cflags"

  unpack frei0r "$w/frei0r-src"
  (cd "$w/frei0r-src" && patch -p1 -s < "$PKG/ios/ffmpeg/patches/frei0r-2.5.1-ios.patch")
  ios_ffmpeg_frei0r "$w/frei0r-src" "$w/frei0r" "$cflags"

  ios_ffmpeg_pkgconfig "$w/x264-prefix" "$w/bin/pkg-config"
  unpack ffmpeg "$w/ffmpeg"
  cd "$w/ffmpeg"
  patch -p1 -s < "$PKG/ios/ffmpeg/patches/ffmpeg-8.1.2-inprocess.patch"
  ios_ffmpeg_env ./configure \
    --prefix=/var/empty --enable-cross-compile --target-os=darwin --arch=aarch64 \
    --cc=/usr/bin/clang --cxx=/usr/bin/clang++ \
    --extra-cflags="$cflags -I$w/frei0r-src/include" --extra-cxxflags="$cflags" \
    --extra-ldflags="$cflags" \
    --pkg-config="$w/bin/pkg-config" --pkg-config-flags=--static \
    --disable-autodetect --enable-static --disable-shared \
    --enable-gpl --enable-libx264 --enable-frei0r \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv --extra-libs="-liconv $w/gb_thread_tag.o" \
    --disable-ffplay --disable-doc --disable-debug
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
    "$w/x264-prefix/lib/libx264.a" "$w/frei0r/frei0r.o" "$w/frei0r/gb_frei0r_table.o" \
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
