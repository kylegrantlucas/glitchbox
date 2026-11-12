//! Drives each wrapper exactly as its macOS CLI drives the core and compares
//! the result with that CLI's real output.
//!
//! The oracles are the tools in a built macOS toolchain (`build.sh tools` /
//! `just app`): `$GLITCHBOX_TOOLCHAIN` (a `Contents` directory), else this
//! checkout's `build/Glitchbox.app/Contents`. These tests are `#[ignore]`d so
//! a plain `cargo test` runs without one; run them with
//! `cargo test -- --include-ignored --nocapture`.
//!
//! Inputs are RGB FFV1 (bgr0) so every decoder hands the effects identical
//! pixels; what is left between the two sides is the CLIs' GStreamer
//! RGB->YUV conversion versus ffmpeg's, so the checks are PSNR floors on the
//! encoded outputs plus exact or near-exact checks where the CLI can write RGB
//! (ntsc-rs-cli's PNG sequence).

use glitchbox_fx::{Bender, Ntsc, Reactive, pts_frame_index, reactive};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const W: usize = 192;
const H: usize = 144;
const FPS: i32 = 30;
const SECONDS: &str = "1";

struct Oracle {
    contents: PathBuf,
    dir: PathBuf,
}

impl Oracle {
    fn new(name: &str) -> Self {
        let contents = std::env::var_os("GLITCHBOX_TOOLCHAIN").map(PathBuf::from).unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../build/Glitchbox.app/Contents")
        });
        assert!(
            contents.join("Helpers/ntsc-rs-cli").is_file(),
            "no macOS toolchain at {} (set GLITCHBOX_TOOLCHAIN to a Glitchbox.app/Contents)",
            contents.display()
        );
        let dir = std::env::temp_dir().join(format!("glitchbox-fx-oracle-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let o = Self { contents, dir };
        o.make_clip();
        o
    }

    fn tool(&self, name: &str) -> Command {
        let mut c = Command::new(self.contents.join("Helpers").join(name));
        c.env_clear()
            .env("HOME", &self.dir)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env(
                "GST_PLUGIN_SYSTEM_PATH",
                self.contents.join("Frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"),
            )
            .env("GST_REGISTRY", self.dir.join("gst-registry.bin"))
            .current_dir(&self.dir);
        c
    }

    fn run(&self, name: &str, args: &[&str]) -> Vec<u8> {
        let out = self.tool(name).args(args).stdin(Stdio::null()).output().unwrap();
        assert!(
            out.status.success(),
            "{name} {args:?} failed: {}\n{}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        );
        out.stdout
    }

    fn path(&self, name: &str) -> String {
        self.dir.join(name).to_string_lossy().into_owned()
    }

    fn library(&self, rel: &str) -> PathBuf {
        self.contents.join("Resources").join(rel)
    }

    /// Moving pattern plus an audio track with level changes and onsets.
    fn make_clip(&self) {
        let video = format!("testsrc2=s={W}x{H}:r={FPS}:d={SECONDS}");
        let audio = format!(
            "aevalsrc='0.8*sin(2*PI*110*t)*(0.5+0.5*sin(2*PI*3*t))+0.6*(random(0)-0.5)*gt(mod(t\\,0.25)\\,0.2)':s=48000:d={SECONDS}"
        );
        let clip = self.path("in.mkv");
        self.run(
            "ffmpeg",
            &[
                "-v", "error", "-y", "-f", "lavfi", "-i", &video, "-f", "lavfi", "-i", &audio, "-c:v", "ffv1",
                "-pix_fmt", "bgr0", "-c:a", "pcm_s16le", "-ac", "1", &clip,
            ],
        );
    }

    /// Video frames of `file` as packed rgb24 (ffmpeg decode, the file's own colour tags).
    fn rgb24_frames(&self, file: &str) -> Vec<Vec<u8>> {
        let raw = self.run("ffmpeg", &["-v", "error", "-i", file, "-map", "0:v", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]);
        split(raw, W * H * 3)
    }

    /// Frame timestamps of `file`'s video in nanoseconds, as a demuxer reports them.
    fn pts_ns(&self, file: &str) -> Vec<u64> {
        let out = self.run(
            "ffprobe",
            &["-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", file],
        );
        String::from_utf8(out)
            .unwrap()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| (l.trim().parse::<f64>().unwrap() * 1e9).round() as u64)
            .collect()
    }

    /// Our packed `pix_fmt` frames converted by swscale the way the host must
    /// stand in for GStreamer's videoconvert: limited-range BT.601 (SD),
    /// chroma sited at the centre and subsampled by box averaging (`area`).
    fn yuv_of_frames(&self, frames: &[Vec<u8>], pix_fmt: &str, yuv: &str) -> Vec<Vec<u8>> {
        let input = self.path(&format!("ours-{pix_fmt}-{yuv}.raw"));
        std::fs::write(&input, frames.concat()).unwrap();
        let size = format!("{W}x{H}");
        let vf = format!(
            "scale=out_color_matrix=bt601:out_range=tv:out_chroma_loc=center:flags=area+accurate_rnd+full_chroma_int,format={yuv}"
        );
        let raw = self.run(
            "ffmpeg",
            &[
                "-v", "error", "-f", "rawvideo", "-pix_fmt", pix_fmt, "-s", &size, "-r", "30", "-i", &input, "-vf",
                &vf, "-f", "rawvideo", "-pix_fmt", yuv, "-",
            ],
        );
        split(raw, yuv_frame_len(yuv))
    }

    /// The CLI's stored `yuv` planes, unconverted.
    fn yuv_of_file(&self, file: &str, yuv: &str) -> Vec<Vec<u8>> {
        let raw = self.run("ffmpeg", &["-v", "error", "-i", file, "-map", "0:v", "-f", "rawvideo", "-pix_fmt", yuv, "-"]);
        split(raw, yuv_frame_len(yuv))
    }

    /// Mono f32 48 kHz samples of `file`'s audio (what reactive-vcr's
    /// audioconvert ! audioresample delivers).
    fn mono_f32(&self, file: &str) -> Vec<f32> {
        let raw = self.run(
            "ffmpeg",
            &["-v", "error", "-i", file, "-map", "0:a", "-ac", "1", "-ar", "48000", "-f", "f32le", "-"],
        );
        raw.chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect()
    }
}

