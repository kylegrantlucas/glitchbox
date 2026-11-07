//! C API over the burns-rs render core (see `include/glitchbox_burns.h`).
//!
//! Mirrors `burns render` (burns-cli `commands::render`) up to the encoder: the project is
//! parsed strictly, the dedicated flags are applied the way `burns-cli`'s `apply_overrides`
//! does, depth comes from a file or from burns-depth's estimator, and every frame is rendered
//! at [`RenderQuality::Final`] and read back as the RGBA8 rows the CLI pipes to FFmpeg.

use std::ffi::{CStr, CString, c_char, c_void};
use std::fs;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::thread;
use std::time::Duration;

use burns::{
    CameraMotion, DepthMap, FrameRate, GpuContext, MotionProject, RenderQuality, RenderView,
    Renderer, Size, SourceImage, Timeline,
};
use burns_depth::{DepthError, DepthEstimator, DepthProgress, DepthService, model_input_size};

/// Opaque renderer handed to C.
pub struct GbBurns {
    renderer: Renderer,
    project: MotionProject,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GbBurnsDepthMode {
    None = 0,
    File = 1,
    Auto = 2,
}

pub type GbBurnsProgressFn = Option<
    unsafe extern "C" fn(
        context: *mut c_void,
        phase: *const c_char,
        received: u64,
        total: u64,
        message: *const c_char,
    ),
>;

#[repr(C)]
pub struct GbBurnsOptions {
    pub image_path: *const c_char,
    pub image_rgba: *const u8,
    pub image_width: u32,
    pub image_height: u32,
    pub project_json: *const c_char,
    pub fps_num: u32,
    pub fps_den: u32,
    pub duration: f64,
    pub frames: u32,
    pub width: u32,
    pub height: u32,
    pub depth_mode: GbBurnsDepthMode,
    pub depth_path: *const c_char,
    pub cache_dir: *const c_char,
    pub ort_library: *const c_char,
    pub progress: GbBurnsProgressFn,
    pub progress_context: *mut c_void,
}

const CANCELLED: &str = "cancelled";

/// Runs `body`, turning an error or a panic into a C string in `*error`.
fn guarded<T>(error: *mut *mut c_char, failed: T, body: impl FnOnce() -> Result<T, String>) -> T {
    let message = match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => return value,
        Ok(Err(message)) => message,
        Err(panic) => {
            let detail = panic
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic payload".to_owned());
            format!("glitchbox-burns panicked: {detail}")
        }
    };
    if !error.is_null() {
        // SAFETY: the caller passes a writable `char **` or NULL.
        unsafe { *error = c_string(message) };
    }
    failed
}

fn c_string(text: String) -> *mut c_char {
    CString::new(text.replace('\0', " "))
        .expect("NULs were replaced")
        .into_raw()
}

/// A required or optional UTF-8 C string argument.
unsafe fn arg<'a>(ptr: *const c_char, name: &str) -> Result<Option<&'a str>, String> {
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: non-NULL arguments are NUL-terminated strings that outlive the call.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(Some)
        .map_err(|_| format!("{name} is not valid UTF-8"))
}

/// Watches the host's `atomic_int` and mirrors it into the flag burns-depth polls.
struct CancelBridge {
    flag: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    watcher: Option<thread::JoinHandle<()>>,
}

impl CancelBridge {
    fn new(cancel: *const AtomicI32) -> Result<Self, String> {
        let flag = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let watcher = if cancel.is_null() {
            None
        } else {
            let host = cancel as usize;
            let (flag, stop) = (Arc::clone(&flag), Arc::clone(&stop));
            Some(
                thread::Builder::new()
                    .name("glitchbox-burns cancel".to_owned())
                    .spawn(move || {
                        // SAFETY: the host keeps `cancel` alive for the whole create call,
                        // and the bridge is joined before create returns.
                        let host = unsafe { &*(host as *const AtomicI32) };
                        while !stop.load(Ordering::Acquire) {
                            if host.load(Ordering::Relaxed) != 0 {
                                flag.store(true, Ordering::Release);
                                return;
                            }
                            thread::sleep(Duration::from_millis(20));
                        }
                    })
                    .map_err(|e| format!("start the cancellation watcher: {e}"))?,
            )
        };
        Ok(Self {
            flag,
            stop,
            watcher,
        })
    }

