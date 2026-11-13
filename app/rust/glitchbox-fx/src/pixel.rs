//! Original implementations for Glitchbox (MIT). Not derived from frei0r.
//!
//! Five RGBA8 frame effects behind the block-glitch, row-shift, plasma-distort,
//! kaleidoscope, and vertigo plugins on hosts without the frei0r plugins the
//! macOS ffmpeg steps use (iOS). They are specified from scratch (see
//! `include/glitchbox_fx.h`, "pixel effects") and look different from the
//! macOS renders. Every effect is deterministic for a given frame index (the
//! random ones seed their PRNG from it); alpha is copied from the source.

use rayon::prelude::*;
use serde_json::Value;
use std::f64::consts::TAU;
use std::sync::Mutex;

/// One effect with resolved params, plus the per-stream state vertigo feeds back.
pub struct Pixel {
    effect: Effect,
    state: Mutex<State>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Effect {
    BlockGlitch { frequency: f64, block_height: f64, shift: f64, color: f64 },
    RowShift { intensity: f64, block_height: f64, min: f64, max: f64 },
    PlasmaDistort { amplitude: f64, frequency: f64, time_based: bool, velocity: f64 },
    Kaleidoscope { origin_x: f64, origin_y: f64, segmentation: f64, direction: f64, reflect: bool },
    Vertigo { phase: f64, zoom: f64 },
}

/// vertigo's previous output frame (tightly packed RGBA8).
#[derive(Default)]
struct State {
    prev: Vec<u8>,
    prev_size: Option<(usize, usize)>,
}

/// The params of one effect as given (`{params}` JSON object), with manifest defaults.
struct Params<'a> {
    map: Option<&'a serde_json::Map<String, Value>>,
}

impl Params<'_> {
    fn num(&self, key: &str, default: f64) -> Result<f64, String> {
        let bad = |v: &Value| format!("parameter {key}: {v} is not a number");
        let n = match self.map.and_then(|m| m.get(key)) {
            None => return Ok(default),
            Some(v @ Value::Number(n)) => n.as_f64().ok_or_else(|| bad(v))?,
            Some(v @ Value::String(s)) => s.trim().parse::<f64>().map_err(|_| bad(v))?,
            Some(v) => return Err(bad(v)),
        };
        if n.is_finite() { Ok(n) } else { Err(format!("parameter {key}: {n} is not a finite number")) }
    }

    fn flag(&self, key: &str, default: bool) -> Result<bool, String> {
        match self.map.and_then(|m| m.get(key)) {
            None => Ok(default),
            Some(Value::String(s)) if s == "y" => Ok(true),
            Some(Value::String(s)) if s == "n" => Ok(false),
            Some(v) => Err(format!("parameter {key}: {v} is not \"y\" or \"n\"")),
        }
    }
}

impl Pixel {
    /// `effect` is a plugin id; `params_json` the layer's params object (None = all defaults).
    /// Missing keys take the defaults of `plugins/<id>.json`; unknown keys are ignored.
    pub fn new(effect: &str, params_json: Option<&str>) -> Result<Self, String> {
        let value: Option<Value> = params_json
            .map(|s| serde_json::from_str(s).map_err(|e| format!("invalid params JSON: {e}")))
            .transpose()?;
        let map = match &value {
            None | Some(Value::Null) => None,
            Some(Value::Object(m)) => Some(m),
            Some(_) => return Err("params JSON must be an object".to_string()),
        };
        let p = Params { map };
        let effect = match effect {
            "block-glitch" => Effect::BlockGlitch {
                frequency: p.num("frequency", 0.5)?,
                block_height: p.num("block_height", 0.5)?,
                shift: p.num("shift", 0.5)?,
                color: p.num("color", 0.3)?,
            },
            "row-shift" => Effect::RowShift {
                intensity: p.num("intensity", 0.1)?,
                block_height: p.num("block_height", 0.0)?,
                min: p.num("min", 0.0083)?,
                max: p.num("max", 0.1)?,
            },
            "plasma-distort" => Effect::PlasmaDistort {
                amplitude: p.num("amplitude", 1.0)?,
                frequency: p.num("frequency", 0.005)?,
                time_based: p.flag("time_based", false)?,
                velocity: p.num("velocity", 0.5)?,
            },
            "kaleidoscope" => Effect::Kaleidoscope {
                origin_x: p.num("origin_x", 0.5)?,
                origin_y: p.num("origin_y", 0.5)?,
                segmentation: p.num("segmentation", 0.125)?,
                direction: p.num("direction", 1.0)?,
                reflect: p.flag("reflect", true)?,
            },
            "vertigo" => Effect::Vertigo { phase: p.num("phase", 0.02)?, zoom: p.num("zoom", 0.202)? },
            other => return Err(format!("unknown pixel effect {other}")),
        };
        Ok(Self { effect, state: Mutex::new(State::default()) })
    }

