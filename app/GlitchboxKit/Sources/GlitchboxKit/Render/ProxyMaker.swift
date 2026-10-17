import Foundation

/// AVPlayer cannot play FFV1/MKV; an H.264 proxy is the only playback path.
public enum ProxyMaker {
    public static func proxy(for out: LayerOutput, env: ToolEnvironment) async throws -> URL {
        let fm = FileManager.default
        let proxy = out.dir.appending(path: "proxy.mp4")
        if fm.fileExists(atPath: proxy.path) { return proxy }
        guard let ffmpeg = env.which("ffmpeg") else { throw RenderError.commandNotFound(plugin: "proxy", command: "ffmpeg") }
        let partial = out.dir.appending(path: "proxy.partial-\(UUID().uuidString.prefix(8)).mp4")
        let log = out.dir.appending(path: "proxy.log")
        let code = try await Spawner.run(
            executable: ffmpeg,
            arguments: ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", out.output.path, "-an",
                        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-preset", "veryfast",
                        "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-y", partial.path],
            environment: env.variables, cwd: out.dir, log: log)
        guard code == 0 else {
            try? fm.removeItem(at: partial)
            throw RenderError.stepFailed(plugin: "proxy", step: "encode", code: code, log: log,
                                         tail: LayerRunner.tail(log, lines: 20))
        }
        if fm.fileExists(atPath: proxy.path) { try? fm.removeItem(at: partial) }
        else { try fm.moveItem(at: partial, to: proxy) }
        return proxy
    }
}
