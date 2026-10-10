# videobed

Reproducible, terminal-only environment for scriptable video/audio glitch
pipelines. Every run is content-addressed and emits a manifest recording the
input digest, every resolved parameter, tool versions, and locked flake input
revisions — so an artifact can be regenerated exactly.

```sh
nix develop
just doctor                       # what works on this platform
just chain input.mkv 42           # analog-pass -> mv-mangle -> encode
just verify-repro input.mkv 42    # assert every stage is byte-reproducible
```

## Platform matrix

Verified against nixpkgs `nixos-26.05` @ `062346a6`.

| | aarch64-darwin | x86_64-linux |
|---|---|---|
| `mv-mangle` (FFglitch) | prebuilt wrap | built from source |
| `analog-pass` (ntsc-rs) | source build | source build |
| `reactive-vcr` (ntsc-rs core, audio-reactive) | prebuilt release | prebuilt release |
| `sonify` (SoX) | yes | yes |
| `shader-feedback` (glslViewer) | **no** | yes, via `xvfb-run` |
| ffmpeg frei0r / geq / lagfun / tblend / datascope | yes | yes |
| ffmpeg libplacebo | **no** (disabled upstream) | yes |
| SuperCollider, Csound | **no** | yes |

Darwin gaps are upstream facts, not configuration choices:
`csound` has `broken = isDarwin`; `supercollider` is `platforms = linux`;
`glslviewer` is `broken = isDarwin` ("never built on aarch64-darwin since first
introduction"). Pipelines needing them refuse to run with an explanation rather
than failing obscurely.

## Reproducibility notes

These were all found by testing, and each one silently breaks reproducibility
while still producing plausible-looking output:

- **ffmpeg bitexact flags are positional.** `-fflags +bitexact` before `-i`
  binds to the *input* context and does nothing for output determinism; two runs
  then differ by 43 bytes (Matroska random `SegmentUID` + `DateUTC`). All ffmpeg
  calls go through `vb_ffmpeg` in `pipelines/_lib.sh`, which places them
  correctly by construction.
- **ntsc-rs renders deterministically but muxes nondeterministically.** Identical
  `random_seed` gives identical pixels (verified via `framemd5`) inside a
  container that differs by 28 bytes per run. `analog-pass` therefore always
  remuxes through `vb_ffmpeg` with a stream copy — lossless, and deterministic.
- **SoX auto-dithers, and its dither is unseedable.** `sonify` passes `-D`.
  Without it, two identical runs differ every time.
- **QuickJS cannot seed `Math.random()`.** `scripts/mv-shuffle.js` uses an
  explicit xorshift32 seeded from `-sp`. Vendored upstream scripts in
  `$FFGLITCH_SCRIPTS` that call `Math.random()` are *not* reproducible.
- **ffedit takes `-sp` params under `args.params`**, not as top-level keys on
  `args`. Reading `args.seed` silently yields `undefined` and pins every run to
  the default seed while the manifest claims otherwise.

`just verify-repro` runs a chain twice into separate trees and reports
per-stage, so a regression names the stage that lost determinism.

## Layout

```
flake.nix              devShells / packages / apps, flake-utils
pkgs/                  ffglitch, ntsc-rs-cli, glslviewer-headless
pipelines/_lib.sh      guards, vb_ffmpeg, run IDs, manifests
pipelines/*            mv-mangle, analog-pass, reactive-vcr, sonify, shader-feedback
scripts/mv-shuffle.js  seeded ffedit motion-vector script
presets/vhs.json       ntsc-rs effect preset
presets/reactive-vcr.toml  audio-reactive mapping for [reactive-vcr](https://kylegrantlucas.github.io/reactive-vcr/)
shaders/feedback.frag  default shader for shader-feedback
out/                   gitignored artifacts, one dir per content-addressed run
```

Each pipeline documents its own knobs in its header; `<pipeline> --help` prints
them.

## Known gaps

- The `x86_64-linux` FFglitch derivation builds from source and has **not** been
  built on a Linux host — this machine has no remote Linux builder. It
  instantiates and its `installCheckPhase` asserts `forcemv`, `nopimb`, and `-sp`
  before it will install, so it fails loudly rather than shipping broken.
  Upstream's 0.10.2 x86_64 prebuilt is a truncated upload (12,011,520 bytes
  served, 27,374,756 required, bad `NextHeaderCRC`), and 0.9.4 predates `-sp`.
- `shader-feedback` is likewise unverified — glslViewer does not run on Darwin.
- `reactive-vcr`'s x86_64-linux package (fetch + `autoPatchelfHook`) has not been
  built on a Linux host either, for the same reason as FFglitch above — no
  remote Linux builder on this machine. Lower risk than FFglitch's from-source
  build (`patchelf --print-needed` shows only libc/libm/libgcc_s, all stock),
  but unverified is unverified.