    /// One RGBA8 frame src -> dst (strides in bytes, buffers at least stride * height).
    /// `frame_index` seeds the random effects and drives velocity-mode plasma; `time_s`
    /// drives time-based plasma. vertigo feeds back its previous output, so feed one
    /// stream's frames in order; frame index 0 restarts it.
    #[allow(clippy::too_many_arguments)]
    pub fn apply_rgba8(
        &self,
        src: &[u8],
        src_stride: usize,
        dst: &mut [u8],
        dst_stride: usize,
        width: usize,
        height: usize,
        frame_index: u64,
        time_s: f64,
    ) -> Result<(), String> {
        let row = width.checked_mul(4).ok_or("width overflows")?;
        if width == 0 || height == 0 {
            return Err("empty frame".to_string());
        }
        for (buf, stride, what) in [(src.len(), src_stride, "src"), (dst.len(), dst_stride, "dst")] {
            if stride < row {
                return Err(format!("{what}: stride {stride} is shorter than a row ({row} bytes)"));
            }
            let needed = stride.checked_mul(height - 1).and_then(|n| n.checked_add(row)).ok_or("frame size overflows")?;
            if buf < needed {
                return Err(format!("{what}: buffer of {buf} bytes is too small"));
            }
        }
        // Frames of one handle run one at a time (vertigo's feedback needs it; the rest
        // keep the same contract).
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let f = Frame { src, src_stride, w: width, h: height };
        match self.effect {
            Effect::BlockGlitch { frequency, block_height, shift, color } => {
                block_glitch(&f, dst, dst_stride, frame_index, frequency, block_height, shift, color)
            }
            Effect::RowShift { intensity, block_height, min, max } => {
                row_shift(&f, dst, dst_stride, frame_index, intensity, block_height, min, max)
            }
            Effect::PlasmaDistort { amplitude, frequency, time_based, velocity } => {
                let phi = if time_based { TAU * 0.1 * velocity * frame_index as f64 } else { TAU * 0.5 * time_s };
                plasma(&f, dst, dst_stride, amplitude, frequency, phi)
            }
            Effect::Kaleidoscope { origin_x, origin_y, segmentation, direction, reflect } => {
                kaleidoscope(&f, dst, dst_stride, origin_x, origin_y, segmentation, direction, reflect)
            }
            Effect::Vertigo { phase, zoom } => vertigo(&f, dst, dst_stride, frame_index, phase, zoom, &mut state)?,
        }
        copy_alpha(&f, dst, dst_stride);
        Ok(())
    }
}

/// A source frame and its geometry.
struct Frame<'a> {
    src: &'a [u8],
    src_stride: usize,
    w: usize,
    h: usize,
}

impl Frame<'_> {
    fn row(&self, y: usize) -> &[u8] {
        &self.src[y * self.src_stride..y * self.src_stride + self.w * 4]
    }

    /// Bilinear RGB sample at (x, y), clamped to the frame; unrounded.
    fn sample(&self, x: f64, y: f64) -> [f64; 3] {
        bilinear(self.src, self.src_stride, self.w, self.h, x, y)
    }
}