fn yuv_frame_len(yuv: &str) -> usize {
    match yuv {
        "yuv420p" => W * H * 3 / 2,
        "yuv444p" => W * H * 3,
        other => panic!("unsupported {other}"),
    }
}

/// Compares Y and chroma planes separately (chroma carries the subsampling filter's differences).
fn compare_yuv(label: &str, ours: &[Vec<u8>], theirs: &[Vec<u8>]) -> (Report, Report) {
    let y = |f: &[Vec<u8>]| f.iter().map(|p| p[..W * H].to_vec()).collect::<Vec<_>>();
    let c = |f: &[Vec<u8>]| f.iter().map(|p| p[W * H..].to_vec()).collect::<Vec<_>>();
    (
        compare(&format!("{label} Y"), &y(ours), &y(theirs)),
        compare(&format!("{label} CbCr"), &c(ours), &c(theirs)),
    )
}

fn split(raw: Vec<u8>, frame: usize) -> Vec<Vec<u8>> {
    assert_eq!(raw.len() % frame, 0, "raw video is not a whole number of frames");
    raw.chunks(frame).map(<[u8]>::to_vec).collect()
}

fn psnr(a: &[u8], b: &[u8]) -> f64 {
    assert_eq!(a.len(), b.len());
    let se: f64 = a.iter().zip(b).map(|(&x, &y)| (f64::from(x) - f64::from(y)).powi(2)).sum();
    if se == 0.0 {
        return f64::INFINITY;
    }
    10.0 * (255.0f64.powi(2) / (se / a.len() as f64)).log10()
}

