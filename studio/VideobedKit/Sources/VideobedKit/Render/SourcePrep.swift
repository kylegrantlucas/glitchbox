import Foundation

/// The implicit first layer: trims, rescales, and normalizes the source to
/// constant-fps video-only FFV1, and extracts its audio (same trim) to
/// `audio.wav` beside it for layers that react to sound. The fps normalization exists because
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
        var steps = [PluginStep(name: "prepare", argv: argv)]
        if !still { steps.append(PluginStep(name: "audio", script: audioScript(settings: settings, duration: duration))) }
        return PluginManifest(id: "source", name: "Source", summary: "Trim, scale, and normalize the source",
                              requires: ["ffmpeg", "ffprobe"], params: params, steps: steps)
    }

    /// File name of the trimmed source audio inside the source layer's directory.
    public static let audioFileName = "audio.wav"

    /// Extracts the first audio track, trimmed exactly like the video, next to
    /// `out.mkv`. Sources without audio produce no file.
    private static func audioScript(settings: RenderSettings, duration: Double) -> String {
        var trim: [String] = []
        if settings.start > 0 { trim += ["-ss", String(settings.start)] }
        if duration >= 0 { trim += ["-t", String(duration)] }
        return """
        if [ -n "$(ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$VB_IN")" ]; then
          ffmpeg -hide_banner -nostdin -loglevel error \(trim.joined(separator: " ")) -i "$VB_IN" -map 0:a:0 -vn \\
            -c:a pcm_s16le -fflags +bitexact -flags:a +bitexact -map_metadata -1 \\
            -y "$(dirname "$VB_OUT")/\(audioFileName)"
        fi
        """
    }
}
