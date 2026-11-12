//! C ABI over the media-free effect cores behind Glitchbox's analog-pass
//! (ntsc-rs), bender (bender-rs), and reactive-vcr plugins, for hosts that
//! cannot spawn the GStreamer CLIs (iOS). `include/glitchbox_fx.h` is the
//! contract: every function there documents how a host must drive it to
//! reproduce the macOS CLI's output.
//!
//! Every entry point catches panics; errors come back as strings allocated
//! here and released with `gbfx_string_free`. Handles are `Send + Sync`: an
//! ntsc handle is immutable, and bender/reactive-vcr handles serialize their
//! per-stream state behind a mutex.

pub mod bend;
pub mod ntsc;
pub mod reactive;

use std::ffi::{CStr, CString, c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

pub use bend::Bender;
pub use ntsc::Ntsc;
pub use reactive::Reactive;

/// Status codes returned by the frame functions.
pub const GBFX_OK: c_int = 0;
pub const GBFX_ERROR: c_int = -1;
pub const GBFX_DROPPED: c_int = 1;

/// Set once any ntsc-rs work has started: both ntsc-rs revisions build their
/// private rayon pool on first use, reading `RAYON_NUM_THREADS` then.
static NTSC_POOL_STARTED: AtomicBool = AtomicBool::new(false);
static NTSC_POOL_CONFIG: Mutex<()> = Mutex::new(());

pub(crate) fn mark_ntsc_pool_started() {
    if !NTSC_POOL_STARTED.load(Ordering::Acquire) {
        let _guard = NTSC_POOL_CONFIG.lock().unwrap_or_else(|e| e.into_inner());
        NTSC_POOL_STARTED.store(true, Ordering::Release);
    }
}

/// Sets the ntsc-rs worker count (0 = ntsc-rs's default, the physical core
/// count). Must precede the first ntsc-rs frame in the process.
pub fn set_ntsc_threads(threads: u32) -> Result<(), String> {
    let _guard = NTSC_POOL_CONFIG.lock().unwrap_or_else(|e| e.into_inner());
    if NTSC_POOL_STARTED.load(Ordering::Acquire) {
        return Err("the ntsc-rs thread pool is already running; set its size before the first ntsc-rs or reactive-vcr frame".into());
    }
    // SAFETY: documented contract (glitchbox_fx.h): called at startup, before
    // other threads read the environment.
    unsafe {
        if threads == 0 {
            std::env::remove_var("RAYON_NUM_THREADS");
        } else {
            std::env::set_var("RAYON_NUM_THREADS", threads.to_string());
        }
    }
    Ok(())
}

/// A rayon pool for one handle; `0` threads means rayon's default.
pub(crate) fn build_pool(threads: u32, name: &'static str) -> Result<rayon::ThreadPool, String> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(threads as usize)
        .thread_name(move |i| format!("gbfx-{name}-{i}"))
        .build()
        .map_err(|e| format!("building the {name} thread pool: {e}"))
}

/// Frame index the ntsc-rs and bender GStreamer filters derive from a buffer
/// timestamp: floor(fps_n * (pts_ns + 100) / fps_d / 1e9).
pub fn pts_frame_index(pts_ns: u64, fps_n: i32, fps_d: i32) -> Option<u64> {
    if fps_n <= 0 || fps_d <= 0 {
        return None;
    }
    let n = fps_n as u128 * (u128::from(pts_ns) + 100) / fps_d as u128;
    Some((n / 1_000_000_000) as u64)
}

// --- FFI plumbing ----------------------------------------------------------------

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        format!("panic: {s}")
    } else if let Some(s) = payload.downcast_ref::<String>() {
        format!("panic: {s}")
    } else {
        "panic".to_string()
    }
}

fn into_c_string(s: String) -> *mut c_char {
    let bytes: Vec<u8> = s.into_bytes().into_iter().filter(|&b| b != 0).collect();
    CString::new(bytes).expect("NULs removed").into_raw()
}

