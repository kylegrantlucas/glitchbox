import Foundation

/// The implicit first layer: trims, rescales, and normalizes the source to
/// constant-fps video-only FFV1. The fps normalization exists because
/// MPEG-1/2 (`mpeg2-mosh`) rejects non-standard rates.
public enum SourcePrep {
    public static let stillExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "webp"]

    public static func isStill(_ url: URL) -> Bool {
        stillExtensions.contains(url.pathExtension.lowercased())
    }

    /// Generated per settings; never written to `plugins/`.
    public static func manifest(settings: RenderSettings, still: Bool) -> PluginManifest {
        let duration = settings.duration ?? (still ? settings.stillDuration : -1)
        let params = [
            ParamSpec(key: "start", label: "Start", type: .float, default: .float(settings.start)),
            ParamSpec(key: "duration", label: "Duration", type: .float, default: .float(duration)),
            ParamSpec(key: "height", label: "Height", type: .int, default: .int(settings.height ?? 0)),
            ParamSpec(key: "fps", label: "FPS", type: .int, default: .int(settings.fps)),
            ParamSpec(key: "still", label: "Still", type: .bool, default: .bool(still)),
        ]
        var argv = ["ffmpeg", "-hide_banner", "-nostdin", "-loglevel", "error"]
        if still { argv += ["-loop", "1", "-framerate", "{p.fps}"] }
        if settings.start > 0 { argv += ["-ss", "{p.start}"] }
        if duration >= 0 { argv += ["-t", "{p.duration}"] }
        let scale = settings.height.map { "scale=-2:\($0):flags=lanczos" } ?? "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        argv += ["-i", "{in}", "-an", "-vf", "fps={p.fps},\(scale),format=yuv420p",
                 "-fflags", "+bitexact", "-flags:v", "+bitexact", "-map_metadata", "-1", "-map_chapters", "-1",
                 "-c:v", "ffv1", "-y", "{out}"]
        return PluginManifest(id: "source", name: "Source", summary: "Trim, scale, and normalize the source",
                              requires: ["ffmpeg"], params: params, steps: [PluginStep(name: "prepare", argv: argv)])
    }
}
