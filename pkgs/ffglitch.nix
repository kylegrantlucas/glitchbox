# FFglitch — ffgac / ffedit / fflive / qjs, from ramiropolla's patched FFmpeg fork.
# Not in nixpkgs. Two very different strategies per platform; see below.
{ lib
, stdenv
, fetchurl
, unzip
, buildPackages
, pkg-config
, perl
, nasm
, zlib
}:

let
  version = "0.10.2";

  # ---------------------------------------------------------------------------
  # aarch64-darwin: wrap upstream's prebuilt. Verified against the real artifact:
  #   * Mach-O 64-bit arm64
  #   * `otool -L` lists ONLY /System/Library/Frameworks/* and /usr/lib/* —
  #     no third-party dylibs, so there is nothing for fixup to do.
  #   * `codesign -dvvv` reports "adhoc, linker-signed"; still valid after the
  #     store copy.
  #   * ffgac exposes forcemv/nopimb under -mpv_flags; ffedit exposes -sp and -t.
  # ---------------------------------------------------------------------------
  prebuiltDarwin = stdenv.mkDerivation {
    pname = "ffglitch";
    inherit version;

    src = fetchurl {
      url = "https://ffglitch.org/pub/bin/macos-aarch64/ffglitch-${version}-macos-aarch64.zip";
      hash = "sha256-JaWn1RIXkZ21oJOyEf2KHieEUoTvsKb2FrjzcfZjju8=";
    };

    nativeBuildInputs = [ unzip ];

    # Load-bearing, not cargo-cult. The binaries carry an ad-hoc *linker-signed*
    # signature sealing their own contents. Nix's default strip/fixup would
    # rewrite them and invalidate it, after which the Apple Silicon kernel
    # refuses to exec the file — presenting as "killed: 9", which reads like a
    # corrupt download rather than a packaging bug.
    dontStrip = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m555 ffgac ffedit fflive qjs $out/bin/
      install -Dm444 readme.txt $out/share/doc/ffglitch/readme.txt
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      for b in ffgac ffedit fflive; do
        $out/bin/$b -version >/dev/null || { echo "FAIL: $b did not execute"; exit 1; }
      done

      # NB: capture to files rather than piping into `grep -q`. stdenv runs with
      # `set -o pipefail`, and `grep -q` exits on first match, closing the pipe
      # and killing the producer with SIGPIPE (141) — which pipefail then reports
      # as a failed pipeline even though the match succeeded.
      $out/bin/ffgac -h full > gac-help.txt 2>&1 || true
      $out/bin/ffedit -h     > edit-help.txt 2>&1 || true

      grep -q forcemv gac-help.txt || { echo "FAIL: -mpv_flags forcemv missing"; exit 1; }
      grep -q nopimb  gac-help.txt || { echo "FAIL: -mpv_flags nopimb missing"; exit 1; }
      grep -q 'setup() parameters' edit-help.txt || { echo "FAIL: ffedit -sp missing"; exit 1; }

      echo "installCheck OK: ffgac/ffedit/fflive execute; forcemv, nopimb, -sp present"
      runHook postInstallCheck
    '';
  };

  # ---------------------------------------------------------------------------
  # x86_64-linux: build from source.
  #
  # Upstream's 0.10.2 prebuilt for this platform is UNUSABLE — the server returns
  # 12,011,520 bytes with a matching Content-Length, but the 7z start header
  # declares nextHeaderOffset+size requiring 27,374,756 (15,363,236 short) and
  # NextHeaderCRC does not verify. It is a half-finished upload. The intact
  # 0.9.4 build is not a fallback either: it predates `-sp`, which mv-mangle is
  # parameterized on (confirmed by string-inspecting the binary).
  #
  # The tarball is a normal FFmpeg tree plus an ffglitch/ dir, with QuickJS
  # vendored at libavutil/quickjs — so no external deps beyond zlib.
  # ---------------------------------------------------------------------------
  fromSource = stdenv.mkDerivation {
    pname = "ffglitch";
    inherit version;

    src = fetchurl {
      url = "https://ffglitch.org/pub/src/ffglitch-${version}.tar.xz";
      hash = "sha256-euy71M4bBChG5DA4votMqxZhZQUnnVMQ0z0WqkJbpG4=";
    };

    nativeBuildInputs = [ pkg-config perl nasm ];
    buildInputs = [ zlib ];

    strictDeps = true;
    enableParallelBuilding = true;

    # FFmpeg's configure is hand-written, not autoconf: it rejects --build/--host
    # and most of the output flags stdenv would otherwise pass.
    configurePlatforms = [ ];
    setOutputFlags = false;

    configureFlags = [
      "--target_os=${stdenv.hostPlatform.parsed.kernel.name}"
      "--arch=${stdenv.hostPlatform.parsed.cpu.name}"
      "--pkg-config=${buildPackages.pkg-config.targetPrefix}pkg-config"
      "--disable-doc"
      "--disable-autodetect" # match upstream's own build; no surprise deps
      "--enable-gpl" # required for geq and friends
      "--enable-zlib"
      "--enable-static"
      "--disable-shared"
    ];

    # `all` builds ffgac and fflive (fftools/Makefile copies them from ffmpeg_g
    # and ffplay_g). qjs has rules in libavutil/Makefile:388 but is deliberately
    # NOT part of `all`, so ask for it explicitly.
    buildFlags = [ "all" "qjs" ];

    # Deliberately not `make install`. Two reasons:
    #  1. fftools/Makefile's install-progs installs only $(AVPROGS) — ffmpeg,
    #     ffplay, ffprobe, ffedit. ffgac and fflive are built but never installed.
    #  2. We do NOT want this derivation shipping its own `ffmpeg`/`ffprobe`,
    #     which would shadow ffmpeg-full on the devshell PATH. Installing exactly
    #     the four FFglitch binaries keeps parity with the Darwin prebuilt.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m555 ffgac ffedit fflive qjs $out/bin/
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      for b in ffgac ffedit fflive; do
        $out/bin/$b -version >/dev/null || { echo "FAIL: $b did not execute"; exit 1; }
      done
      $out/bin/ffgac -h full > gac-help.txt 2>&1 || true
      $out/bin/ffedit -h     > edit-help.txt 2>&1 || true
      grep -q forcemv gac-help.txt || { echo "FAIL: -mpv_flags forcemv missing"; exit 1; }
      grep -q nopimb  gac-help.txt || { echo "FAIL: -mpv_flags nopimb missing"; exit 1; }
      grep -q 'setup() parameters' edit-help.txt || { echo "FAIL: ffedit -sp missing"; exit 1; }
      echo "installCheck OK: ffgac/ffedit/fflive execute; forcemv, nopimb, -sp present"
      runHook postInstallCheck
    '';
  };

  base = if stdenv.hostPlatform.isDarwin then prebuiltDarwin else fromSource;
in
base.overrideAttrs (old: {
  meta = {
    description = "Multimedia bitstream editor based on a patched FFmpeg fork";
    homepage = "https://ffglitch.org";
    license = lib.licenses.gpl2Plus;
    mainProgram = "ffgac";
    platforms = [ "aarch64-darwin" "x86_64-linux" ];
    sourceProvenance =
      if stdenv.hostPlatform.isDarwin then
        with lib.sourceTypes; [ binaryNativeCode ]
      else
        with lib.sourceTypes; [ fromSource ];
  };
})