    fn check(&self, host: *const AtomicI32) -> Result<(), String> {
        // SAFETY: as above; NULL means no cancellation.
        let host_set = !host.is_null() && unsafe { &*host }.load(Ordering::Relaxed) != 0;
        if host_set || self.flag.load(Ordering::Acquire) {
            Err(CANCELLED.to_owned())
        } else {
            Ok(())
        }
    }
}

impl Drop for CancelBridge {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(watcher) = self.watcher.take() {
            let _ = watcher.join();
        }
    }
}

/// burns-cli's `final_timeline`: a new rate alone keeps the saved duration; an explicit
/// duration replaces it at the final rate. An exact frame count is this API's addition.
fn final_timeline(
    saved: Timeline,
    fps: Option<FrameRate>,
    duration: Option<f64>,
    frames: Option<u32>,
) -> Result<Timeline, String> {
    let rate = fps.unwrap_or(saved.fps);
    let timeline = match (fps, duration, frames) {
        (_, _, Some(frames)) => Timeline::new(rate, frames),
        (None, None, None) => Ok(saved),
        (Some(fps), None, None) => saved.retimed(fps),
        (_, Some(seconds), None) => Timeline::from_duration(rate, seconds),
    };
    timeline.map_err(|e| e.to_string())
}

fn load_project(options: &GbBurnsOptions) -> Result<MotionProject, String> {
    // SAFETY: the caller's options hold valid C strings or NULL.
    let json = unsafe { arg(options.project_json, "project_json") }?
        .ok_or("project_json is required")?;
    let mut project =
        MotionProject::from_json(json).map_err(|e| format!("invalid burns project: {e}"))?;
    let fps = (options.fps_num != 0).then(|| FrameRate::new(options.fps_num, options.fps_den.max(1)));
    let duration = (options.duration != 0.0).then_some(options.duration);
    let frames = (options.frames != 0).then_some(options.frames);
    project.timeline = final_timeline(project.timeline, fps, duration, frames)?;
    project.output = Size::new(
        if options.width != 0 { options.width } else { project.output.width },
        if options.height != 0 { options.height } else { project.output.height },
    );
    project.validate().map_err(|e| e.to_string())?;
    Ok(project)
}

fn load_image(options: &GbBurnsOptions) -> Result<SourceImage, String> {
    // SAFETY: as above.
    if let Some(path) = unsafe { arg(options.image_path, "image_path") }? {
        let bytes = fs::read(path).map_err(|e| format!("read source image `{path}`: {e}"))?;
        return SourceImage::decode(&bytes).map_err(|e| format!("source image `{path}`: {e}"));
    }
    if options.image_rgba.is_null() {
        return Err("either image_path or image_rgba is required".to_owned());
    }
    let size = Size::new(options.image_width, options.image_height);
    let len = (options.image_width as usize)
        .checked_mul(options.image_height as usize)
        .and_then(|n| n.checked_mul(4))
        .ok_or("image size overflows")?;
    // SAFETY: the caller passes `len` readable bytes.
    let pixels = unsafe { std::slice::from_raw_parts(options.image_rgba, len) }.to_vec();
    SourceImage::from_rgba8(size, pixels).map_err(|e| format!("source image: {e}"))
}