/// Bilinear RGB sample of an RGBA8 image at (x, y), clamped to [0,W-1]x[0,H-1].
fn bilinear(img: &[u8], stride: usize, w: usize, h: usize, x: f64, y: f64) -> [f64; 3] {
    let x = if x.is_nan() { 0.0 } else { x.clamp(0.0, (w - 1) as f64) };
    let y = if y.is_nan() { 0.0 } else { y.clamp(0.0, (h - 1) as f64) };
    let (x0, y0) = (x.floor() as usize, y.floor() as usize);
    let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
    let (tx, ty) = (x - x0 as f64, y - y0 as f64);
    let px = |xx: usize, yy: usize, c: usize| f64::from(img[yy * stride + xx * 4 + c]);
    let mut out = [0.0; 3];
    for (c, v) in out.iter_mut().enumerate() {
        let top = px(x0, y0, c) + (px(x1, y0, c) - px(x0, y0, c)) * tx;
        let bottom = px(x0, y1, c) + (px(x1, y1, c) - px(x0, y1, c)) * tx;
        *v = top + (bottom - top) * ty;
    }
    out
}

fn to_u8(v: f64) -> u8 {
    v.round().clamp(0.0, 255.0) as u8
}

/// Rows of dst (each `w * 4` bytes) with their index, in parallel.
fn par_rows(dst: &mut [u8], dst_stride: usize, w: usize, h: usize, f: impl Fn(usize, &mut [u8]) + Sync + Send) {
    dst.par_chunks_mut(dst_stride).take(h).enumerate().for_each(|(y, row)| f(y, &mut row[..w * 4]));
}

fn copy_alpha(f: &Frame, dst: &mut [u8], dst_stride: usize) {
    for y in 0..f.h {
        let s = f.row(y);
        let d = &mut dst[y * dst_stride..y * dst_stride + f.w * 4];
        for x in 0..f.w {
            d[x * 4 + 3] = s[x * 4 + 3];
        }
    }
}

/// Writes source row `y` shifted right by `dx` pixels (wrapping) into `out`:
/// `out[x] = src[(x - dx) mod W]`.
fn shift_row(src_row: &[u8], out: &mut [u8], w: usize, dx: i64) {
    let d = dx.rem_euclid(w as i64) as usize * 4;
    let row = w * 4;
    out[d..row].copy_from_slice(&src_row[..row - d]);
    out[..d].copy_from_slice(&src_row[row - d..row]);
}

/// SplitMix64; `f()` gives [0, 1) from the top 53 bits.
struct SplitMix64(u64);