struct Report {
    frames: usize,
    identical: usize,
    min_psnr: f64,
    max_abs: u8,
}

fn compare(label: &str, ours: &[Vec<u8>], theirs: &[Vec<u8>]) -> Report {
    assert_eq!(ours.len(), theirs.len(), "{label}: frame count (ours vs CLI)");
    let mut r = Report { frames: ours.len(), identical: 0, min_psnr: f64::INFINITY, max_abs: 0 };
    for (i, (a, b)) in ours.iter().zip(theirs).enumerate() {
        let p = psnr(a, b);
        if a == b {
            r.identical += 1;
        }
        r.min_psnr = r.min_psnr.min(p);
        let m = a.iter().zip(b).map(|(&x, &y)| x.abs_diff(y)).max().unwrap_or(0);
        r.max_abs = r.max_abs.max(m);
        if std::env::var_os("GBFX_ORACLE_VERBOSE").is_some() {
            eprintln!("  {label} frame {i}: psnr {p:.2} dB, max |diff| {m}");
        }
    }
    eprintln!(
        "{label}: {} frames, {} identical, min PSNR {:.2} dB, max |diff| {}",
        r.frames, r.identical, r.min_psnr, r.max_abs
    );
    r
}

fn rgb24_to_xrgb16(rgb: &[u8]) -> Vec<u16> {
    // GStreamer's videoconvert widens 8-bit to 16-bit by replication (v * 257).
    rgb.chunks_exact(3)
        .flat_map(|p| [0xffff, u16::from(p[0]) * 257, u16::from(p[1]) * 257, u16::from(p[2]) * 257])
        .collect()
}

fn xrgb16_to_rgb48le(x: &[u16]) -> Vec<u8> {
    x.chunks_exact(4).flat_map(|p| [p[1], p[2], p[3]]).flat_map(u16::to_le_bytes).collect()
}

fn xrgb16_to_rgb24(x: &[u16]) -> Vec<u8> {
    // videoconvert narrows 16-bit to 8-bit by dropping the low byte.
    x.chunks_exact(4).flat_map(|p| [(p[1] >> 8) as u8, (p[2] >> 8) as u8, (p[3] >> 8) as u8]).collect()
}

fn rgb24_to_rgba(rgb: &[u8]) -> Vec<u8> {
    rgb.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 0xff]).collect()
}

fn rgba_to_rgb24(rgba: &[u8]) -> Vec<u8> {
    rgba.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect()
}

