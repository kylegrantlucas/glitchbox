# videobed — agent notes

Reproducible terminal-only glitch/media toolchain (Nix flake) plus `glitch-loop/`, an ffmpeg + FFglitch datamosh piece. README.md has the full platform matrix and reproducibility notes; read it before changing pipelines.

## Layout
- `flake.nix` / `pkgs/` — devShell, ffglitch 0.10.2, ntsc-rs-cli, reactive-vcr, bender-cli (bender-rs, built with bender-rs's own locked nixpkgs for Rust ≥ 1.96; `$BENDER_PRESETS` = its bundled presets), glslviewer-headless (linux).
- `pipelines/` — seeded, content-addressed pipelines (on PATH in the devShell); shared helpers in `pipelines/_lib.sh`.
- `justfile` — `just doctor`, `just chain INPUT SEED`, `just verify-repro INPUT SEED`, per-pipeline recipes (`just bend INPUT SEED --preset F --set id=v`).
- `glitch-loop/` — standalone datamosh loop: `source.jpg` → judder (`filters/judder.filter`) → MPEG-2 forced-MV (`ffgac`) → `ffedit` + `scripts/mv_average_timed.js` → VHS (`filters/vhs2.filter`) → `out/loop_mosh.mp4`. `combine` layers an external video over the tail and cross-moshes (`scripts/mv_layer_mosh.js`). Intermediates go to `glitch-loop/work/`, finals to `glitch-loop/out/` (both gitignored; `out/` holds the owner's finished renders — don't delete).
- `studio/` — Videobed Studio: `VideobedKit/` Swift package (engine + `vbplug` CLI + Swift Testing suite) and `App/` (SwiftUI macOS app; `project.yml` → XcodeGen, generated `.xcodeproj` is gitignored). Plugins live in `plugins/*.json`, chain presets in `presets/chains/`, per-plugin presets in `presets/plugins/<id>/`. Layer cache + devshell env cache + session in `out/studio/`.

## Commands (verified on aarch64-darwin)
- `nix develop` (or direnv `.envrc`: `use flake`).
- `nix develop -c ffmpeg -version` → ffmpeg 8.x (ffmpeg-full).
- `cd glitch-loop && just base` — full 112 s render (slow). Quick smoke without touching finals: `just loop_s=1 work=/tmp/gl out=/tmp/gl base`.
- `cd glitch-loop && just combine VIDEO START LEN OUT_NAME`.
- `nix build .#bender-cli` — source build (~8 min cold); its install check lists settings and round-trips a bundled preset. `nix develop -c bend --seed 42 IN` renders; two runs into separate `VB_OUT_DIR`s are byte-identical.
- `cd studio/VideobedKit && swift test` — engine unit tests (no nix needed).
- `nix develop -c just plug validate|list|render --chain NAME INPUT|clean` — headless CLI; `just studio` builds and opens the app (both strip nix's SDK vars so system Xcode works in the devshell).

## Invariants
- Bit-exactness: all videobed pipeline ffmpeg calls go through `vb_ffmpeg` (bitexact flags are positional — after `-i`). ntsc-rs output is always remuxed; SoX runs with `-D`; ffedit scripts must use seeded PRNG (QuickJS `Math.random()` is unseedable) and read params from `args.params`. `just verify-repro` must stay green.
- glitch-loop is NOT bit-exact-managed (plain ffmpeg/x264); it's an artwork, not a pipeline.
- Studio renders are best-effort reproducible (like glitch-loop), not part of `verify-repro`. Cache keys hash the parent key, plugin manifest, resolved params, file/asset digests, and `flake.lock`; change any of those and downstream layers re-render.
- `pipelines/reactive-vcr` shares its name with the tool and sits first on the devshell PATH; it resolves the real binary past itself (`type -ap`). Don't call bare `reactive-vcr render` from inside it.
- macOS 27.0.1 gotchas in the app: SwiftUI `VideoPlayer` aborts in `_AVKit_SwiftUI` (use the `AVPlayerView` wrapper); `VSplitView` around the player loops AppKit constraint passes and throws; `Slider(step:)` materializes every stop (seed ranges hang the app), so `ParamControl` caps stepped sliders at 1000 stops.
- Plugin-authoring gotchas (all verified): ntsc-rs `version: 1` presets fill missing keys from `legacy_value()`, not `Default` — `analog-pass` defaults mirror that so they reproduce `presets/vhs.json` exactly (enum values are Rust discriminants, not menu order). ffedit's `-sp` JSON rejects floats, so ffedit-script params must be ints (`scripts/mosh.js` uses percents). ffmpeg's frei0r filter wants bools as `y`/`n` (use enum params). frei0r `colorhalftone` renders solid black in this build. `glitch0r`/`pixs0r` use unseeded randomness.
- FFglitch comes only from `pkgs/ffglitch.nix` (never vendor binaries). Darwin uses the upstream prebuilt; x86_64-linux builds from source (unverified, no Linux builder).

## Platform gaps
aarch64-darwin lacks supercollider, csound, glslviewer (`shader-feedback` linux-only), ffmpeg libplacebo. Pipelines refuse with a message rather than fail obscurely.

## Secrets
None.
