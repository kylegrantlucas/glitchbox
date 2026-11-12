//! reactive-vcr (core crate at v0.4.1, with its own ntsc-rs and bender
//! revisions), driven the way `reactive-vcr render` does with no
//! --preview/--start/--duration.

use reactive_vcr::effect::FrameProcessor;
use reactive_vcr::mapping::{self, MappingFile};
use reactive_vcr::modulate::Schedule;
use reactive_vcr::params::ParamCatalog;
use reactive_vcr::timeline::{Selection, VideoInfo, select_timeline, selection_features};
use std::path::Path;
use std::sync::Mutex;

/// What `reactive-vcr render` probes from the video (GStreamer Discoverer).
#[derive(Debug, Clone, Copy)]
pub struct VideoFacts {
    pub width: u32,
    pub height: u32,
    /// Frame rate; 0/x or x/0 falls back to 30/1 like the CLI.
    pub fps_n: i32,
    pub fps_d: i32,
    /// Container duration in seconds.
    pub duration_s: f64,
}

pub struct Reactive {
    catalog: ParamCatalog,
    schedule: Schedule,
    selection: Selection,
    processor: Mutex<Option<FrameProcessor>>,
    pool: rayon::ThreadPool,
}

impl Reactive {
    /// `mapping_toml` is the mapping file's text and `base_dir` its directory
    /// (relative `[base] preset` paths resolve against it, like
    /// `mapping::load`). `samples` is the driving audio as mono f32 at
    /// 48 kHz.
    pub fn new(mapping_toml: &str, base_dir: &Path, samples: &[f32], video: VideoFacts, threads: u32) -> Result<Self, String> {
        let (fps_n, fps_d) = if video.fps_n > 0 && video.fps_d > 0 { (video.fps_n, video.fps_d) } else { (30, 1) };
        if !(video.duration_s.is_finite() && video.duration_s > 0.0) {
            return Err("the video reports no duration".into());
        }
        let info = VideoInfo {
            width: video.width,
            height: video.height,
            fps_n,
            fps_d,
            duration_s: video.duration_s,
            has_audio: false,
        };
        let selection = select_timeline(&info, None, None, None).map_err(|e| format!("{e:#}"))?;
        let catalog = ParamCatalog::new();
        let file = MappingFile::parse(mapping_toml).map_err(|e| format!("parsing mapping: {e:#}"))?;
        let map = mapping::compile(file, base_dir, &catalog).map_err(|e| format!("{e:#}"))?;
        let features = selection_features(samples, &map, &selection).map_err(|e| format!("{e:#}"))?;
        let schedule = Schedule::build(&catalog, &map, &features, selection.fps());
        Ok(Self {
            catalog,
            schedule,
            selection,
            processor: Mutex::new(None),
            pool: crate::build_pool(threads, "reactive")?,
        })
    }

    /// Frames the CLI renders: round(duration_s * fps); later frames are dropped.
    pub fn frame_count(&self) -> usize {
        self.selection.frames
    }

    /// The size the CLI scales video to before the effect (each dimension
    /// floored to even, at least 2).
    pub fn frame_size(&self) -> (u32, u32) {
        (self.selection.width, self.selection.height)
    }

    /// One RGB24 frame src -> dst; strides in bytes. Returns false (and
    /// leaves `dst` untouched) for frames the CLI drops (index >= frame_count).
    #[allow(clippy::too_many_arguments)]
    pub fn apply_rgb24(
        &self,
        src: &[u8],
        src_stride: usize,
        dst: &mut [u8],
        dst_stride: usize,
        width: usize,
        height: usize,
        frame: usize,
    ) -> Result<bool, String> {
        let limit = self.selection.frames;
        if limit != 0 && frame >= limit {
            return Ok(false);
        }
        let effect = self.schedule.effect(&self.catalog, frame);
        let chain = self.schedule.chain();
        if chain.ntsc {
            crate::mark_ntsc_pool_started();
        }
        let mut guard = self.processor.lock().unwrap_or_else(|e| e.into_inner());
        let processor = match guard.as_mut() {
            Some(current) if current.fits(width, height, chain) => current,
            _ => guard.insert(FrameProcessor::new(width, height, chain)),
        };
        self.pool
            .install(|| processor.process_strided(&effect, frame, src, src_stride, dst, dst_stride));
        Ok(true)
    }
}

/// The CLI filter's frame index for a stream time: round((t - start) * fps),
/// clamped at 0, with start = 0. `None` for a non-positive rate.
pub fn frame_index(stream_time_ns: u64, fps_n: i32, fps_d: i32) -> Option<usize> {
    if fps_n <= 0 || fps_d <= 0 {
        return None;
    }
    let fps = fps_n as f64 / fps_d as f64;
    let offset_s = stream_time_ns as f64 / 1e9;
    Some((offset_s * fps).round().max(0.0) as usize)
}