/// `onnxruntime.framework/onnxruntime` beside the framework (or dylib) this code is in.
fn sibling_ort_library() -> Result<PathBuf, String> {
    #[repr(C)]
    struct DlInfo {
        fname: *const c_char,
        fbase: *mut c_void,
        sname: *const c_char,
        saddr: *mut c_void,
    }
    unsafe extern "C" {
        fn dladdr(addr: *const c_void, info: *mut DlInfo) -> i32;
    }
    let mut info = DlInfo {
        fname: ptr::null(),
        fbase: ptr::null_mut(),
        sname: ptr::null(),
        saddr: ptr::null_mut(),
    };
    // SAFETY: dladdr only reads the address and fills `info`.
    let found = unsafe { dladdr(sibling_ort_library as *const c_void, &mut info) };
    if found == 0 || info.fname.is_null() {
        return Err("cannot locate GlitchboxBurns to find ONNX Runtime beside it".to_owned());
    }
    // SAFETY: dladdr returns a NUL-terminated path owned by dyld.
    let image = PathBuf::from(unsafe { CStr::from_ptr(info.fname) }.to_string_lossy().into_owned());
    let container = image
        .ancestors()
        .find(|dir| dir.extension().is_some_and(|ext| ext == "framework"))
        .and_then(Path::parent)
        .or_else(|| image.parent())
        .ok_or("GlitchboxBurns has no parent directory")?;
    let candidate = container.join("onnxruntime.framework").join("onnxruntime");
    if candidate.is_file() {
        Ok(candidate)
    } else {
        Err(format!(
            "ONNX Runtime not found: no `{}` (pass ort_library)",
            candidate.display()
        ))
    }
}

fn depth_error(error: DepthError) -> String {
    match error {
        DepthError::Cancelled => CANCELLED.to_owned(),
        other => format!("depth: {other}"),
    }
}

/// `burns render --auto-depth`: burns-depth's `DepthService::generate` with an explicit
/// cache root and ONNX Runtime path (the service finds both through the environment).
fn auto_depth(
    root: &Path,
    ort: &Path,
    image: &SourceImage,
    cancel: &AtomicBool,
    mut progress: impl FnMut(DepthProgress),
) -> Result<DepthMap, String> {
    let check = || {
        if cancel.load(Ordering::Relaxed) {
            Err(CANCELLED.to_owned())
        } else {
            Ok(())
        }
    };
    check()?;
    model_input_size(image.size()).map_err(depth_error)?;
    let mut service = DepthService::with_cache_root(root);
    if let Ok(Some(map)) = service.cached(image) {
        progress(DepthProgress::CacheHit);
        return Ok(map);
    }
    let model = service
        .ensure_model(cancel, &mut progress)
        .map_err(depth_error)?;
    check()?;
    progress(DepthProgress::Loading);
    let mut estimator = DepthEstimator::new(&model, ort).map_err(depth_error)?;
    check()?;
    progress(DepthProgress::Inferring);
    let map = estimator.estimate(image).map_err(depth_error)?;
    check()?;
    progress(DepthProgress::Saving);
    if let Err(message) = store_depth(&service.depth_cache_path(image), &map) {
        progress(DepthProgress::PersistenceWarning {
            message: format!("depth map was generated but not cached: {message}"),
        });
    }
    Ok(map)
}

/// burns-depth's private `DepthService::store`: PNG through a temporary, then renamed.
fn store_depth(path: &Path, map: &DepthMap) -> Result<(), String> {
    let dir = path.parent().ok_or("cache path has no parent")?;
    let png = map.encode_png().map_err(|e| e.to_string())?;
    fs::create_dir_all(dir).map_err(|e| format!("create `{}`: {e}", dir.display()))?;
    let temp = dir.join(format!(
        ".{}.{}.partial",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("depth"),
        std::process::id()
    ));
    fs::write(&temp, &png).map_err(|e| format!("write `{}`: {e}", temp.display()))?;
    fs::rename(&temp, path).map_err(|e| {
        let _ = fs::remove_file(&temp);
        format!("publish `{}`: {e}", path.display())
    })
}

fn report(options: &GbBurnsOptions, event: DepthProgress) {
    let Some(callback) = options.progress else {
        return;
    };
    let (phase, received, total, message) = match event {
        DepthProgress::CacheHit => ("cache-hit", 0, 0, None),
        DepthProgress::Verifying => ("verifying", 0, 0, None),
        DepthProgress::Downloading { received, total } => ("downloading", received, total, None),
        DepthProgress::Loading => ("loading", 0, 0, None),
        DepthProgress::Inferring => ("inferring", 0, 0, None),
        DepthProgress::Saving => ("saving", 0, 0, None),
        DepthProgress::PersistenceWarning { message } => ("warning", 0, 0, Some(message)),
    };
    let phase = CString::new(phase).expect("no NUL");
    let message = message.map(|m| CString::new(m.replace('\0', " ")).expect("NULs replaced"));
    // SAFETY: the host's callback with its own context.
    unsafe {
        callback(
            options.progress_context,
            phase.as_ptr(),
            received,
            total,
            message.as_ref().map_or(ptr::null(), |m| m.as_ptr()),
        )
    };
}