/// analog-pass: `ntsc-rs-cli -i IN -o OUT -c ffv1 --chroma-subsampling -y -j SETTINGS`
/// with SETTINGS = presets/vhs.json + random_seed, plus the PNG pass.
#[test]
#[ignore = "needs a built macOS toolchain (GLITCHBOX_TOOLCHAIN)"]
fn ntsc_matches_ntsc_rs_cli() {
    let o = Oracle::new("ntsc");
    let preset = std::fs::read_to_string(o.library("library/presets/vhs.json")).unwrap();
    // The pipeline sets the seed with jq: `.random_seed = $seed` (re-serialized compactly).
    let settings = preset.replacen("\"random_seed\": 0", "\"random_seed\": 1234567", 1);
    assert_ne!(settings, preset, "vhs.json no longer has random_seed 0");

    o.run(
        "ntsc-rs-cli",
        &["-i", &o.path("in.mkv"), "-o", &o.path("ntsc.mkv"), "-c", "ffv1", "--chroma-subsampling", "-y", "-j", &settings],
    );
    std::fs::create_dir_all(o.dir.join("png")).unwrap();
    o.run("ntsc-rs-cli", &["-i", &o.path("in.mkv"), "-o", &o.path("png/f_####.png"), "-c", "png", "-y", "-j", &settings]);

    let input = o.rgb24_frames(&o.path("in.mkv"));
    let ntsc = Ntsc::from_json(&settings).unwrap();
    // ntsc-rs-cli's videorate retimes frames to exact k * fps_d / fps_n, so the
    // filter's index is k; at EOS it repeats the last frame once more as index N.
    let mut ours16 = Vec::new();
    for k in 0..=input.len() {
        let src = rgb24_to_xrgb16(&input[k.min(input.len() - 1)]);
        let mut dst = vec![0u16; W * H * 4];
        let pts = (k as u128 * 1_000_000_000 / FPS as u128) as u64;
        let index = pts_frame_index(pts, FPS, 1).unwrap();
        assert_eq!(index, k as u64);
        ntsc.apply_xrgb16(&src, W * 8, &mut dst, W * 8, W, H, index).unwrap();
        ours16.push(dst);
    }

    let png: Vec<Vec<u8>> = (0..ours16.len())
        .map(|k| {
            let raw = o.run(
                "ffmpeg",
                &["-v", "error", "-i", &o.path(&format!("png/f_{k:04}.png")), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            );
            raw
        })
        .collect();
    assert!(!o.dir.join(format!("png/f_{:04}.png", ours16.len())).exists(), "CLI wrote more PNG frames than N + 1");
    let ours_rgb: Vec<Vec<u8>> = ours16.iter().map(|f| xrgb16_to_rgb24(f)).collect();
    let r = compare("ntsc vs ntsc-rs-cli PNG (RGB, effect level)", &ours_rgb, &png);
    assert!(r.min_psnr >= 50.0, "ntsc PNG comparison diverges at the effect level");

    let cli = o.yuv_of_file(&o.path("ntsc.mkv"), "yuv420p");
    let ours48: Vec<Vec<u8>> = ours16.iter().map(|f| xrgb16_to_rgb48le(f)).collect();
    compare_yuv("ntsc vs ntsc-rs-cli FFV1 yuv420p, from 16-bit RGB", &o.yuv_of_frames(&ours48, "rgb48le", "yuv420p"), &cli);
    let (y, c) = compare_yuv("ntsc vs ntsc-rs-cli FFV1 yuv420p, from 8-bit RGB", &o.yuv_of_frames(&ours_rgb, "rgb24", "yuv420p"), &cli);
    assert!(y.min_psnr >= 45.0 && c.min_psnr >= 40.0, "ntsc FFV1 comparison diverges");
}

/// bend: `bender --preset P --seed N --dump-preset` -> preset.json, then
/// `bender -i IN -o OUT --codec ffv1 --scanlines 0 --preset preset.json --overwrite`.
#[test]
#[ignore = "needs a built macOS toolchain (GLITCHBOX_TOOLCHAIN)"]
fn bender_matches_bender_cli() {
    let o = Oracle::new("bender");
    let preset_path = o.library("bender-presets/meltdown.json");
    let preset_text = std::fs::read_to_string(&preset_path).unwrap();
    let preset_arg = preset_path.to_string_lossy().into_owned();
    let dumped = o.run(
        "bender",
        &["--preset", &preset_arg, "--set", "order=sync,tape,feedback", "--seed", "-77", "--dump-preset"],
    );
    let dumped = String::from_utf8(dumped).unwrap();
    std::fs::write(o.dir.join("preset.json"), &dumped).unwrap();

    let bender = Bender::new(Some(&preset_text), &["order=sync,tape,feedback"], Some(-77), 0).unwrap();
    assert_eq!(bender.preset_json(), dumped.trim_end_matches('\n'), "--dump-preset differs");

    o.run(
        "bender",
        &[
            "-i", &o.path("in.mkv"), "-o", &o.path("bend.mkv"), "--codec", "ffv1", "--scanlines", "0", "--preset",
            &o.path("preset.json"), "--overwrite",
        ],
    );
    let bender = Bender::new(Some(&dumped), &[], None, 0).unwrap();
    let input = o.rgb24_frames(&o.path("in.mkv"));
    let pts = o.pts_ns(&o.path("in.mkv"));
    assert_eq!(pts.len(), input.len());
    let mut ours = Vec::new();
    let mut indices = Vec::new();
    for (frame, &t) in input.iter().zip(&pts) {
        // No videorate in bender: the index comes from the demuxed (millisecond) timestamp.
        let index = pts_frame_index(t, FPS, 1).unwrap();
        indices.push(index);
        let src = rgb24_to_rgba(frame);
        let mut dst = vec![0u8; W * H * 4];
        bender.apply_rgba8(&src, W * 4, &mut dst, W * 4, W, H, index).unwrap();
        ours.push(rgba_to_rgb24(&dst));
    }
    eprintln!("bender frame indices from MKV timestamps: {indices:?}");
    let cli = o.yuv_of_file(&o.path("bend.mkv"), "yuv420p");
    let (y, c) = compare_yuv("bender vs bender CLI FFV1 yuv420p", &o.yuv_of_frames(&ours, "rgb24", "yuv420p"), &cli);
    assert!(y.min_psnr >= 45.0 && c.min_psnr >= 40.0, "bender comparison diverges");
}

/// reactive-vcr: `reactive-vcr render --video IN --audio IN --map presets/reactive-vcr.toml
/// --audio-mode none --output OUT`.
#[test]
#[ignore = "needs a built macOS toolchain (GLITCHBOX_TOOLCHAIN)"]
fn reactive_matches_reactive_vcr_cli() {
    let o = Oracle::new("reactive");
    let map_path = o.library("library/presets/reactive-vcr.toml");
    let map_arg = map_path.to_string_lossy().into_owned();
    o.run(
        "reactive-vcr",
        &[
            "render", "--video", &o.path("in.mkv"), "--audio", &o.path("in.mkv"), "--map", &map_arg, "--audio-mode",
            "none", "--output", &o.path("rv.mkv"),
        ],
    );

    let duration: f64 = String::from_utf8(o.run(
        "ffprobe",
        &["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", &o.path("in.mkv")],
    ))
    .unwrap()
    .trim()
    .parse()
    .unwrap();
    let samples = o.mono_f32(&o.path("in.mkv"));
    let toml = std::fs::read_to_string(&map_path).unwrap();
    let rv = Reactive::new(
        &toml,
        map_path.parent().unwrap(),
        &samples,
        reactive::VideoFacts { width: W as u32, height: H as u32, fps_n: FPS, fps_d: 1, duration_s: duration },
        0,
    )
    .unwrap();
    assert_eq!(rv.frame_size(), (W as u32, H as u32));

    let input = o.rgb24_frames(&o.path("in.mkv"));
    let mut ours = Vec::new();
    for (k, frame) in input.iter().enumerate() {
        // videorate retimes to k * fps_d / fps_n; the filter rounds.
        let t = (k as u128 * 1_000_000_000 / FPS as u128) as u64;
        let index = reactive::frame_index(t, FPS, 1).unwrap();
        assert_eq!(index, k);
        let mut dst = vec![0u8; W * H * 3];
        if rv.apply_rgb24(frame, W * 3, &mut dst, W * 3, W, H, index).unwrap() {
            ours.push(dst);
        }
    }
    assert_eq!(ours.len(), rv.frame_count());
    let cli = o.yuv_of_file(&o.path("rv.mkv"), "yuv444p");
    let (y, c) = compare_yuv("reactive vs reactive-vcr CLI FFV1 yuv444p", &o.yuv_of_frames(&ours, "rgb24", "yuv444p"), &cli);
    assert!(y.min_psnr >= 45.0 && c.min_psnr >= 45.0, "reactive-vcr comparison diverges");
}
