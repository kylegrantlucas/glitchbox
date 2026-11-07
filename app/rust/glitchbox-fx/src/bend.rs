//! bender-rs (`bender` core crate at the macOS bender CLI revision), driven
//! the way `bender` (bender-gst's filter) drives it.

use bender::{BendEffect, BendState, PixelOrder};
use std::sync::Mutex;

pub struct Bender {
    effect: BendEffect,
    state: Mutex<BendState>,
    pool: rayon::ThreadPool,
}

impl Bender {
    /// Resolves an effect like `bender [--preset P] [--set ID=VALUE]... [--seed N]`:
    /// the preset (or `BendEffect::default()` without one), then each
    /// override in order, then the seed. The result is round-tripped through
    /// its JSON (`--dump-preset`) because Glitchbox's bend pipeline renders
    /// from that dumped preset. `threads` sizes this handle's rayon pool
    /// (0 = rayon's default).
    pub fn new(preset_json: Option<&str>, sets: &[&str], seed: Option<i32>, threads: u32) -> Result<Self, String> {
        let mut effect = match preset_json {
            Some(json) => BendEffect::from_json(json).map_err(|e| format!("invalid bender preset: {e}"))?,
            None => BendEffect::default(),
        };
        for entry in sets {
            let (id, value) = entry
                .split_once('=')
                .ok_or_else(|| format!("invalid --set '{entry}'; expected ID=VALUE"))?;
            effect
                .set_by_id(id.trim(), value.trim())
                .map_err(|e| format!("invalid --set '{entry}': {e}"))?;
        }
        if let Some(seed) = seed {
            effect.seed = seed;
        }
        let effect = BendEffect::from_json(&effect.to_json())
            .map_err(|e| format!("re-reading the resolved bender preset: {e}"))?;
        Ok(Self {
            effect,
            state: Mutex::new(BendState::default()),
            pool: crate::build_pool(threads, "bender")?,
        })
    }

    /// `bender --dump-preset` output (without its trailing newline).
    pub fn preset_json(&self) -> String {
        self.effect.to_json()
    }

    /// Forgets the stream's frame memory, as the GStreamer filter does on stop.
    pub fn reset(&self) {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).reset();
    }

    /// One RGBA8 frame (R, G, B, A bytes; alpha is carried through as bender
    /// leaves it) src -> dst; strides in bytes. Frames of one stream must be
    /// fed in decode order: the handle keeps feedback/tape memory.
    #[allow(clippy::too_many_arguments)]
    pub fn apply_rgba8(
        &self,
        src: &[u8],
        src_stride: usize,
        dst: &mut [u8],
        dst_stride: usize,
        width: usize,
        height: usize,
        frame: u64,
    ) -> Result<(), String> {
        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let state: &mut BendState = &mut guard;
        let effect = &self.effect;
        self.pool.install(|| {
            effect.apply_rgba8(width, height, src, src_stride, dst, dst_stride, PixelOrder::Rgba, frame, state)
        });
        Ok(())
    }
}

/// bender `--scanlines N` processing size (bender-gst `scaled_size`): height
/// N and width w*N/h (or the source size for N = 0), each rounded to the
/// nearest even number, at least 2.
pub fn scaled_size(width: u32, height: u32, scanlines: u32) -> (u32, u32) {
    let (w, h) = if scanlines == 0 || height == 0 {
        (f64::from(width), f64::from(height))
    } else {
        let s = f64::from(scanlines);
        (f64::from(width) * s / f64::from(height), s)
    };
    let even = |v: f64| (2.0 * (v / 2.0).round()).max(2.0) as u32;
    (even(w), even(h))
}
