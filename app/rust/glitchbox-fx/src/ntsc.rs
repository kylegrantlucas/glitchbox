//! ntsc-rs (core crate at the macOS ntsc-rs-cli revision), driven the way
//! ntsc-rs-cli's GStreamer filter drives it for progressive input.

use ntsc_rs::settings::SettingsList;
use ntsc_rs::yiq_fielding::{BlitInfo, DeinterlaceMode, Xrgb, YiqOwned, YiqView};
use ntsc_rs::{NtscEffect, NtscEffectFullSettings};

pub struct Ntsc {
    settings: NtscEffectFullSettings,
    effect: NtscEffect,
}

impl Ntsc {
    /// Parses settings exactly as `ntsc-rs-cli -j JSON` does
    /// (`SettingsList::from_json`: `version: 1` presets start from the legacy
    /// values, ntscQT presets are converted).
    pub fn from_json(json: &str) -> Result<Self, String> {
        let list = SettingsList::<NtscEffectFullSettings>::new();
        let settings = list
            .from_json(json)
            .map_err(|e| format!("invalid ntsc-rs settings: {e}"))?;
        let effect = settings.clone().into();
        Ok(Self { settings, effect })
    }

    /// The fully resolved settings as ntsc-rs JSON.
    pub fn settings_json(&self) -> Result<String, String> {
        SettingsList::<NtscEffectFullSettings>::new()
            .to_json_string(&self.settings)
            .map_err(|e| format!("serializing ntsc-rs settings: {e}"))
    }

    pub fn effect(&self) -> &NtscEffect {
        &self.effect
    }

    /// One progressive frame of 16-bit xRGB (GStreamer ARGB64: four native-endian
    /// u16 per pixel, X/A first, then R, G, B) in, same format out; strides in
    /// bytes. Mirrors ntsc-rs-cli's `process_gst_frame` for
    /// `VideoInterlaceMode::Progressive`: the field comes from `use_field` and
    /// the frame index, the effect runs at scale [1, 1], and the result is
    /// written back with `DeinterlaceMode::Bob`. The X channel of `dst` is
    /// left as ntsc-rs writes it (unspecified).
    #[allow(clippy::too_many_arguments)]
    pub fn apply_xrgb16(
        &self,
        src: &[u16],
        src_stride: usize,
        dst: &mut [u16],
        dst_stride: usize,
        width: usize,
        height: usize,
        frame: u64,
    ) -> Result<(), String> {
        let frame = usize::try_from(frame).map_err(|_| "frame index overflows")?;
        crate::mark_ntsc_pool_started();
        let field = self.effect.use_field.to_yiq_field(frame);
        let mut yiq = YiqOwned::from_strided_buffer::<Xrgb, u16>(src, src_stride, width, height, field);
        let mut view = YiqView::from(&mut yiq);
        self.effect.apply_effect_to_yiq(&mut view, frame, [1.0, 1.0]);
        view.write_to_strided_buffer::<Xrgb, u16, _>(
            dst,
            BlitInfo::from_full_frame(width, height, dst_stride),
            DeinterlaceMode::Bob,
            (),
        );
        Ok(())
    }
}

/// ntsc-rs-cli `--scale N`: height N, width round(w * N / h) in f32 (not
/// rounded to even). `None` for a zero dimension.
pub fn scaled_size(width: u32, height: u32, scanlines: u32) -> Option<(u32, u32)> {
    if width == 0 || height == 0 || scanlines == 0 {
        return None;
    }
    let scale_factor = scanlines as f32 / height as f32;
    let w = (width as f32 * scale_factor).round() as i32;
    (w > 0).then_some((w as u32, scanlines))
}
