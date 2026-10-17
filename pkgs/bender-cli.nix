# bender-cli — circuit-bent video hardware emulation (`bender`), headless.
#
# Not in nixpkgs and upstream ships no flake package, so we build the
# `bender-cli` crate from the pinned source. bender-rs needs Rust >= 1.96, newer
# than this flake's nixpkgs (1.95), so flake.nix calls this with bender-rs's own
# locked nixpkgs: the toolchain and GStreamer upstream CI builds against.
{ lib
, stdenv
, rustPlatform
, bender-src
, pkg-config
, makeWrapper
, glib
, gst_all_1
, libiconv
}:

let
  version = "0.2.0";

  # Loaded dynamically at runtime: decodebin's demuxers/decoders, avenc_ffv1
  # (libav), x264enc (ugly), matroskamux/mp4mux/flacenc (good). Without
  # GST_PLUGIN_PATH the binary builds fine and fails on first render.
  gstPlugins = with gst_all_1; [
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
  ];
in
rustPlatform.buildRustPackage {
  pname = "bender-cli";
  inherit version;

  src = bender-src;
  cargoLock.lockFile = "${bender-src}/Cargo.lock";

  cargoBuildFlags = [ "-p" "bender-cli" ];
  # The effect core's tests are pure Rust; the GUI and wasm crates are not built.
  cargoTestFlags = [ "-p" "bender" ];

  nativeBuildInputs = [ pkg-config makeWrapper ];
  buildInputs = [ glib gst_all_1.gstreamer gst_all_1.gst-plugins-base ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ libiconv ];

  postInstall = ''
    wrapProgram $out/bin/bender \
      --prefix GST_PLUGIN_PATH : "${lib.makeSearchPath "lib/gstreamer-1.0" gstPlugins}"
    mkdir -p $out/share/bender
    cp -r ${bender-src}/presets $out/share/bender/presets
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/bender --list-settings > settings.txt
    grep -q '^sync.enabled' settings.txt || { echo "FAIL: --list-settings lacks sync.enabled"; exit 1; }
    $out/bin/bender --preset $out/share/bender/presets/meltdown.json --dump-preset > dump.json
    grep -q '"version"' dump.json || { echo "FAIL: --dump-preset produced no preset"; exit 1; }
    echo "installCheck OK: bender lists settings and round-trips a bundled preset"
    runHook postInstallCheck
  '';

  meta = {
    description = "Circuit-bent video hardware, emulated (bender CLI)";
    homepage = "https://github.com/kylegrantlucas/bender-rs";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "bender";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
  };
}
