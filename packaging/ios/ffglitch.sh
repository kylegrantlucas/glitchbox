# packaging/ios/ffglitch.sh — stage ios_ffglitch: FFglitch.xcframework.
# Sourced by packaging/build.sh (runs under /bin/bash 3.2).
#
# FFglitch 0.10.2 (an FFmpeg 7.0 fork that changes AVPacket/AVFrame/
# AVFormatContext/AVCodec) built from source as one dynamic framework per slice
# (ios-arm64, ios-arm64-simulator, macos-arm64; install name
# @rpath/FFglitch.framework/FFglitch, the macOS one in the versioned layout).
# Its libav* never meet the app's FFmpeg 8.1: everything is compiled
# -fvisibility=hidden and the dylib exports only ffglitch_ffgac_run and
# ffglitch_ffedit_run (ffglitch/ffglitch.h, module FFglitch).
#
#  - ffglitch/inprocess.patch: ffgac never touches the terminal or installs
#    signal handlers (always -nostdin, no overwrite prompt) and gets a
#    SIGTERM-equivalent cancel entry; libavformat/file.c waits for pipe I/O in
#    poll() slices so failed/cancelled runs never hang, registers the fds it
#    opens with the run, and sets F_SETNOSIGPIPE; libavutil/log.c takes its
#    level and sink from the current run; QuickJS scripts are interrupted when
#    their run fails or is cancelled, and std.popen/std.urlGet/os.exec/
#    os.signal/os.ttySetRaw throw; libpython is never dlopen()ed.
#  - ffglitch/ffg_hooks.h is force-included into every object (exit,
#    pthread_create, pthread_cond_wait, fopen/fdopen/fclose go to
#    ffglitch/ffglitch_runtime.c), ffglitch/ffg_tool_hooks.h also into the
#    fftools objects (tracked threads, stdout/stderr to the run's log).
#  - Each tool (ffgac = fftools/ffmpeg, ffedit) with its own cmdutils and
#    opt_common is linked into one relocatable object exporting only its
#    entry points, its writable data renamed to __DATA,__<tool>_data/_bss;
#    the runtime restores those sections before every run (fresh globals),
#    and the two tools share no fftools state, so they run concurrently.
#  - Configure matches the macOS prebuilt (GPL, every codec, zlib) minus
#    libzmq/rtmidi/SDL2/AVFoundation (no avdevice, no autodetected system
#    frameworks), so ffgac/ffedit produce the same bitstreams.
#
# Output: build/ios/xcframeworks/FFglitch.xcframework.
# Host tests: packaging/ios/ffglitch/test (not part of the stage).

ios_ffglitch_srcs="ffglitch-src"
ios_ffglitch_inputs="packaging/ios/ffglitch/inprocess.patch packaging/ios/ffglitch/ffg_hooks.h packaging/ios/ffglitch/ffg_tool_hooks.h packaging/ios/ffglitch/ffglitch_runtime.c packaging/ios/ffglitch/ffglitch.h packaging/ios/ffglitch/module.modulemap"
ios_ffglitch_slices="ios-arm64 ios-arm64-simulator macos-arm64"
ios_ffglitch_libs="libavfilter libavformat libavcodec libpostproc libswresample libswscale libavutil"
ios_ffglitch_exports="_ffglitch_ffgac_run _ffglitch_ffedit_run"
# What the framework must never reference: process spawning, dlopen, signal
# handlers, terminal control.
ios_ffglitch_forbidden='^_(fork|vfork|execl|execle|execlp|execv|execve|execvp|execvP|popen|system|posix_spawn|posix_spawnp|dlopen|signal|sigaction|tcsetattr)$'

# The compilers take the OS and version from -target; menv's
# MACOSX_DEPLOYMENT_TARGET would only contradict it on the iOS slices.
ios_ffglitch_env() { menv /usr/bin/env -u MACOSX_DEPLOYMENT_TARGET "$@"; }

ios_ffglitch_sdk() { # SLICE -> xcrun SDK name
  case $1 in
    ios-arm64) echo iphoneos ;;
    ios-arm64-simulator) echo iphonesimulator ;;
    macos-arm64) echo macosx ;;
  esac
}
ios_ffglitch_target() { # SLICE -> clang target triple
  case $1 in
    ios-arm64) echo "arm64-apple-ios$DEPLOYMENT_TARGET" ;;
    ios-arm64-simulator) echo "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" ;;
    macos-arm64) echo "arm64-apple-macos$DEPLOYMENT_TARGET" ;;
  esac
}
ios_ffglitch_platform() { # SLICE -> CFBundleSupportedPlatforms entry
  case $1 in
    ios-arm64) echo iPhoneOS ;;
    ios-arm64-simulator) echo iPhoneSimulator ;;
    macos-arm64) echo MacOSX ;;
  esac
}

