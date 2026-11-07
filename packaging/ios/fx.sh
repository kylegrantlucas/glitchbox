# shellcheck shell=bash
# Sourced by packaging/build.sh: stage ios_fx -> GlitchboxFX.xcframework.
#
# app/rust/glitchbox-fx is one Rust staticlib over the media-free cores of
# ntsc-rs (@add90f5), bender-rs (@1ddcf66), and reactive-vcr (v0.4.1); its
# git dependencies are pinned in its Cargo.lock and fetched by cargo into
# build/downloads/cargo-home. Each slice is a release build (LTO, one codegen
# unit, from the crate's Cargo.toml) of libglitchbox_fx.a, unstripped for the
# same reason cargo_build is: Xcode 27's `strip -S` corrupts chained-fixup
# Rust output. Headers: include/glitchbox_fx.h and module.modulemap
# (module GlitchboxFX; links the archive and libiconv, which the Rust std
# needs besides libSystem).

ios_fx_srcs=""
ios_fx_inputs="app/rust/glitchbox-fx/Cargo.toml app/rust/glitchbox-fx/Cargo.lock app/rust/glitchbox-fx/src app/rust/glitchbox-fx/include"

ios_fx_cargo() { # TARGET-TRIPLE DEPLOYMENT-VAR
  local triple=$1 dvar=$2 crate=$ROOT/app/rust/glitchbox-fx flags
  local -a f=(
    "--remap-path-prefix=$DL/cargo-home=/cargo"
    "--remap-path-prefix=$crate=/glitchbox-fx"
    "--remap-path-prefix=$RUST_SYSROOT=/rust"
  )
  flags=$(IFS=$'\x1f'; printf '%s' "${f[*]}")
  # menv pins MACOSX_DEPLOYMENT_TARGET; the iOS slices take theirs from
  # IPHONEOS_DEPLOYMENT_TARGET (the simulator triple reads the same variable).
  (cd "$crate" && menv \
    "$dvar=$DEPLOYMENT_TARGET" \
    CARGO_HOME="$DL/cargo-home" CARGO_TARGET_DIR="$WORK/fx-target" CARGO_TERM_COLOR=never \
    CARGO_PROFILE_RELEASE_STRIP=false \
    RUSTC="$TOOLBIN/rustc" \
    CARGO_ENCODED_RUSTFLAGS="$flags" \
    cargo build --release --locked --lib --target "$triple")
}

build_ios_fx() {
  local crate=$ROOT/app/rust/glitchbox-fx out=$IOS/fx hdr t
  local triples="aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin"
  for t in $triples; do
    "$RUSTC_BIN" --print target-libdir --target "$t" >/dev/null 2>&1 &&
      [ -d "$("$RUSTC_BIN" --print target-libdir --target "$t")" ] ||
      die "ios_fx: Rust target $t is not installed (rustup target add $t)"
  done
  rm -rf "$out" "$WORK/fx-target"
  mkdir -p "$out" "$IOS_XCF"
  ios_fx_cargo aarch64-apple-ios IPHONEOS_DEPLOYMENT_TARGET
  ios_fx_cargo aarch64-apple-ios-sim IPHONEOS_DEPLOYMENT_TARGET
  ios_fx_cargo aarch64-apple-darwin MACOSX_DEPLOYMENT_TARGET

  hdr=$out/include
  mkdir -p "$hdr"
  cp "$crate/include/glitchbox_fx.h" "$crate/include/module.modulemap" "$hdr/"
  for t in $triples; do
    mkdir -p "$out/$t"
    cp "$WORK/fx-target/$t/release/libglitchbox_fx.a" "$out/$t/"
  done

  rm -rf "$IOS_XCF/GlitchboxFX.xcframework"
  menv_swift xcodebuild -create-xcframework \
    -library "$out/aarch64-apple-ios/libglitchbox_fx.a" -headers "$hdr" \
    -library "$out/aarch64-apple-ios-sim/libglitchbox_fx.a" -headers "$hdr" \
    -library "$out/aarch64-apple-darwin/libglitchbox_fx.a" -headers "$hdr" \
    -output "$IOS_XCF/GlitchboxFX.xcframework"
  rm -rf "$WORK/fx-target"
}
