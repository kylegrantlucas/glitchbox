# reactive-vcr — audio-reactive ntsc-rs VHS/NTSC rendering.
# https://github.com/kylegrantlucas/reactive-vcr / https://kylegrantlucas.github.io/reactive-vcr/
#
# Not in nixpkgs. Upstream ships a clean prebuilt per platform (both aarch64-darwin
# and x86_64-linux — no truncated-upload or missing-flag problems like ffglitch),
# so this wraps the release archive directly rather than building from source.
{ lib
, stdenv
, fetchurl
, autoPatchelfHook
}:

let
  version = "0.1.0";

  # Verified against the archives' own published SHA256SUMS at this tag.
  srcs = {
    aarch64-darwin = fetchurl {
      url = "https://github.com/kylegrantlucas/reactive-vcr/releases/download/v${version}/reactive-vcr-v${version}-aarch64-apple-darwin.tar.gz";
      hash = "sha256-R4IJuwcep9GDWhdWhE+6ZoeJLuE8Z0nkHaYwG/Bh6c0=";
    };
    x86_64-linux = fetchurl {
      url = "https://github.com/kylegrantlucas/reactive-vcr/releases/download/v${version}/reactive-vcr-v${version}-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-a3wBgGJTdd05UIk2lSwFCcwnqrMgf1mzOnmE4OPoahQ=";
    };
  };
in
stdenv.mkDerivation {
  pname = "reactive-vcr";
  inherit version;

  src = srcs.${stdenv.hostPlatform.system}
    or (throw "reactive-vcr: no prebuilt release for ${stdenv.hostPlatform.system}");

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  # Only libc/libm/libgcc_s per `patchelf --print-needed`; all covered by stdenv.
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  # Darwin binary carries an ad-hoc *linker-signed* signature (same situation as
  # pkgs/ffglitch.nix's prebuiltDarwin). Nix's default strip/fixup rewrites the
  # binary and invalidates that signature, after which it won't exec.
  dontStrip = stdenv.hostPlatform.isDarwin;
  dontFixup = stdenv.hostPlatform.isDarwin;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m555 reactive-vcr $out/bin/reactive-vcr
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/reactive-vcr --version >/dev/null || { echo "FAIL: reactive-vcr did not execute"; exit 1; }
    $out/bin/reactive-vcr --help > help.txt 2>&1 || true
    for cmd in render analyze params; do
      grep -q "  $cmd" help.txt || { echo "FAIL: '$cmd' subcommand missing"; exit 1; }
    done
    echo "installCheck OK: reactive-vcr executes; render/analyze/params present"
    runHook postInstallCheck
  '';

  meta = {
    description = "Audio-reactive VHS/NTSC effect renderer built on the ntsc-rs core";
    homepage = "https://kylegrantlucas.github.io/reactive-vcr/";
    license = lib.licenses.mit;
    mainProgram = "reactive-vcr";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
