# GlitchboxBurns.xcframework + onnxruntime.xcframework (stage ios_burns), sourced by build.sh.
#
# app/rust/glitchbox-burns is a cdylib over burns-rs's render core (the same commit as the
# macOS `burns` helper, pinned by rev in its Cargo.lock): a still + project JSON in, RGBA8
# frames out (header glitchbox_burns.h), no process spawning and no encoding. Rendering is
# wgpu over Metal, which works on device and in the iOS 26+ simulator.
#
# Depth estimation dlopens ONNX Runtime (burns-depth uses ort's load-dynamic). Microsoft
# ships no dynamic iOS ONNX Runtime, so the official onnxruntime-c pod's static framework
# (a single prelinked object per slice) is relinked here, unchanged, into a dynamic
# onnxruntime.framework exporting only the C entry points (_Ort*). The app embeds it beside
# GlitchboxBurns.framework, where gb_burns_create finds it when ort_library is NULL.
#
# Both xcframeworks are dynamic frameworks with ios-arm64, ios-arm64-simulator, and
# macos-arm64 (versioned bundle) slices. The check at the end renders a 2D and a depth
# clip with the macOS slice (model pre-seeded from sources.json, so no network) and links
# the C smoke program against the device slice.
ios_burns_srcs="onnxruntime-c-pod depth-anything-v2-small"
ios_burns_inputs="app/rust/glitchbox-burns"

ios_burns_slices="ios-arm64 ios-arm64-simulator macos-arm64"

ios_burns_triple() { # SLICE
  case $1 in
    ios-arm64) echo aarch64-apple-ios ;;
    ios-arm64-simulator) echo aarch64-apple-ios-sim ;;
    macos-arm64) echo aarch64-apple-darwin ;;
  esac
}

ios_burns_clang_target() { # SLICE
  case $1 in
    ios-arm64) echo "arm64-apple-ios$DEPLOYMENT_TARGET" ;;
    ios-arm64-simulator) echo "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" ;;
    macos-arm64) echo "arm64-apple-macos$DEPLOYMENT_TARGET" ;;
  esac
}

ios_burns_sdk() { # SLICE
  case $1 in
    ios-arm64) echo iphoneos ;;
    ios-arm64-simulator) echo iphonesimulator ;;
    macos-arm64) echo macosx ;;
  esac
}

ios_burns_platform() { # SLICE -> CFBundleSupportedPlatforms entry
  case $1 in
    ios-arm64) echo iPhoneOS ;;
    ios-arm64-simulator) echo iPhoneSimulator ;;
    macos-arm64) echo MacOSX ;;
  esac
}

# Where a framework's binary, Info.plist, and headers go: flat on iOS, Versions/A on macOS.
ios_burns_fw_dir() { # SLICE FRAMEWORK-DIR
  case $1 in
    macos-arm64) echo "$2/Versions/A" ;;
    *) echo "$2" ;;
  esac
}

ios_burns_install_name() { # SLICE NAME
  case $1 in
    macos-arm64) echo "@rpath/$2.framework/Versions/A/$2" ;;
    *) echo "@rpath/$2.framework/$2" ;;
  esac
}

ios_burns_info_plist() { # SLICE NAME ID VERSION OUT
  local min=MinimumOSVersion
  [ "$1" = macos-arm64 ] && min=LSMinimumSystemVersion
  cat > "$5" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$4</string>
  <key>CFBundleVersion</key><string>$4</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$(ios_burns_platform "$1")</string></array>
  <key>$min</key><string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
}