unsafe fn set_error(error: *mut *mut c_char, message: String) {
    if !error.is_null() {
        unsafe { *error = into_c_string(message) };
    }
}

/// Runs `f`, catching panics; on failure writes the message to `*error`.
unsafe fn guard<T>(error: *mut *mut c_char, fallback: T, f: impl FnOnce() -> Result<T, String>) -> T {
    if !error.is_null() {
        unsafe { *error = std::ptr::null_mut() };
    }
    let result = catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|p| Err(panic_message(p)));
    match result {
        Ok(v) => v,
        Err(message) => {
            unsafe { set_error(error, message) };
            fallback
        }
    }
}

unsafe fn c_str<'a>(p: *const c_char, what: &str) -> Result<&'a str, String> {
    if p.is_null() {
        return Err(format!("{what} is NULL"));
    }
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map_err(|_| format!("{what} is not valid UTF-8"))
}

unsafe fn opt_c_str<'a>(p: *const c_char, what: &str) -> Result<Option<&'a str>, String> {
    if p.is_null() { Ok(None) } else { unsafe { c_str(p, what) }.map(Some) }
}

/// A byte slice covering `height` rows of `stride` bytes (`stride >= row_bytes`).
unsafe fn frame_slice<'a>(p: *const u8, stride: usize, row_bytes: usize, height: usize, what: &str) -> Result<&'a [u8], String> {
    let len = frame_len(stride, row_bytes, height, what)?;
    if p.is_null() {
        return Err(format!("{what} is NULL"));
    }
    Ok(unsafe { std::slice::from_raw_parts(p, len) })
}

unsafe fn frame_slice_mut<'a>(p: *mut u8, stride: usize, row_bytes: usize, height: usize, what: &str) -> Result<&'a mut [u8], String> {
    let len = frame_len(stride, row_bytes, height, what)?;
    if p.is_null() {
        return Err(format!("{what} is NULL"));
    }
    Ok(unsafe { std::slice::from_raw_parts_mut(p, len) })
}

fn frame_len(stride: usize, row_bytes: usize, height: usize, what: &str) -> Result<usize, String> {
    if height == 0 || row_bytes == 0 {
        return Err(format!("{what}: empty frame"));
    }
    if stride < row_bytes {
        return Err(format!("{what}: stride {stride} is shorter than a row ({row_bytes} bytes)"));
    }
    stride
        .checked_mul(height)
        .ok_or_else(|| format!("{what}: frame size overflows"))
}

unsafe fn handle<'a, T>(p: *const T, what: &str) -> Result<&'a T, String> {
    if p.is_null() {
        Err(format!("{what} handle is NULL"))
    } else {
        Ok(unsafe { &*p })
    }
}

// --- Exported C API ----------------------------------------------------------------

/// Frees a string returned by this library. NULL is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { CString::from_raw(s) })));
    }
}

/// Library version (static string, do not free).
#[unsafe(no_mangle)]
pub extern "C" fn gbfx_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_ntsc_set_threads(threads: u32, error: *mut *mut c_char) -> c_int {
    unsafe { guard(error, GBFX_ERROR, || set_ntsc_threads(threads).map(|()| GBFX_OK)) }
}

#[unsafe(no_mangle)]
pub extern "C" fn gbfx_pts_frame_index(pts_ns: u64, fps_n: i32, fps_d: i32) -> i64 {
    catch_unwind(|| pts_frame_index(pts_ns, fps_n, fps_d).map_or(-1, |n| n.min(i64::MAX as u64) as i64)).unwrap_or(-1)
}

