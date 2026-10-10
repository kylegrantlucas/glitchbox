# ntsc-rs-cli — analog/NTSC artifact simulation, headless.
#
# Not in nixpkgs. There is no `ntsc-rs-cli` crate: the CLI is a [[bin]] target
# inside the `ntsc-rs-gui` crate, so eframe/egui compile whether we want them or
# not. Accepted — the alternative is extracting it from a 147 MB macOS .pkg.
#
# Upstream ships a clean standalone Linux CLI but only a .pkg for macOS, so a
# source build is the one strategy that works identically on both platforms.
{ lib
, stdenv
, rustPlatform
, ntsc-rs-src
, pkg-config
, makeWrapper
, cmake
, glib
, gst_all_1
}:

let
  version = "0.9.4";

  # Plugins ntsc-rs needs at RUNTIME to demux/decode/encode. The binary links
  # only against core gstreamer; everything else is loaded dynamically, so
  # without GST_PLUGIN_PATH the CLI builds fine and then fails at first use with
  # an opaque "no decoder" error.
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
  pname = "ntsc-rs-cli";
  inherit version;

  src = ntsc-rs-src;

  cargoLock = {
    lockFile = "${ntsc-rs-src}/Cargo.lock";
    # importCargoLock vendors every git source in the lock, including ones only
    # the After Effects plugin uses, so both need hashes even though we build
    # neither.
    outputHashes = {
      "fontique-0.3.0" = "sha256-rDMhY/EaMsWwXnH7SYTLzJMucNUUYIoWx+jFPUafRIc=";
      "after-effects-0.3.0" = "sha256-ILfSDXeNYEhOIie3rELeUBRxuKIFOy58MKsqSSEm43E=";
    };
  };

  # The workspace package is `ntsc-rs-gui`, not `gui`.
  cargoBuildFlags = [ "-p" "ntsc-rs-gui" "--bin" "ntsc-rs-cli" ];

  nativeBuildInputs = [ pkg-config makeWrapper cmake ];
  buildInputs = [ glib gst_all_1.gstreamer gst_all_1.gst-plugins-base ];

  # Workspace tests pull in the GUI and OpenFX crates (the latter needs a git
  # submodule we do not fetch). Nothing here is worth that.
  doCheck = false;

  # buildRustPackage installs every bin the package produces; we only want the CLI.
  postInstall = ''
    rm -f $out/bin/ntsc-rs-standalone $out/bin/ntsc-rs-launcher
    wrapProgram $out/bin/ntsc-rs-cli \
      --prefix GST_PLUGIN_PATH : "${lib.makeSearchPath "lib/gstreamer-1.0" gstPlugins}"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/ntsc-rs-cli --help > help.txt 2>&1 || true
    grep -q -- '--settings-path' help.txt || { echo "FAIL: --settings-path missing"; exit 1; }
    grep -q -- '--codec'         help.txt || { echo "FAIL: --codec missing"; exit 1; }
    echo "installCheck OK: ntsc-rs-cli runs, preset and codec flags present"
    runHook postInstallCheck
  '';

  meta = {
    description = "Command-line NTSC/VHS analog artifact simulation";
    homepage = "https://github.com/valadaptive/ntsc-rs";
    license = lib.licenses.gpl3Only;
    mainProgram = "ntsc-rs-cli";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
  };
}
