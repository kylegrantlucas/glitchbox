# videobed — agent notes

Reproducible terminal-only glitch/media toolchain (Nix flake) plus `glitch-loop/`, an ffmpeg + FFglitch datamosh piece. README.md has the full platform matrix and reproducibility notes; read it before changing pipelines.

## Layout
- `flake.nix` / `pkgs/` — devShell, ffglitch 0.10.2, ntsc-rs-cli, reactive-vcr, glslviewer-headless (linux).
- `pipelines/` — seeded, content-addressed pipelines (on PATH in the devShell); shared helpers in `pipelines/_lib.sh`.
- `justfile` — `just doctor`, `just chain INPUT SEED`, `just verify-repro INPUT SEED`.
- `glitch-loop/` — standalone datamosh loop: `source.jpg` → judder (`filters/judder.filter`) → MPEG-2 forced-MV (`ffgac`) → `ffedit` + `scripts/mv_average_timed.js` → VHS (`filters/vhs2.filter`) → `out/loop_mosh.mp4`. `combine` layers an external video over the tail and cross-moshes (`scripts/mv_layer_mosh.js`). Intermediates go to `glitch-loop/work/`, finals to `glitch-loop/out/` (both gitignored; `out/` holds the owner's finished renders — don't delete).

## Commands (verified on aarch64-darwin)
- `nix develop` (or direnv `.envrc`: `use flake`).
- `nix develop -c ffmpeg -version` → ffmpeg 8.x (ffmpeg-full).
- `cd glitch-loop && just base` — full 112 s render (slow). Quick smoke without touching finals: `just loop_s=1 work=/tmp/gl out=/tmp/gl base`.
- `cd glitch-loop && just combine VIDEO START LEN OUT_NAME`.

## Invariants
- Bit-exactness: all videobed pipeline ffmpeg calls go through `vb_ffmpeg` (bitexact flags are positional — after `-i`). ntsc-rs output is always remuxed; SoX runs with `-D`; ffedit scripts must use seeded PRNG (QuickJS `Math.random()` is unseedable) and read params from `args.params`. `just verify-repro` must stay green.
- glitch-loop is NOT bit-exact-managed (plain ffmpeg/x264); it's an artwork, not a pipeline.
- FFglitch comes only from `pkgs/ffglitch.nix` (never vendor binaries). Darwin uses the upstream prebuilt; x86_64-linux builds from source (unverified, no Linux builder).

## Platform gaps
aarch64-darwin lacks supercollider, csound, glslviewer (`shader-feedback` linux-only), ffmpeg libplacebo. Pipelines refuse with a message rather than fail obscurely.

## Secrets
None.