// ntsc-rs

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_ntsc_new(settings_json: *const c_char, error: *mut *mut c_char) -> *mut Ntsc {
    unsafe {
        guard(error, std::ptr::null_mut(), || {
            let json = c_str(settings_json, "settings_json")?;
            Ntsc::from_json(json).map(|n| Box::into_raw(Box::new(n)))
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_ntsc_free(ntsc: *mut Ntsc) {
    if !ntsc.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(ntsc) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_ntsc_settings_json(ntsc: *const Ntsc, error: *mut *mut c_char) -> *mut c_char {
    unsafe { guard(error, std::ptr::null_mut(), || Ok(into_c_string(handle(ntsc, "ntsc")?.settings_json()?))) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_ntsc_scaled_size(width: u32, height: u32, scanlines: u32, out_width: *mut u32, out_height: *mut u32) -> c_int {
    catch_unwind(AssertUnwindSafe(|| match ntsc::scaled_size(width, height, scanlines) {
        Some((w, h)) if !out_width.is_null() && !out_height.is_null() => {
            unsafe {
                *out_width = w;
                *out_height = h;
            }
            GBFX_OK
        }
        _ => GBFX_ERROR,
    }))
    .unwrap_or(GBFX_ERROR)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_ntsc_apply(
    ntsc: *const Ntsc,
    src: *const u16,
    src_stride: usize,
    dst: *mut u16,
    dst_stride: usize,
    width: u32,
    height: u32,
    frame_index: u64,
    error: *mut *mut c_char,
) -> c_int {
    unsafe {
        guard(error, GBFX_ERROR, || {
            let ntsc = handle(ntsc, "ntsc")?;
            let (w, h) = (width as usize, height as usize);
            let row = w.checked_mul(8).ok_or("width overflows")?;
            if src_stride % 2 != 0 || dst_stride % 2 != 0 || (src as usize) % 2 != 0 || (dst as usize) % 2 != 0 {
                return Err("16-bit frames need 2-byte aligned pointers and even strides".into());
            }
            let s = frame_slice(src.cast(), src_stride, row, h, "src")?;
            let d = frame_slice_mut(dst.cast(), dst_stride, row, h, "dst")?;
            let s16 = std::slice::from_raw_parts(s.as_ptr().cast::<u16>(), s.len() / 2);
            let d16 = std::slice::from_raw_parts_mut(d.as_mut_ptr().cast::<u16>(), d.len() / 2);
            ntsc.apply_xrgb16(s16, src_stride, d16, dst_stride, w, h, frame_index)?;
            Ok(GBFX_OK)
        })
    }
}

// bender

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_bender_new(
    preset_json: *const c_char,
    sets: *const *const c_char,
    set_count: usize,
    seed: *const i32,
    threads: u32,
    error: *mut *mut c_char,
) -> *mut Bender {
    unsafe {
        guard(error, std::ptr::null_mut(), || {
            let preset = opt_c_str(preset_json, "preset_json")?;
            let mut overrides = Vec::with_capacity(set_count);
            if set_count > 0 {
                if sets.is_null() {
                    return Err("sets is NULL but set_count > 0".into());
                }
                for i in 0..set_count {
                    overrides.push(c_str(*sets.add(i), "sets[i]")?);
                }
            }
            let seed = if seed.is_null() { None } else { Some(*seed) };
            Bender::new(preset, &overrides, seed, threads).map(|b| Box::into_raw(Box::new(b)))
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_bender_free(bender: *mut Bender) {
    if !bender.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(bender) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_bender_preset_json(bender: *const Bender, error: *mut *mut c_char) -> *mut c_char {
    unsafe { guard(error, std::ptr::null_mut(), || Ok(into_c_string(handle(bender, "bender")?.preset_json()))) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_bender_reset(bender: *const Bender, error: *mut *mut c_char) -> c_int {
    unsafe {
        guard(error, GBFX_ERROR, || {
            handle(bender, "bender")?.reset();
            Ok(GBFX_OK)
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_bender_scaled_size(width: u32, height: u32, scanlines: u32, out_width: *mut u32, out_height: *mut u32) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        if out_width.is_null() || out_height.is_null() || width == 0 || height == 0 {
            return GBFX_ERROR;
        }
        let (w, h) = bend::scaled_size(width, height, scanlines);
        unsafe {
            *out_width = w;
            *out_height = h;
        }
        GBFX_OK
    }))
    .unwrap_or(GBFX_ERROR)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_bender_apply(
    bender: *const Bender,
    src: *const u8,
    src_stride: usize,
    dst: *mut u8,
    dst_stride: usize,
    width: u32,
    height: u32,
    frame_index: u64,
    error: *mut *mut c_char,
) -> c_int {
    unsafe {
        guard(error, GBFX_ERROR, || {
            let bender = handle(bender, "bender")?;
            let (w, h) = (width as usize, height as usize);
            let row = w.checked_mul(4).ok_or("width overflows")?;
            let s = frame_slice(src, src_stride, row, h, "src")?;
            let d = frame_slice_mut(dst, dst_stride, row, h, "dst")?;
            bender.apply_rgba8(s, src_stride, d, dst_stride, w, h, frame_index)?;
            Ok(GBFX_OK)
        })
    }
}

// reactive-vcr

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_reactive_new(
    mapping_toml: *const c_char,
    base_dir: *const c_char,
    samples: *const f32,
    sample_count: usize,
    video_width: u32,
    video_height: u32,
    fps_n: i32,
    fps_d: i32,
    duration_s: f64,
    threads: u32,
    error: *mut *mut c_char,
) -> *mut Reactive {
    unsafe {
        guard(error, std::ptr::null_mut(), || {
            let toml = c_str(mapping_toml, "mapping_toml")?;
            let base = c_str(base_dir, "base_dir")?;
            let samples = if sample_count == 0 {
                &[][..]
            } else if samples.is_null() {
                return Err("samples is NULL".into());
            } else {
                std::slice::from_raw_parts(samples, sample_count)
            };
            Reactive::new(
                toml,
                std::path::Path::new(base),
                samples,
                reactive::VideoFacts { width: video_width, height: video_height, fps_n, fps_d, duration_s },
                threads,
            )
            .map(|r| Box::into_raw(Box::new(r)))
        })
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_reactive_free(reactive: *mut Reactive) {
    if !reactive.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(reactive) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_reactive_frame_count(reactive: *const Reactive) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        if reactive.is_null() { 0 } else { unsafe { &*reactive }.frame_count() as u64 }
    }))
    .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_reactive_frame_size(reactive: *const Reactive, out_width: *mut u32, out_height: *mut u32) -> c_int {
    catch_unwind(AssertUnwindSafe(|| {
        if reactive.is_null() || out_width.is_null() || out_height.is_null() {
            return GBFX_ERROR;
        }
        let (w, h) = unsafe { &*reactive }.frame_size();
        unsafe {
            *out_width = w;
            *out_height = h;
        }
        GBFX_OK
    }))
    .unwrap_or(GBFX_ERROR)
}

#[unsafe(no_mangle)]
pub extern "C" fn gbfx_reactive_frame_index(stream_time_ns: u64, fps_n: i32, fps_d: i32) -> i64 {
    catch_unwind(|| reactive::frame_index(stream_time_ns, fps_n, fps_d).map_or(-1, |n| n.min(i64::MAX as usize) as i64)).unwrap_or(-1)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gbfx_reactive_apply(
    reactive: *const Reactive,
    src: *const u8,
    src_stride: usize,
    dst: *mut u8,
    dst_stride: usize,
    width: u32,
    height: u32,
    frame_index: u64,
    error: *mut *mut c_char,
) -> c_int {
    unsafe {
        guard(error, GBFX_ERROR, || {
            let reactive = handle(reactive, "reactive")?;
            let (w, h) = (width as usize, height as usize);
            let row = w.checked_mul(3).ok_or("width overflows")?;
            let s = frame_slice(src, src_stride, row, h, "src")?;
            let d = frame_slice_mut(dst, dst_stride, row, h, "dst")?;
            let frame = usize::try_from(frame_index).map_err(|_| "frame_index overflows")?;
            Ok(if reactive.apply_rgb24(s, src_stride, d, dst_stride, w, h, frame)? {
                GBFX_OK
            } else {
                GBFX_DROPPED
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    #[test]
    fn pts_index_matches_the_gstreamer_filters() {
        // Exact videorate timestamps count up; Matroska's millisecond ones repeat.
        assert_eq!(pts_frame_index(33_333_333, 30, 1), Some(1));
        assert_eq!(pts_frame_index(33_000_000, 30, 1), Some(0));
        assert_eq!(pts_frame_index(67_000_000, 30, 1), Some(2));
        assert_eq!(pts_frame_index(1_001_000_000, 30000, 1001), Some(30));
        assert_eq!(pts_frame_index(5, 0, 1), None);
        assert_eq!(reactive::frame_index(32_600_000, 30, 1), Some(1));
        assert_eq!(reactive::frame_index(0, 30, 0), None);
    }

    #[test]
    fn scaled_sizes_follow_each_cli() {
        assert_eq!(ntsc::scaled_size(1920, 1080, 480), Some((853, 480)));
        assert_eq!(ntsc::scaled_size(0, 1080, 480), None);
        assert_eq!(bend::scaled_size(1920, 1080, 480), (854, 480));
        assert_eq!(bend::scaled_size(321, 241, 0), (322, 242));
    }

    #[test]
    fn errors_come_back_as_strings() {
        let mut error = ptr::null_mut();
        let ntsc = unsafe { gbfx_ntsc_new(c"{\"version\": 2}".as_ptr(), &mut error) };
        assert!(ntsc.is_null());
        let message = unsafe { CStr::from_ptr(error) }.to_str().unwrap().to_owned();
        assert!(message.contains("version"), "{message}");
        unsafe { gbfx_string_free(error) };

        let set = c"no.such=1";
        let sets = [set.as_ptr()];
        let bender = unsafe { gbfx_bender_new(ptr::null(), sets.as_ptr(), 1, ptr::null(), 1, &mut error) };
        assert!(bender.is_null());
        assert!(!error.is_null());
        unsafe { gbfx_string_free(error) };
    }

    #[test]
    fn short_strides_are_rejected_not_read_past() {
        let bender = Bender::new(None, &[], Some(1), 1).unwrap();
        let mut error = ptr::null_mut();
        let src = vec![0u8; 16];
        let mut dst = vec![0u8; 16];
        let rc = unsafe {
            gbfx_bender_apply(&bender, src.as_ptr(), 4, dst.as_mut_ptr(), 8, 2, 2, 0, &mut error)
        };
        assert_eq!(rc, GBFX_ERROR);
        unsafe { gbfx_string_free(error) };
    }

    #[test]
    fn ntsc_threads_cannot_change_once_running() {
        let ntsc = Ntsc::from_json(r#"{"version": 1}"#).unwrap();
        let src = vec![0u16; 8 * 4 * 4];
        let mut dst = vec![0u16; 8 * 4 * 4];
        ntsc.apply_xrgb16(&src, 8 * 8, &mut dst, 8 * 8, 8, 4, 0).unwrap();
        assert!(set_ntsc_threads(2).is_err());
    }

    #[test]
    fn reactive_drops_frames_past_the_selection() {
        let samples = vec![0.25f32; 48_000];
        let rv = Reactive::new(
            "[[modulate]]\ntarget = \"snow_intensity\"\nsource = \"rms\"\n",
            std::path::Path::new("."),
            &samples,
            reactive::VideoFacts { width: 9, height: 7, fps_n: 10, fps_d: 1, duration_s: 0.5 },
            1,
        )
        .unwrap();
        assert_eq!(rv.frame_count(), 5);
        assert_eq!(rv.frame_size(), (8, 6));
        let src = vec![128u8; 8 * 6 * 3];
        let mut dst = vec![0u8; 8 * 6 * 3];
        assert!(rv.apply_rgb24(&src, 24, &mut dst, 24, 8, 6, 4).unwrap());
        assert!(!rv.apply_rgb24(&src, 24, &mut dst, 24, 8, 6, 5).unwrap());
    }
}
