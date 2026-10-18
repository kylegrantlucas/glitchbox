import Foundation

/// AVPlayer cannot play lossless MKV layers; an H.264 proxy is the only playback path.
public enum ProxyMaker {
    /// Tried in order. VideoToolbox is about 2× faster than libx264 (the encode is then bound by
    /// decoding the lossless layer); a bitrate target, not `-q:v`, keeps noisy layers from turning
    /// to mush. libx264 is the fallback when VideoToolbox can't open a session (no hardware
    /// encoder, unsupported frame size).
    static let encoders: [(name: String, arguments: [String])] = [
        ("h264_videotoolbox", ["-c:v", "h264_videotoolbox", "-b:v", "40M"]),
        ("libx264", ["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]),
    ]

    public static func proxy(for out: LayerOutput, env: ToolEnvironment) async throws -> URL {
        let fm = FileManager.default
        let proxy = out.dir.appending(path: "proxy.mp4")
        if fm.fileExists(atPath: proxy.path) { return proxy }
        guard let ffmpeg = env.which("ffmpeg") else { throw RenderError.commandNotFound(plugin: "proxy", command: "ffmpeg") }
        let partial = out.dir.appending(path: "proxy.partial-\(UUID().uuidString.prefix(8)).mp4")
        let log = out.dir.appending(path: "proxy.log")
        var code: Int32 = 0
        for (i, encoder) in encoders.enumerated() {
            if i > 0 { LayerRunner.append(log, "== \(encoders[i - 1].name) failed (exit \(code)); falling back to \(encoder.name) ==\n") }
            code = try await Spawner.run(
                executable: ffmpeg,
                arguments: ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", out.output.path, "-an",
                            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"] + encoder.arguments
                    + ["-pix_fmt", "yuv420p", "-movflags", "+faststart", "-y", partial.path],
                environment: env.variables, cwd: out.dir, log: log)
            if code == 0 { break }
            try? fm.removeItem(at: partial)
        }
        guard code == 0 else {
            throw RenderError.stepFailed(plugin: "proxy", step: "encode", code: code, log: log,
                                         tail: LayerRunner.tail(log, lines: 20))
        }
        if fm.fileExists(atPath: proxy.path) { try? fm.removeItem(at: partial) }
        else { try fm.moveItem(at: partial, to: proxy) }
        return proxy
    }
}
