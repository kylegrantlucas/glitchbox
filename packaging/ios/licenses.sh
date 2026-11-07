# shellcheck shell=bash
# Sourced by packaging/build.sh: stage ios_licenses -> build/ios/licenses, the
# licence texts of everything linked into the iOS app (assemble_ios copies the
# tree to Toolchain/licenses beside Credits.html, which the app's Licenses view
# shows). The macOS tree differs: no GStreamer, bash, SoX, or jq, FFglitch is
# built from source, ONNX Runtime is the iOS pod, and the Rust crate lists are
# cargo-about over the two in-repo wrapper crates (which pull in ntsc-rs's core,
# bender, reactive-vcr, and burns).

ios_licenses_srcs="ffmpeg x264 frei0r ffglitch-src ffglitch-scripts ntsc-rs bender-rs burns-rs reactive-vcr onnxruntime-c-pod"
ios_licenses_inputs="LICENSE packaging/about.toml packaging/about.hbs app/rust/glitchbox-fx/Cargo.toml app/rust/glitchbox-fx/Cargo.lock app/rust/glitchbox-burns/Cargo.toml app/rust/glitchbox-burns/Cargo.lock"

ios_licenses_crates() { # CRATE-DIR OUT: cargo-about over an in-repo crate
  mkdir -p "$(dirname "$2")"
  (cd "$1" && menv CARGO_HOME="$DL/cargo-home" "$CARGO_ABOUT" generate --locked \
    -c "$PKG/about.toml" -m "$1/Cargo.toml" -o "$2" "$PKG/about.hbs")
}

build_ios_licenses() {
  [ -n "$CARGO_ABOUT" ] || die "ios_licenses: cargo-about not found (cargo install cargo-about --locked --version 0.9.2)"
  local LIC=$IOS/licenses t=$WORK/ios-lic
  rm -rf "$LIC" "$t"
  lic_copy ffmpeg ffmpeg COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md
  lic_copy x264 x264 COPYING
  lic_copy frei0r frei0r COPYING
  lic_copy ffglitch-src ffglitch COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md
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
