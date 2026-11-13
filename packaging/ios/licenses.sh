# shellcheck shell=bash
# Sourced by packaging/build.sh: stage ios_licenses -> build/ios/licenses, the
# licence texts of everything linked into the iOS app (assemble_ios copies the
# tree to Toolchain/licenses beside Credits.html, which the app's Licenses view
# shows). The macOS tree differs: no GStreamer, bash, SoX, jq, x264, or frei0r,
# FFmpeg and FFglitch are LGPL builds from source (each folder carries the
# in-process patch and a MODIFICATIONS.txt, as LGPL-2.1 §2 asks), ONNX Runtime
# is the iOS pod, and the Rust crate lists are cargo-about over the two in-repo
# wrapper crates (which pull in ntsc-rs's core, bender, reactive-vcr, and burns)
# with GPL refused (packaging/ios/about.toml).

ios_licenses_srcs="ffmpeg ffglitch-src ffglitch-scripts ntsc-rs bender-rs burns-rs reactive-vcr onnxruntime-c-pod"
ios_licenses_inputs="LICENSE packaging/ios/about.toml packaging/about.hbs packaging/ios/ffmpeg/patches/ffmpeg-8.1.2-inprocess.patch packaging/ios/ffglitch/inprocess.patch app/rust/glitchbox-fx/Cargo.toml app/rust/glitchbox-fx/Cargo.lock app/rust/glitchbox-burns/Cargo.toml app/rust/glitchbox-burns/Cargo.lock"

ios_licenses_crates() { # CRATE-DIR OUT: cargo-about over an in-repo crate
  mkdir -p "$(dirname "$2")"
  (cd "$1" && menv CARGO_HOME="$DL/cargo-home" "$CARGO_ABOUT" generate --locked \
    -c "$PKG/ios/about.toml" -m "$1/Cargo.toml" -o "$2" "$PKG/about.hbs")
}

# PATCH -> DIR/<patch name> plus DIR/MODIFICATIONS.txt naming the files it changes.
ios_licenses_modified() { # PATCH DIR
  local name
  name=$(basename "$1")
  cp "$1" "$2/$name"
  {
    printf 'Modified by Glitchbox for in-process use (%s):\n' "$(date -u +%Y-%m-%d)"
    grep '^+++ ' "$1" | sed 's|^+++ [ab]/||; s|^+++ src/||' | sed 's/^/  /'
    printf 'The full changes are in %s in this folder.\n' "$name"
  } > "$2/MODIFICATIONS.txt"
}

build_ios_licenses() {
  [ -n "$CARGO_ABOUT" ] || die "ios_licenses: cargo-about not found (cargo install cargo-about --locked --version 0.9.2)"
  local LIC=$IOS/licenses t=$WORK/ios-lic
  rm -rf "$LIC" "$t"
  lic_copy ffmpeg ffmpeg COPYING.LGPLv2.1 LICENSE.md
  ios_licenses_modified "$PKG/ios/ffmpeg/patches/ffmpeg-8.1.2-inprocess.patch" "$LIC/ffmpeg"
  lic_copy ffglitch-src ffglitch COPYING.LGPLv2.1 LICENSE.md
  ios_licenses_modified "$PKG/ios/ffglitch/inprocess.patch" "$LIC/ffglitch"
  mkdir -p "$t" "$LIC/ffglitch/quickjs"
  tar -xf "$(src ffglitch-src)" -C "$t" --strip-components 1 '*/libavutil/quickjs/LICENSE'
  cp "$t/libavutil/quickjs/LICENSE" "$LIC/ffglitch/quickjs/LICENSE"
  rm -rf "$t"
  lic_copy ffglitch-scripts ffglitch-scripts LICENSE
  lic_copy ntsc-rs ntsc-rs LICENSE-MIT LICENSE-APACHE-2.0 LICENSE-ISC
  lic_copy bender-rs bender-rs LICENSE-MIT LICENSE-APACHE
  lic_copy burns-rs burns-rs LICENSE-MIT LICENSE-APACHE
  lic_copy reactive-vcr reactive-vcr LICENSE
  mkdir -p "$LIC/onnxruntime"
  unzip -p "$(src onnxruntime-c-pod)" LICENSE > "$LIC/onnxruntime/LICENSE"
  [ -s "$LIC/onnxruntime/LICENSE" ]
  ios_licenses_crates "$ROOT/app/rust/glitchbox-fx" "$LIC/glitchbox-fx/crates.html"
  ios_licenses_crates "$ROOT/app/rust/glitchbox-burns" "$LIC/glitchbox-burns/crates.html"
  mkdir -p "$LIC/glitchbox"
  cp "$ROOT/LICENSE" "$LIC/glitchbox/LICENSE"
}