# Lays out NAME.framework around BINARY (already carrying its install name) and HEADERS-DIR.
ios_burns_framework() { # SLICE NAME ID VERSION BINARY HEADERS-DIR MODULEMAP-FILE OUT-DIR
  local slice=$1 name=$2 fw=$8/$2.framework d
  rm -rf "$fw"
  d=$(ios_burns_fw_dir "$slice" "$fw")
  mkdir -p "$d/Headers" "$d/Modules"
  install -m 755 "$5" "$d/$name"
  cp "$6"/*.h "$d/Headers/"
  cp "$7" "$d/Modules/module.modulemap"
  if [ "$slice" = macos-arm64 ]; then
    mkdir -p "$d/Resources"
    ios_burns_info_plist "$slice" "$name" "$3" "$4" "$d/Resources/Info.plist"
    ln -s A "$fw/Versions/Current"
    for l in "$name" Headers Modules Resources; do ln -s "Versions/Current/$l" "$fw/$l"; done
  else
    ios_burns_info_plist "$slice" "$name" "$3" "$4" "$d/Info.plist"
  fi
  codesign --force --sign - --timestamp=none "$fw"
}

ios_burns_cargo() { # SLICE TARGET-DIR
  local slice=$1 triple flags
  triple=$(ios_burns_triple "$slice")
  local -a f=(
    -C "link-arg=-Wl,-install_name,$(ios_burns_install_name "$slice" GlitchboxBurns)"
    "--remap-path-prefix=$DL/cargo-home=/cargo"
    "--remap-path-prefix=$WORK=/build"
    "--remap-path-prefix=$RUST_SYSROOT=/rust"
  )
  flags=$(IFS=$'\x1f'; printf '%s' "${f[*]}")
  # Release strip stays off (see cargo_build): Xcode 27's strip breaks chained-fixup images.
  (cd "$WORK/ios-burns/crate" && menv \
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    CARGO_HOME="$DL/cargo-home" CARGO_TARGET_DIR="$2" CARGO_TERM_COLOR=never \
    CARGO_PROFILE_RELEASE_STRIP=false RUSTC="$TOOLBIN/rustc" \
    CARGO_ENCODED_RUSTFLAGS="$flags" \
    cargo build --release --locked --lib --target "$triple")
}

# The pod's static framework for SLICE, thinned to arm64, relinked as a dylib.
ios_burns_ort_dylib() { # POD-DIR SLICE OUT
  local x=$1/onnxruntime.xcframework src a=$3.a
  case $2 in
    ios-arm64) src=$x/ios-arm64/onnxruntime.framework/onnxruntime ;;
    ios-arm64-simulator) src=$x/ios-arm64_x86_64-simulator/onnxruntime.framework/onnxruntime ;;
    macos-arm64) src=$x/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime ;;
  esac
  lipo "$src" -thin arm64 -output "$a" 2>/dev/null || cp "$src" "$a"
  printf '_Ort*\n' > "$3.exp"
  menv xcrun -sdk "$(ios_burns_sdk "$2")" clang -target "$(ios_burns_clang_target "$2")" \
    -dynamiclib -o "$3" -Wl,-all_load "$a" -lc++ -framework Foundation -weak_framework CoreML \
    -install_name "$(ios_burns_install_name "$2" onnxruntime)" \
    -Wl,-exported_symbols_list,"$3.exp" -Wl,-dead_strip
  rm -f "$a" "$3.exp"
}

build_ios_burns() {
  local w=$WORK/ios-burns pod ortv slice triple bin t name
  local crate=$ROOT/app/rust/glitchbox-burns
  rm -rf "$w"
  mkdir -p "$w/crate" "$w/pod" "$w/mod"
  pod=$w/pod
  ortv=$(lock_field onnxruntime-c-pod version)
  # The pod archive has several top-level entries, so no unpack (which strips one).
  tar -xf "$(src onnxruntime-c-pod)" -C "$pod"
  # The crate is copied so its target dir and lockfile resolution stay out of the checkout.
  cp -R "$crate/Cargo.toml" "$crate/Cargo.lock" "$crate/src" "$crate/include" "$w/crate/"
  cat > "$w/mod/gb.modulemap" <<'EOF'
framework module GlitchboxBurns {
  umbrella header "glitchbox_burns.h"
  export *
}
EOF
  cat > "$w/mod/ort.modulemap" <<'EOF'
framework module onnxruntime {
  header "onnxruntime_c_api.h"
  export *
}
EOF
  for slice in $ios_burns_slices; do
    triple=$(ios_burns_triple "$slice")
    t=$w/target
    ios_burns_cargo "$slice" "$t"
    bin=$t/$triple/release/libglitchbox_burns.dylib
    otool -D "$bin" | grep -qx "$(ios_burns_install_name "$slice" GlitchboxBurns)" ||
      die "ios_burns: $bin has install name $(otool -D "$bin" | tail -1)"
    ios_burns_framework "$slice" GlitchboxBurns org.glitchbox.GlitchboxBurns 0.1.0 \
      "$bin" "$crate/include" "$w/mod/gb.modulemap" "$w/fw/$slice"
    ios_burns_ort_dylib "$pod" "$slice" "$w/ort-$slice"
    ios_burns_framework "$slice" onnxruntime com.microsoft.onnxruntime "$ortv" \
      "$w/ort-$slice" "$pod/Headers" "$w/mod/ort.modulemap" "$w/fw/$slice"
  done
  mkdir -p "$IOS_XCF"
  for name in GlitchboxBurns onnxruntime; do
    rm -rf "$IOS_XCF/$name.xcframework"
    local -a args=()
    for slice in $ios_burns_slices; do args+=(-framework "$w/fw/$slice/$name.framework"); done
    menv_swift xcodebuild -create-xcframework "${args[@]}" -output "$IOS_XCF/$name.xcframework"
  done
  ios_burns_check "$w"
  rm -rf "$w"
}

# Host renders through the macOS slices (a 2D camera, and the depth camera with ONNX Runtime
# found beside GlitchboxBurns and the model in a pre-seeded cache, so no network), and a
# device-slice link of the same C program. Pixel parity with `burns render` is checked by
# the crate's tests/compare.sh, which needs a reference burns binary.
ios_burns_check() { # WORK
  local c=$1/check m
  local smoke=$ROOT/app/rust/glitchbox-burns/tests/smoke.c
  mkdir -p "$c/cache/models" "$c/Frameworks"
  cp -R "$IOS_XCF/GlitchboxBurns.xcframework/macos-arm64/GlitchboxBurns.framework" \
    "$IOS_XCF/onnxruntime.xcframework/macos-arm64/onnxruntime.framework" "$c/Frameworks/"
  menv xcrun -sdk macosx clang -target "arm64-apple-macos$DEPLOYMENT_TARGET" -O2 "$smoke" \
    -F "$c/Frameworks" -framework GlitchboxBurns -Wl,-rpath,@executable_path/Frameworks -o "$c/smoke"
  menv xcrun -sdk iphoneos clang -target "arm64-apple-ios$DEPLOYMENT_TARGET" -O2 "$smoke" \
    -F "$IOS_XCF/GlitchboxBurns.xcframework/ios-arm64" -framework GlitchboxBurns \
    -Wl,-rpath,@executable_path/Frameworks -o "$c/smoke-ios"
  cp -c "$(src depth-anything-v2-small)" \
    "$c/cache/models/$(lock_field depth-anything-v2-small sha256).onnx"
  for m in transform depth; do
    printf '%s' "{\"version\":1,\"output\":{\"width\":1920,\"height\":1080},
      \"timeline\":{\"fps\":{\"num\":30,\"den\":1},\"frames\":30},\"seed\":0,
      \"camera\":$(ios_burns_camera $m),\"depth\":{\"invert\":false},
      \"shake\":{\"enabled\":false,\"profile\":\"shake\",\"amount\":1.0,\"speed\":1.0},
      \"warp\":{\"type\":\"ripple\",\"enabled\":false,\"amplitude\":0.006,\"wavelength\":0.18,
      \"center\":[0.5,0.5],\"cycles\":2}}" > "$c/$m.json"
  done
  # `gradient:WxH` makes the smoke program pass synthetic pixels (the image_rgba path).
  (cd "$c" && menv ./smoke gradient:160x120 transform.json t.rgba 64 36 30 1 &&
    menv ./smoke gradient:160x120 depth.json d.rgba 64 36 30 1 auto "$c/cache")
  for m in t d; do
    [ "$(wc -c < "$c/$m.rgba")" -eq $((64 * 36 * 4 * 30)) ] || die "ios_burns: $m.rgba has the wrong size"
  done
  ls "$c/cache/depth/"*.png > /dev/null || die "ios_burns: no cached depth map"
  log "ios_burns: macOS slice rendered 2D and depth clips; device slice links"
}

ios_burns_camera() { # transform|depth: the still-motion plugin's defaults
  case $1 in
    transform) printf '%s' '{"type":"transform","start":{"zoom":1.04,"x":0.35,"y":0.5,"roll_degrees":0.0},"end":{"zoom":1.22,"x":0.65,"y":0.5,"roll_degrees":0.0},"easing":"cosine"}' ;;
    depth) printf '%s' '{"type":"depth","motion":"orbital","height":0.2,"steady":0.3,"focus":0.3,"zoom":0.98,"amount":1.0,"cycles":1}' ;;
  esac
}