fn resolve_depth(
    options: &GbBurnsOptions,
    project: &MotionProject,
    image: &SourceImage,
    cancel: *const AtomicI32,
) -> Result<Option<DepthMap>, String> {
    // Only the depth camera uses a map; burns ignores --depth/--auto-depth otherwise.
    if !matches!(project.camera, CameraMotion::Depth { .. }) {
        return Ok(None);
    }
    match options.depth_mode {
        GbBurnsDepthMode::None => Ok(None),
        GbBurnsDepthMode::File => {
            // SAFETY: as above.
            let path = unsafe { arg(options.depth_path, "depth_path") }?
                .ok_or("depth_path is required for GB_BURNS_DEPTH_FILE")?;
            let bytes = fs::read(path).map_err(|e| format!("read depth map `{path}`: {e}"))?;
            DepthMap::decode_png(&bytes)
                .map(Some)
                .map_err(|e| format!("depth map `{path}`: {e}"))
        }
        GbBurnsDepthMode::Auto => {
            // SAFETY: as above.
            let root = unsafe { arg(options.cache_dir, "cache_dir") }?
                .ok_or("cache_dir is required for GB_BURNS_DEPTH_AUTO")?;
            // SAFETY: as above.
            let ort = match unsafe { arg(options.ort_library, "ort_library") }? {
                Some(path) => PathBuf::from(path),
                None => sibling_ort_library()?,
            };
            let bridge = CancelBridge::new(cancel)?;
            let map = auto_depth(Path::new(root), &ort, image, &bridge.flag, |event| {
                report(options, event)
            });
            bridge.check(cancel)?;
            map.map(Some)
        }
    }
}

/// burns's `GpuContext::headless`, except that each requested limit is capped at what the
/// adapter supports. burns asks for `wgpu::Limits::default()` (plus the adapter's texture
/// and buffer sizes), which the iOS simulator's Metal device fails: it allows 15
/// inter-stage shader variables, the default is 16, and device creation is refused. burns's
/// shaders use far fewer, and limits never change rendered pixels; on Macs and devices that
/// meet the defaults the request is exactly burns's.
async fn gpu_context() -> Result<GpuContext, String> {
    let mut descriptor = wgpu::InstanceDescriptor::new_without_display_handle();
    descriptor.backends = burns::renderer::HEADLESS_BACKENDS;
    let instance = wgpu::Instance::new(descriptor);
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            force_fallback_adapter: false,
            compatible_surface: None,
            apply_limit_buckets: false,
        })
        .await
        .map_err(|e| format!("no GPU adapter: {e}"))?;
    let info = adapter.get_info();
    let supported = adapter.limits();
    let mut limits = wgpu::Limits::default().using_resolution(supported.clone());
    limits.max_buffer_size = supported.max_buffer_size;
    let limits = limits.or_worse_values_from(&supported);
    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor {
            label: Some("burns"),
            required_limits: limits,
            ..Default::default()
        })
        .await
        .map_err(|e| {
            format!(
                "the GPU adapter {} ({:?}) could not create a device: {e}",
                info.name, info.backend
            )
        })?;
    Ok(GpuContext { device, queue })
}

fn create(options: &GbBurnsOptions, cancel: *const AtomicI32) -> Result<Box<GbBurns>, String> {
    let project = load_project(options)?;
    let image = load_image(options)?;
    let depth = resolve_depth(options, &project, &image, cancel)?;
    if matches!(project.camera, CameraMotion::Depth { .. }) && depth.is_none() {
        return Err("the depth camera needs a depth map (depth file or auto depth)".to_owned());
    }
    let context = pollster::block_on(gpu_context())?;
    let mut renderer =
        Renderer::new(context, project.output, RenderQuality::Final).map_err(|e| e.to_string())?;
    renderer.set_source(&image).map_err(|e| e.to_string())?;
    if depth.is_some() {
        renderer.set_depth(depth.as_ref()).map_err(|e| e.to_string())?;
    }
    Ok(Box::new(GbBurns { renderer, project }))
}