impl SplitMix64 {
    fn for_frame(frame_index: u64) -> Self {
        Self(0x5EED_0000_0000_0000 ^ frame_index)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn f(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// floor(n * f()), at most n - 1.
    fn below(&mut self, n: usize) -> usize {
        ((self.f() * n as f64).floor() as usize).min(n.saturating_sub(1))
    }
}

/// Copies rows `y..y + h` of the source into dst, each shifted by `dx`.
fn shift_band(f: &Frame, dst: &mut [u8], dst_stride: usize, y: usize, h: usize, dx: i64) {
    for yy in y..y + h {
        let out = &mut dst[yy * dst_stride..yy * dst_stride + f.w * 4];
        shift_row(f.row(yy), out, f.w, dx);
    }
}

fn copy_frame(f: &Frame, dst: &mut [u8], dst_stride: usize) {
    shift_band(f, dst, dst_stride, 0, f.h, 0);
}

#[allow(clippy::too_many_arguments)]
fn block_glitch(
    f: &Frame,
    dst: &mut [u8],
    dst_stride: usize,
    frame_index: u64,
    frequency: f64,
    block_height: f64,
    shift: f64,
    color: f64,
) {
    let mut rng = SplitMix64::for_frame(frame_index);
    if rng.f() >= frequency {
        copy_frame(f, dst, dst_stride);
        return;
    }
    let (w, h) = (f.w as f64, f.h);
    let hb = ((block_height * h as f64 / 4.0).round().max(1.0)) as usize;
    let mut y = 0;
    while y < h {
        let band = (h - y).min(1 + rng.below(hb));
        let dx = if rng.f() < 0.5 { ((2.0 * rng.f() - 1.0) * shift * w / 2.0).round() as i64 } else { 0 };
        shift_band(f, dst, dst_stride, y, band, dx);
        y += band;
    }
    if rng.f() < color {
        let op = rng.below(3);
        let (channel, xor) = match op {
            1 => (rng.below(3), 0),
            2 => (rng.below(3), rng.below(256) as u8),
            _ => (0, 0),
        };
        for y in 0..f.h {
            let row = &mut dst[y * dst_stride..y * dst_stride + f.w * 4];
            for px in row.chunks_exact_mut(4) {
                match op {
                    0 => px.swap(0, 2),
                    1 => px[channel] = 255 - px[channel],
                    _ => px[channel] ^= xor,
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn row_shift(
    f: &Frame,
    dst: &mut [u8],
    dst_stride: usize,
    frame_index: u64,
    intensity: f64,
    block_height: f64,
    min: f64,
    max: f64,
) {
    let mut rng = SplitMix64::for_frame(frame_index);
    let (w, h) = (f.w as f64, f.h as f64);
    let fixed = (block_height > 0.0).then(|| (block_height * h).round().max(1.0) as usize);
    let lo = (min.min(max) * h).round().max(1.0) as usize;
    let hi = ((min.max(max) * h).round() as usize).max(lo);
    let mut y = 0;
    while y < f.h {
        let band = fixed.unwrap_or_else(|| lo + rng.below(hi - lo + 1)).min(f.h - y);
        let dx = ((2.0 * rng.f() - 1.0) * intensity * w).round() as i64;
        shift_band(f, dst, dst_stride, y, band, dx);
        y += band;
    }
}

fn plasma(f: &Frame, dst: &mut [u8], dst_stride: usize, amplitude: f64, frequency: f64, phi: f64) {
    let (w, h) = (f.w as f64, f.h as f64);
    let a = amplitude * 0.05 * w.min(h);
    let k = TAU * (1.0 + 199.0 * frequency) / w.max(h);
    par_rows(dst, dst_stride, f.w, f.h, |y, row| {
        let yf = y as f64;
        let (sy, sy_half) = ((k * yf + phi).sin(), (0.5 * k * yf + phi).sin());
        for (x, px) in row.chunks_exact_mut(4).enumerate() {
            let xf = x as f64;
            let dx = a * sy * (0.5 * k * xf + 0.7 * phi).cos();
            let dy = a * (k * xf + 1.3 * phi).cos() * sy_half;
            let s = f.sample(xf + dx, yf + dy);
            px[..3].copy_from_slice(&s.map(to_u8));
        }
    });
}

#[allow(clippy::too_many_arguments)]
fn kaleidoscope(
    f: &Frame,
    dst: &mut [u8],
    dst_stride: usize,
    origin_x: f64,
    origin_y: f64,
    segmentation: f64,
    direction: f64,
    reflect: bool,
) {
    let n = (segmentation * 128.0).round().max(1.0);
    let alpha = TAU / n;
    let (ox, oy) = (origin_x * (f.w - 1) as f64, origin_y * (f.h - 1) as f64);
    par_rows(dst, dst_stride, f.w, f.h, |y, row| {
        let vy = y as f64 - oy;
        for (x, px) in row.chunks_exact_mut(4).enumerate() {
            let vx = x as f64 - ox;
            let r = vx.hypot(vy);
            let theta = vy.atan2(vx).rem_euclid(TAU);
            let i = (theta / alpha).floor().min(n - 1.0);
            let mut t = theta - i * alpha;
            if reflect && i % 2.0 == 1.0 {
                t = alpha - t;
            }
            // Nearest of the manifest's three directions: 1.0, 0.5, 0.0.
            let s = if direction >= 0.75 {
                t
            } else if direction >= 0.25 {
                -t
            } else {
                t - alpha / 2.0
            };
            let sample = f.sample(ox + r * s.cos(), oy + r * s.sin());
            px[..3].copy_from_slice(&sample.map(to_u8));
        }
    });
}

#[allow(clippy::too_many_arguments)]
fn vertigo(
    f: &Frame,
    dst: &mut [u8],
    dst_stride: usize,
    frame_index: u64,
    phase: f64,
    zoom: f64,
    state: &mut State,
) -> Result<(), String> {
    let (w, h) = (f.w, f.h);
    let start = frame_index == 0 || state.prev_size.is_none();
    if !start && state.prev_size != Some((w, h)) {
        let (pw, ph) = state.prev_size.unwrap_or_default();
        return Err(format!("vertigo: frame size {w}x{h} differs from the previous frame's {pw}x{ph}"));
    }
    if start {
        copy_frame(f, dst, dst_stride);
    } else {
        let prev = &state.prev;
        let theta = phase * 0.5;
        let s = 1.0 + zoom * 0.1;
        let (sin, cos) = theta.sin_cos();
        let (cx, cy) = ((w - 1) as f64 / 2.0, (h - 1) as f64 / 2.0);
        par_rows(dst, dst_stride, w, h, |y, row| {
            let src = f.row(y);
            let py = (y as f64 - cy) / s;
            for (x, px) in row.chunks_exact_mut(4).enumerate() {
                let pxf = (x as f64 - cx) / s;
                let warp = bilinear(prev, w * 4, w, h, cx + cos * pxf - sin * py, cy + sin * pxf + cos * py);
                for c in 0..3 {
                    px[c] = to_u8(0.25 * f64::from(src[x * 4 + c]) + 0.75 * warp[c]);
                }
            }
        });
    }
    state.prev.resize(w * h * 4, 0);
    for y in 0..h {
        state.prev[y * w * 4..(y + 1) * w * 4].copy_from_slice(&dst[y * dst_stride..y * dst_stride + w * 4]);
    }
    state.prev_size = Some((w, h));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 37;
    const H: usize = 23;

    /// A deterministic, structured RGBA test card with varying alpha.
    fn card() -> Vec<u8> {
        let mut v = Vec::with_capacity(W * H * 4);
        for y in 0..H {
            for x in 0..W {
                v.extend_from_slice(&[(x * 7) as u8, (y * 11) as u8, ((x * y) % 256) as u8, (x + y) as u8]);
            }
        }
        v
    }

    fn apply(effect: &str, params: &str, src: &[u8], index: u64) -> Vec<u8> {
        let p = Pixel::new(effect, Some(params)).unwrap();
        render(&p, src, index)
    }

    fn render(p: &Pixel, src: &[u8], index: u64) -> Vec<u8> {
        let mut dst = vec![0u8; src.len()];
        p.apply_rgba8(src, W * 4, &mut dst, W * 4, W, H, index, index as f64 / 30.0).unwrap();
        dst
    }

    fn max_diff(a: &[u8], b: &[u8]) -> u8 {
        a.iter().zip(b).map(|(x, y)| x.abs_diff(*y)).max().unwrap()
    }

    #[test]
    fn neutral_settings_are_the_identity() {
        let src = card();
        for index in [0, 1, 7] {
            assert_eq!(apply("block-glitch", r#"{"frequency": 0}"#, &src, index), src);
            assert_eq!(apply("row-shift", r#"{"intensity": 0}"#, &src, index), src);
            assert_eq!(apply("plasma-distort", r#"{"amplitude": 0}"#, &src, index), src);
        }
        assert_eq!(apply("vertigo", "{}", &src, 0), src);
    }

    #[test]
    fn one_segment_kaleidoscope_is_nearly_the_identity() {
        let src = card();
        let out = apply("kaleidoscope", r#"{"segmentation": 0.001, "reflect": "n", "direction": "1.0"}"#, &src, 3);
        assert!(max_diff(&out, &src) <= 1, "max diff {}", max_diff(&out, &src));
    }

    #[test]
    fn random_effects_are_deterministic_per_frame() {
        let src = card();
        for (effect, params) in [("block-glitch", r#"{"frequency": 1}"#), ("row-shift", r#"{"frequency": 1}"#)] {
            let a = apply(effect, params, &src, 5);
            assert_eq!(a, apply(effect, params, &src, 5), "{effect}: same index differs");
            assert_ne!(a, apply(effect, params, &src, 6), "{effect}: different index matches");
            assert_ne!(a, src, "{effect}: no effect");
        }
    }

    #[test]
    fn alpha_comes_from_the_source() {
        let src = card();
        for effect in ["block-glitch", "row-shift", "plasma-distort", "kaleidoscope", "vertigo"] {
            let p = Pixel::new(effect, Some(r#"{"frequency": 1, "color": 1, "intensity": 0.5}"#)).unwrap();
            for index in 0..3 {
                let out = render(&p, &src, index);
                assert!(out.iter().zip(&src).skip(3).step_by(4).all(|(a, b)| a == b), "{effect} frame {index}");
            }
        }
    }

    #[test]
    fn vertigo_feeds_back_and_rejects_a_new_size() {
        let src = card();
        let p = Pixel::new("vertigo", Some(r#"{"phase": 0.5, "zoom": 1}"#)).unwrap();
        assert_eq!(render(&p, &src, 0), src);
        let one = render(&p, &src, 1);
        assert_ne!(one, src);
        let mut dst = vec![0u8; 8 * 8 * 4];
        let small = vec![0u8; 8 * 8 * 4];
        let err = p.apply_rgba8(&small, 32, &mut dst, 32, 8, 8, 2, 0.0).unwrap_err();
        assert!(err.contains("differs"), "{err}");
        // Frame 0 restarts the stream at any size.
        p.apply_rgba8(&small, 32, &mut dst, 32, 8, 8, 0, 0.0).unwrap();
    }

    #[test]
    fn strided_buffers_match_packed_ones() {
        let src = card();
        let stride = W * 4 + 12;
        let mut padded = vec![0u8; stride * H];
        for y in 0..H {
            padded[y * stride..y * stride + W * 4].copy_from_slice(&src[y * W * 4..(y + 1) * W * 4]);
        }
        for effect in ["block-glitch", "row-shift", "plasma-distort", "kaleidoscope", "vertigo"] {
            let packed = apply(effect, r#"{"frequency": 1}"#, &src, 0);
            let p = Pixel::new(effect, Some(r#"{"frequency": 1}"#)).unwrap();
            let mut dst = vec![0u8; stride * (H - 1) + W * 4];
            p.apply_rgba8(&padded, stride, &mut dst, stride, W, H, 0, 0.0).unwrap();
            for y in 0..H {
                assert_eq!(&dst[y * stride..y * stride + W * 4], &packed[y * W * 4..(y + 1) * W * 4], "{effect} row {y}");
            }
        }
    }

    #[test]
    fn bad_ids_and_values_are_errors() {
        let err = Pixel::new("glitch0r", None).err().unwrap();
        assert_eq!(err, "unknown pixel effect glitch0r");
        let err = Pixel::new("row-shift", Some(r#"{"intensity": "lots"}"#)).err().unwrap();
        assert!(err.contains("intensity"), "{err}");
        let err = Pixel::new("kaleidoscope", Some(r#"{"reflect": "maybe"}"#)).err().unwrap();
        assert!(err.contains("reflect"), "{err}");
        let err = Pixel::new("vertigo", Some(r#"{"zoom": true}"#)).err().unwrap();
        assert!(err.contains("zoom"), "{err}");
        // Strings parse as numbers; the manifests' enum values are strings.
        Pixel::new("kaleidoscope", Some(r#"{"direction": "0.5", "segmentation": "0.25"}"#)).unwrap();
    }

    #[test]
    fn splitmix_is_the_reference_sequence() {
        // SplitMix64 seeded 0 (Vigna's reference): first output 0xE220A8397B1DCDAF.
        let mut r = SplitMix64(0);
        assert_eq!(r.next_u64(), 0xE220_A839_7B1D_CDAF);
    }
}
