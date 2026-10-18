<p align="center">
  <img src="site/assets/icon/icon-512.png" width="128" height="128" alt="Glitchbox icon: a white cube sliced by glitch on VCR blue">
</p>

<h1 align="center">Glitchbox</h1>

<p align="center">Break video on purpose.</p>

<p align="center">
  <img src="site/assets/demos/stack.jpg" width="720" alt="A gradient after four Glitchbox layers: row shift, MPEG-2 mosh, analog pass, and VHS filter">
</p>

Glitchbox is a Mac app for wrecking video in ways that look intentional. Stack
datamosh, VHS tape damage, circuit-bent video hardware, and pixel-level effects
into a chain, turn the knobs on each layer, and watch the result in the built-in
player. Every tool it runs ships inside the app, so there's no Homebrew setup and
no FFmpeg fork to compile.

**[Download Glitchbox for macOS](https://github.com/kylegrantlucas/glitchbox/releases/latest)** · Apple silicon, macOS 26 or later

## What it does

### Effects in layers

A chain is a stack of layers, and every layer is one effect with its own
controls. Add, reorder, switch off, and remove layers, then render. Preview mode
renders a short slice at a size and frame rate you pick, and Full renders the
whole clip at its own resolution.

### Only the part you changed renders again

Every layer's output is cached. Nudge a slider on the third layer and Glitchbox
re-renders that layer and the ones below it, while everything above comes
straight from the cache. Layers hand each other lossless FFV1 video, so stacking
them adds no extra compression in between.

### Presets for chains and for single effects

Save a whole stack as a chain preset, or save one layer's settings as a preset
for that effect. Two effects come with presets: the MPEG-2 mosh has long smear,
pan drift, and sink and rise, and the circuit-bend effect brings every preset
that ships with bender. If you edit a built-in preset, your copy replaces it
until you revert it.

### Your own effects

An effect is a small JSON file that declares its parameters and the commands to
run, and Glitchbox builds the controls from it. Write one in the app's plugin
editor or by hand. Steps can call any of the bundled tools, and a step can be a
whole bash script that gets every parameter as a variable.

### A command line, too

The app carries a `glitchbox` command that uses the same engine, effects, and
cache, so a chain you saved in the app renders headless:

```sh
glitchbox render --chain analog-mosh-vhs --duration 3 --height 240 clip.mp4
```

## The effects

Every clip below is a real Glitchbox render of one of ffmpeg's built-in test
generators.

| | | |
|:---:|:---:|:---:|
| <img src="site/assets/demos/vhs-bars.jpg" width="240" alt="SMPTE bars after analog-pass"><br>VHS dub (analog pass) | <img src="site/assets/demos/mosh-bands.jpg" width="240" alt="Gradient bands after MPEG-2 mosh"><br>Long smear (MPEG-2 mosh) | <img src="site/assets/demos/mv-zoom.jpg" width="240" alt="Mandelbrot zoom after an MV script"><br>Zoom in, zoom out (MV script) |
| <img src="site/assets/demos/bend-life.jpg" width="240" alt="Game of Life after circuit bend"><br>Rolling tear (circuit bend) | <img src="site/assets/demos/smear-testcard.jpg" width="240" alt="Test card after pixel smear and RGB split"><br>Smeared test card (pixel smear, RGB split) | <img src="site/assets/demos/reactive-pulse.jpg" width="240" alt="Pulsing disc after Reactive VCR"><br>Kick drum on the tracking (Reactive VCR) |

Nineteen effects come built in.

### Datamosh

MPEG-2 Mosh encodes your clip with forced motion vectors and then smears them,
with an averaging window, separate horizontal and vertical scale, and drift. MV
Script runs the deterministic DD-GlitchAssist scripts on the same encode, and MV
Mangle shuffles MPEG-4 motion vectors from a seed. All three run on
[FFglitch](https://ffglitch.org).

### Analog video

Analog Pass is a full NTSC and VHS simulation from
[ntsc-rs](https://github.com/valadaptive/ntsc-rs), with every one of its settings
exposed. Reactive VCR drives those artifacts from audio, either the clip's own
soundtrack or a file you choose. Its default mapping lets the bass push tracking
noise and sharp hits trigger head switching. VHS Filter is a lighter ffmpeg take
with levels, misregistration, noise, softness, and vignette.

### Circuit bending

Circuit Bend runs your clip through emulated video hardware from
[bender-rs](https://github.com/kylegrantlucas/bender-rs): camera sensor, tape,
frame store, colour encoder, monitor, and feedback loop. Any stage can be broken
the way a stray wire would break it, and you can put the stages in a different
order.

### Pixel effects

RGB Split, Pixel Smear (pixel-sort-style streaks), Pixelate, Bitcrush, Trails,
Frame Blend, and Datascope come from ffmpeg. Block Glitch, Row Shift, Plasma
Distort, Kaleidoscope, and Vertigo come from frei0r.

## Install

Download `Glitchbox-<version>.dmg` from
[Releases](https://github.com/kylegrantlucas/glitchbox/releases/latest), open it,
and drag Glitchbox to Applications. It needs a Mac with Apple silicon and macOS
26 or later, and takes about 195 MB on disk.

Glitchbox isn't notarized yet, so macOS blocks the first launch. Open System
Settings → Privacy & Security and click Open Anyway, or clear the quarantine flag
in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Glitchbox.app
```

## Built on

Glitchbox runs these projects, all of which ship inside the app:
[FFglitch](https://ffglitch.org) and
[ffglitch-scripts](https://github.com/ramiropolla/ffglitch-scripts),
[ntsc-rs](https://github.com/valadaptive/ntsc-rs),
[bender-rs](https://github.com/kylegrantlucas/bender-rs),
[reactive-vcr](https://github.com/kylegrantlucas/reactive-vcr),
[FFmpeg](https://ffmpeg.org),
[x264](https://www.videolan.org/developers/x264.html),
[frei0r](https://frei0r.dyne.org),
[GStreamer](https://gstreamer.freedesktop.org),
[SoX](https://sourceforge.net/projects/sox/),
[jq](https://jqlang.org), and
[bash](https://www.gnu.org/software/bash/).