# Prints the values of FFmpeg make variables (Xcode's make 3.81 has no --eval).
ios_ffglitch_print() { # SRC VAR...
  local s=$1 v targets=
  shift
  printf 'ffg-print-%%:\n\t@echo $($*)\n' > "$s/ffg-print.mak"
  for v in "$@"; do targets="$targets ffg-print-$v"; done
  (cd "$s" && make -s -f Makefile -f ffg-print.mak $targets)
}

# Links TOOL's fftools objects (built with the tool hooks and main renamed to
# NAME_tool_main) into OUT, exporting only NAME_tool_main plus EXTRA symbols,
# its writable data renamed into the sections the runtime resets.
ios_ffglitch_fftool() { # SRC TOOL NAME OUT CFLAGS EXTRA...
  local s=$1 tool=$2 name=$3 out=$4 cflags=$5 objs sects exp e
  shift 5
  objs=$(ios_ffglitch_print "$s" "OBJS-$tool")
  [ -n "$objs" ] || die "ios_ffglitch: no OBJS-$tool"
  # cmdutils.o/opt_common.o are shared by both tools: rebuild them each time
  # (same flags; only the main rename differs, and they have no main).
  (cd "$s" && rm -f $objs &&
    ios_ffglitch_env make -j"$JOBS" \
      ECFLAGS="-include $PKG/ios/ffglitch/ffg_hooks.h -include $PKG/ios/ffglitch/ffg_tool_hooks.h -Dmain=${name}_tool_main" \
      $objs)
  exp="-Wl,-exported_symbol,_${name}_tool_main"
  for e in "$@"; do exp="$exp -Wl,-exported_symbol,_$e"; done
  (cd "$s" && ios_ffglitch_env /usr/bin/clang $cflags -r -nostdlib $exp \
    -Wl,-rename_section,__DATA,__data,__DATA,__${name}_data \
    -Wl,-rename_section,__DATA,__bss,__DATA,__${name}_bss \
    -Wl,-rename_section,__DATA,__common,__DATA,__${name}_bss \
    -o "$out" $objs)
  # Every writable byte must be in a reset section (__DATA,__const is
  # read-only once fixed up); thread-locals would escape the reset.
  sects=$(otool -l "$out" | awk '/sectname/ {s=$2; next} /segname/ && s != "" {print $2 "," s; s=""}' |
    grep -v '^__TEXT,' | grep -v '^__LD,' |
    grep -v -e "^__DATA,__${name}_data\$" -e "^__DATA,__${name}_bss\$" -e '^__DATA,__const$' || true)
  [ -z "$sects" ] || die "ios_ffglitch: $name: unexpected writable sections: $sects"
  nm -gU "$out"
  [ "$(nm -gU "$out" | wc -l | tr -d ' ')" = "$(($# + 1))" ] ||
    die "ios_ffglitch: $name: unexpected exported symbols"
}

ios_ffglitch_plist() { # SLICE OUT
  local min
  case $1 in
    macos-arm64) min="<key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>" ;;
    *) min="<key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>" ;;
  esac
  cat > "$2" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>FFglitch</string>
  <key>CFBundleIdentifier</key><string>com.kylegrantlucas.glitchbox.FFglitch</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>FFglitch</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$(lock_field ffglitch-src version)</string>
  <key>CFBundleVersion</key><string>$(lock_field ffglitch-src version)</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$(ios_ffglitch_platform "$1")</string></array>
  $min
</dict>
</plist>
EOF
}