/// # Safety
/// `options` points to a valid `gb_burns_options`; `cancel` and `error` are valid or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_create(
    options: *const GbBurnsOptions,
    cancel: *const AtomicI32,
    error: *mut *mut c_char,
) -> *mut GbBurns {
    guarded(error, ptr::null_mut(), || {
        // SAFETY: per the contract.
        let options = unsafe { options.as_ref() }.ok_or("options is NULL")?;
        create(options, cancel).map(Box::into_raw)
    })
}

/// # Safety
/// `renderer` comes from `gb_burns_create` or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_width(renderer: *const GbBurns) -> u32 {
    // SAFETY: per the contract.
    unsafe { renderer.as_ref() }.map_or(0, |r| r.project.output.width)
}

/// # Safety
/// `renderer` comes from `gb_burns_create` or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_height(renderer: *const GbBurns) -> u32 {
    // SAFETY: per the contract.
    unsafe { renderer.as_ref() }.map_or(0, |r| r.project.output.height)
}

/// # Safety
/// `renderer` comes from `gb_burns_create` or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_frame_count(renderer: *const GbBurns) -> u32 {
    // SAFETY: per the contract.
    unsafe { renderer.as_ref() }.map_or(0, |r| r.project.timeline.frames)
}

/// # Safety
/// `renderer` comes from `gb_burns_create` or is NULL; `num`/`den` are writable or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_fps(renderer: *const GbBurns, num: *mut u32, den: *mut u32) {
    // SAFETY: per the contract.
    let fps = unsafe { renderer.as_ref() }.map(|r| r.project.timeline.fps);
    let (n, d) = fps.map_or((0, 0), |f| (f.num, f.den));
    // SAFETY: per the contract.
    unsafe {
        if let Some(num) = num.as_mut() {
            *num = n;
        }
        if let Some(den) = den.as_mut() {
            *den = d;
        }
    }
}

/// # Safety
/// `renderer` comes from `gb_burns_create` or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_project_json(renderer: *const GbBurns) -> *mut c_char {
    // SAFETY: per the contract.
    let Some(renderer) = (unsafe { renderer.as_ref() }) else {
        return ptr::null_mut();
    };
    catch_unwind(AssertUnwindSafe(|| renderer.project.to_json().ok()))
        .ok()
        .flatten()
        .map_or(ptr::null_mut(), c_string)
}

/// # Safety
/// `renderer` comes from `gb_burns_create`; `dst` holds `stride * (height - 1) + width * 4`
/// writable bytes; `error` is writable or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_render_frame(
    renderer: *mut GbBurns,
    index: u32,
    dst: *mut u8,
    stride: usize,
    error: *mut *mut c_char,
) -> i32 {
    guarded(error, -1, || {
        // SAFETY: per the contract.
        let this = unsafe { renderer.as_mut() }.ok_or("renderer is NULL")?;
        if dst.is_null() {
            return Err("dst is NULL".to_owned());
        }
        let Size { width, height } = this.project.output;
        let frames = this.project.timeline.frames;
        if index >= frames {
            return Err(format!("frame {index} is past the last frame ({frames} frames)"));
        }
        let row = width as usize * 4;
        if stride < row {
            return Err(format!("stride {stride} is below the {row}-byte row"));
        }
        let len = stride * (height as usize - 1) + row;
        // SAFETY: per the contract.
        let dst = unsafe { std::slice::from_raw_parts_mut(dst, len) };
        this.renderer
            .render(&this.project, index, RenderView::Motion)
            .map_err(|e| e.to_string())?;
        pollster::block_on(this.renderer.read_rgba8(dst, stride)).map_err(|e| e.to_string())?;
        Ok(0)
    })
}

/// # Safety
/// `renderer` comes from `gb_burns_create` (not yet freed) or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_free(renderer: *mut GbBurns) {
    if !renderer.is_null() {
        // SAFETY: per the contract.
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(renderer) })));
    }
}

/// # Safety
/// `string` comes from this library or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gb_burns_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: per the contract.
        drop(unsafe { CString::from_raw(string) });
    }
}
