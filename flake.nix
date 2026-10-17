{
  description = "videobed — scriptable video/audio glitch pipelines";

  inputs = {
    # Matches the user's registry pin. All recon was verified against this rev.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";

    # Vendored so example glitch scripts are pinned, never fetched at runtime.
    ffglitch-scripts = {
      url = "github:ramiropolla/ffglitch-scripts";
      flake = false;
    };

    # Source for packages.ntsc-rs-cli (Stage 3b).
    ntsc-rs-src = {
      url = "github:valadaptive/ntsc-rs/v0.9.4";
      flake = false;
    };

    # Source for packages.bender-cli. A flake input (not flake = false) so its
    # own nixpkgs pin, which carries the Rust >= 1.96 it requires, is locked too.
    bender-rs.url = "github:kylegrantlucas/bender-rs/v0.2.0";
  };

  # flake-utils rather than flake-parts: this flake composes no modules, so the
  # module system would buy indirection (config/self'/inputs') and pay for it in
  # readability. eachSystem is one function whose body is a plain attrset.
  outputs =
    { self, nixpkgs, flake-utils, ffglitch-scripts, ntsc-rs-src, bender-rs }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

        # ---------------------------------------------------------------------
        # Our own packages
        # ---------------------------------------------------------------------

        # FFglitch. Prebuilt wrap on darwin, source build on linux — upstream's
        # x86_64 prebuilt is a truncated upload. See pkgs/ffglitch.nix.
        ffglitch = pkgs.callPackage ./pkgs/ffglitch.nix { };

        ntsc-rs-cli = pkgs.callPackage ./pkgs/ntsc-rs-cli.nix { inherit ntsc-rs-src; };

        # Built with bender-rs's own nixpkgs (Rust >= 1.96); see pkgs/bender-cli.nix.
        bender-cli = bender-rs.inputs.nixpkgs.legacyPackages.${system}.callPackage ./pkgs/bender-cli.nix {
          bender-src = bender-rs.outPath;
        };

        # x86_64-linux only; see pkgs/glslviewer-headless.nix.
        glslviewer-headless =
          if isDarwin then null else pkgs.callPackage ./pkgs/glslviewer-headless.nix { };

        # Prebuilt release on both platforms; see pkgs/reactive-vcr.nix.
        reactive-vcr = pkgs.callPackage ./pkgs/reactive-vcr.nix { };

        # ---------------------------------------------------------------------
        # nixpkgs fixups
        # ---------------------------------------------------------------------

        # puredata 0.55-2 declares darwin support and is NOT marked broken, but
        # does not build on aarch64-darwin: pd's configure forces
        # -mmacosx-version-min=10.6 while d_soundfile.c calls strnlen (10.7+),
        # and -Werror=unguarded-availability makes that fatal. It is absent from
        # the binary cache, so this only surfaces on a real build. clang is
        # last-wins on the flag, so appending a newer target fixes it.
        # Verified: builds clean, `pd -nogui -batch` runs a patch.
        puredata' =
          if !isDarwin then
            pkgs.puredata
          else
            pkgs.puredata.overrideAttrs (old: {
              env = (old.env or { }) // {
                NIX_CFLAGS_COMPILE =
                  (old.env.NIX_CFLAGS_COMPILE or "") + " -mmacosx-version-min=11.0";
              };
            });

        pythonEnv = pkgs.python3.withPackages (ps: with ps; [
          vapoursynth
          numpy
          pillow
        ]);

        # ---------------------------------------------------------------------
        # Tool sets
        # ---------------------------------------------------------------------
        portableTools = [ puredata' ] ++ (with pkgs; [
          ffmpeg-full # 8.1.2; frei0r+gpl on both, libplacebo linux-only
          frei0r # 2.5.1
          imagemagick # 7.1.2-29
          sox # raw-import round trips for `sonify`
          faust # 2.85.5
          vapoursynth
          pythonEnv
          just # pipeline composition
          shellcheck # pipelines are shell; lint them
          p7zip # ffglitch linux archives
          jq # manifest generation
          bc # glitch-loop/justfile offset math
          coreutils
        ]);

        # Genuinely unavailable on aarch64-darwin. NOT papered over: pipelines
        # that need these refuse to run on Darwin with a clear message.
        #   supercollider 3.13.1  platforms = lib.platforms.linux
        #   csound 7.0.0-beta.10  broken = stdenv.hostPlatform.isDarwin
        #   glslviewer 3.5.2      broken = isDarwin ("never built on
        #                         aarch64-darwin since first introduction")
        linuxOnlyTools = with pkgs; [
          supercollider
          csound
          glslviewer # OSC compiled in unconditionally (vendored deps/liblo)
          xvfb-run # --headless is a *hidden window*, still needs a display
        ];

        ourTools = [ ffglitch ntsc-rs-cli reactive-vcr bender-cli ]
          ++ lib.optionals (!isDarwin) [ glslviewer-headless ];

        capabilityBanner = ''
          videobed devshell — ${system}

            ffmpeg-full ${pkgs.ffmpeg-full.version}   frei0r  imagemagick  sox
            vapoursynth ${pkgs.vapoursynth.version}   puredata  faust  python ${pkgs.python3.version}
        '' + (if isDarwin then ''
            ffglitch ${ffglitch.version}  (ffgac ffedit fflive qjs)
            reactive-vcr ${reactive-vcr.version}  (audio-reactive ntsc-rs, prebuilt release)
            bender ${bender-cli.version}  (circuit-bent video hardware, bender-rs)

            unavailable on aarch64-darwin (upstream, not a config choice):
              supercollider  platforms = linux
              csound         broken = isDarwin
              glslviewer     broken = isDarwin  -> `shader-feedback` is linux-only
              ffmpeg libplacebo/vulkan  disabled by nixpkgs on darwin
        '' else ''
            linux extras: supercollider  csound  glslviewer(+xvfb)  ffmpeg libplacebo

            ffglitch ${ffglitch.version}  (built from source — upstream's x86_64
            prebuilt is a truncated upload; 0.9.4 predates -sp)
            reactive-vcr ${reactive-vcr.version}  (audio-reactive ntsc-rs, prebuilt release)
            bender ${bender-cli.version}  (circuit-bent video hardware, bender-rs)
        '');
      in
      {
        packages = {
          inherit ffglitch ntsc-rs-cli reactive-vcr bender-cli;
          default = ffglitch;
        } // lib.optionalAttrs (!isDarwin) { inherit glslviewer-headless; };

        apps = lib.genAttrs [ "ffgac" "ffedit" "fflive" ] (bin: {
          type = "app";
          program = "${ffglitch}/bin/${bin}";
        }) // {
          ntsc-rs-cli = {
            type = "app";
            program = "${ntsc-rs-cli}/bin/ntsc-rs-cli";
          };
          reactive-vcr = {
            type = "app";
            program = "${reactive-vcr}/bin/reactive-vcr";
          };
          bender = {
            type = "app";
            program = "${bender-cli}/bin/bender";
          };
        };

        devShells.default = pkgs.mkShell {
          name = "videobed";

          packages = portableTools ++ ourTools
            ++ lib.optionals (!isDarwin) linuxOnlyTools;

          # ffmpeg searches $FREI0R_PATH, ~/.frei0r-1/lib, /usr/local/lib/frei0r-1,
          # /usr/lib/frei0r-1. On Nix none of the fallbacks exist, so without this
          # the frei0r filter is compiled in but resolves zero plugins.
          FREI0R_PATH = "${pkgs.frei0r}/lib/frei0r-1";

          # Pinned flake input; pipelines read scripts from here, never the network.
          FFGLITCH_SCRIPTS = "${ffglitch-scripts}";

          # bender-rs's bundled presets, pinned with the binary.
          BENDER_PRESETS = "${bender-cli}/share/bender/presets";

          VIDEOBED_PLATFORM = system;

          shellHook = ''
            export VIDEOBED_ROOT="$PWD"
            export PATH="$PWD/pipelines:$PATH"
            printf '%s\n' ${lib.escapeShellArg capabilityBanner}
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