ios_ffglitch_slice() { # SLICE
  local slice=$1 sdk target sysroot cflags w s out fw bin res hdr extralibs f ver
  sdk=$(ios_ffglitch_sdk "$slice")
  target=$(ios_ffglitch_target "$slice")
  sysroot=$(ios_ffglitch_env xcrun --sdk "$sdk" --show-sdk-path)
  cflags="-target $target -isysroot $sysroot"
  ver=$(lock_field ffglitch-src version)
  w=$WORK/ios_ffglitch/$slice
  s=$w/ffglitch
  out=$IOS/ffglitch/$slice
  fw=$out/FFglitch.framework
  log "ios_ffglitch: $slice ($target)"
  rm -rf "$w" "$out"
  mkdir -p "$w" "$out"

  unpack ffglitch-src "$s"
  cd "$s"
  patch -p1 -s < "$PKG/ios/ffglitch/inprocess.patch"
  ios_ffglitch_env ./configure \
    --prefix=/var/empty --enable-cross-compile --target-os=darwin --arch=aarch64 \
    --cc=/usr/bin/clang --cxx=/usr/bin/clang++ \
    --extra-cflags="$cflags -fvisibility=hidden -fno-common" --extra-cxxflags="$cflags -fvisibility=hidden -fno-common" \
    --extra-ldflags="$cflags" \
    --disable-autodetect --enable-static --disable-shared --enable-gpl \
    --disable-iconv --enable-zlib \
    --disable-libzmq --disable-rtmidi --disable-sdl2 --disable-avdevice \
    --disable-ffplay --disable-doc --disable-debug
  for f in $ios_ffglitch_libs; do
    ios_ffglitch_env make -j"$JOBS" ECFLAGS="-include $PKG/ios/ffglitch/ffg_hooks.h" "$f/$f.a"
  done
  ios_ffglitch_fftool "$s" ffmpeg ffgac "$w/ffgac.o" "$cflags" ffgac_tool_cancel
  ios_ffglitch_fftool "$s" ffedit ffedit "$w/ffedit.o" "$cflags"
  ios_ffglitch_env /usr/bin/clang $cflags -O2 -Wall -fvisibility=hidden \
    -I"$s" -I"$PKG/ios/ffglitch" \
    -c "$PKG/ios/ffglitch/ffglitch_runtime.c" -o "$w/ffglitch_runtime.o"

  extralibs=$(ios_ffglitch_print "$s" \
    EXTRALIBS-avfilter EXTRALIBS-avformat EXTRALIBS-avcodec EXTRALIBS-postproc \
    EXTRALIBS-swresample EXTRALIBS-swscale EXTRALIBS-avutil | tr '\n' ' ')
  log "ios_ffglitch: extra libs: $extralibs"
  for f in $ios_ffglitch_exports; do echo "$f"; done > "$w/exports"

  if [ "$slice" = macos-arm64 ]; then
    mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
    ln -s A "$fw/Versions/Current"
    for f in FFglitch Headers Modules Resources; do ln -s "Versions/Current/$f" "$fw/$f"; done
    bin=$fw/Versions/A/FFglitch
    res=$fw/Versions/A/Resources
    hdr=$fw/Versions/A
  else
    mkdir -p "$fw/Headers" "$fw/Modules"
    bin=$fw/FFglitch
    res=$fw
    hdr=$fw
  fi
  ios_ffglitch_env /usr/bin/clang $cflags -dynamiclib -o "$bin" \
    -install_name @rpath/FFglitch.framework/FFglitch \
    -compatibility_version 1 -current_version "$ver" \
    -Wl,-exported_symbols_list,"$w/exports" -Wl,-dead_strip -Wl,-dead_strip_dylibs -Wl,-x \
    "$w/ffgac.o" "$w/ffedit.o" "$w/ffglitch_runtime.o" \
    $(for f in $ios_ffglitch_libs; do echo "$s/$f/$f.a"; done) \
    $extralibs
  cp "$PKG/ios/ffglitch/ffglitch.h" "$hdr/Headers/"
  cp "$PKG/ios/ffglitch/module.modulemap" "$hdr/Modules/"
  ios_ffglitch_plist "$slice" "$res/Info.plist"

  # Only the API is exported; nothing spawns processes or loads code.
  [ "$(nm -gU "$bin" | awk '{print $3}' | LC_ALL=C sort | tr '\n' ' ')" = \
    "$(LC_ALL=C sort "$w/exports" | tr '\n' ' ')" ] ||
    die "ios_ffglitch: $slice exports: $(nm -gU "$bin")"
  if nm -u "$bin" | grep -E "$ios_ffglitch_forbidden"; then
    die "ios_ffglitch: $slice references forbidden symbols (above)"
  fi
  otool -L "$bin"
  cd "$ROOT"
  rm -rf "$w"
}

build_ios_ffglitch() {
  local s args xcf=$IOS_XCF/FFglitch.xcframework
  for s in $ios_ffglitch_slices; do ios_ffglitch_slice "$s"; done
  args=
  for s in $ios_ffglitch_slices; do args="$args -framework $IOS/ffglitch/$s/FFglitch.framework"; done
  mkdir -p "$IOS_XCF"
  rm -rf "$xcf"
  menv_swift xcodebuild -create-xcframework $args -output "$xcf"
  find "$xcf" -maxdepth 2 | LC_ALL=C sort
  rm -rf "$WORK/ios_ffglitch"
}
