import Foundation
import GlitchboxKit
import Testing
@testable import GlitchboxInProcess

/// Shared, built once: synthetic clips, the unpacked FFglitch scripts, an in-process tool
/// environment over the repo library, and the macOS CLI as the reference.
struct Fixture: Sendable {
    /// The checkout (library base: plugins/, scripts/, pipelines/).
    static let repo = URL(filePath: #filePath).deletingLastPathComponent()  // GlitchboxInProcessTests
        .deletingLastPathComponent().deletingLastPathComponent()           // Tests, GlitchboxInProcess
        .deletingLastPathComponent().deletingLastPathComponent()           // app, repo
    /// The prebuilt macOS toolchain used as the reference oracle (read-only).
    static let macToolchain = URL(filePath: "/Users/kyle/Development/glitchbox/build/Glitchbox.app/Contents",
                                  directoryHint: .isDirectory)
    static let cli = repo.appending(path: "app/GlitchboxKit/.build/debug/glitchbox")

    let dir: URL
    let env: ToolEnvironment
    let workspace: Workspace
    /// 2 s, 320×240 @ 30 fps, H.264 + AAC stereo.
    let clip: URL
    /// 20 s, 1280×720 @ 30 fps, for cancellation and concurrency.
    let longClip: URL

    static let shared = Task<Fixture, any Error> { try await make() }

    static func get() async throws -> Fixture { try await shared.value }

    private static func make() async throws -> Fixture {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "glitchbox-inprocess-tests", directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // FFglitch scripts from the pinned download, as the macOS bundle ships them.
        let tarball = try #require(try fm.contentsOfDirectory(atPath: repo.appending(path: "build/downloads").path)
            .first { $0.hasPrefix("ffglitch-scripts-") && $0.hasSuffix(".tar.gz") })
        let scriptsParent = dir.appending(path: "ffglitch-scripts", directoryHint: .isDirectory)
        try fm.createDirectory(at: scriptsParent, withIntermediateDirectories: true)
        let rc = try run("/usr/bin/tar", ["-xzf", repo.appending(path: "build/downloads/\(tarball)").path,
                                          "-C", scriptsParent.path])
        try #require(rc.status == 0, "tar: \(rc.output)")
        let scripts = scriptsParent.appending(path: String(tarball.dropLast(".tar.gz".count)), directoryHint: .isDirectory)

        // toolchain.json as the iOS app writes it: no PATH entries, scripts by environment.
        let contents = dir.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let manifest = contents.appending(path: "toolchain.json")
        let json: [String: Any] = ["schema": 1, "digest": "inprocess-tests", "tools": ["ffmpeg": "8.1.2"],
                                   "path": [], "environment": ["FFGLITCH_SCRIPTS": scripts.path]]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: manifest)
        let cache = dir.appending(path: "cache", directoryHint: .isDirectory)
        let toolchain = try Toolchain.load(manifest: manifest, contents: contents, cacheDir: cache)
        let env = toolchain.toolEnvironment(base: repo, parent: [:], runner: InProcessRunner())
        let workspace = Workspace(base: repo, user: dir.appending(path: "user", directoryHint: .isDirectory), cache: cache)

        let clip = dir.appending(path: "clip.mp4")
        let longClip = dir.appending(path: "long.mp4")
        for (url, size, seconds) in [(clip, "320x240", 2), (longClip, "1280x720", 20)] {
            let code = try await env.runner.run(ToolInvocation(command: "ffmpeg", arguments: [
                "-hide_banner", "-nostdin", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30:duration=\(seconds)",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)",
                "-ac", "2", "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", "-shortest", "-y", url.path,
            ], environment: [:], cwd: dir, log: dir.appending(path: "fixture.log")))
            try #require(code == 0, "fixture ffmpeg failed: \(log(dir.appending(path: "fixture.log")))")
        }
        return Fixture(dir: dir, env: env, workspace: workspace, clip: clip, longClip: longClip)
    }

    /// Renders `layers` over `source` in-process.
    func render(_ layers: [LayerSpec], source: URL? = nil, settings: RenderSettings = RenderSettings(),
                emit: @Sendable (RenderEvent) -> Void = { _ in }) async throws -> (output: LayerOutput, sourceAudio: URL?) {
        try await Renderer(env: env, workspace: workspace).render(source: source ?? clip, layers: layers,
                                                                  settings: settings, emit: emit)
    }

    /// Renders `layers` over `clip` with the macOS CLI and prebuilt toolchain; returns the
    /// final out.mkv and the CLI's cache dir.
    func renderOnMac(_ layers: [LayerSpec], name: String) throws -> (output: URL, cache: URL) {
        let fm = FileManager.default
        try #require(fm.isExecutableFile(atPath: Self.cli.path),
                     "build the reference CLI first: (cd app/GlitchboxKit && swift build)")
        let chain = dir.appending(path: "chain-\(name).json")
        try Workspace.write(ChainPreset(name: name, layers: layers), to: chain)
        let cache = dir.appending(path: "mac-cache", directoryHint: .isDirectory)
        let result = try Self.run(Self.cli.path, ["--root", Self.repo.path, "--toolchain", Self.macToolchain.path,
                                                  "render", "--chain", chain.path, clip.path],
                                  environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                                "GLITCHBOX_CACHE_DIR": cache.path,
                                                "GLITCHBOX_DATA_DIR": dir.appending(path: "mac-user").path])
        try #require(result.status == 0, "macOS CLI render failed: \(result.output)")
        let path = try #require(result.output.split(separator: "\n").last { $0.hasSuffix("out.mkv") })
        return (URL(filePath: String(path)), cache)
    }

    /// The single `source-*` layer directory under a cache.
    static func sourceLayer(in cache: URL) throws -> URL {
        let layers = cache.appending(path: "layers", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: layers.path)
            .filter { $0.hasPrefix("source-") && !$0.contains(".") }
        try #require(names.count == 1, "expected one source layer in \(layers.path), found \(names)")
        return layers.appending(path: names[0], directoryHint: .isDirectory)
    }

    /// Leftover partial or failed layer directories.
    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.layersDir.path)
            .filter { $0.contains(".partial-") }
    }

    static func run(_ exe: String, _ args: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func log(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "(no log)"
    }

    /// Frame count, size, and pixel format of a video, decoded natively.
    static func shape(_ url: URL) throws -> (frames: Int, width: Int, height: Int, pixelFormat: Int32) {
        let d = try MediaDecoder(url: url, pixelFormat: "rgba")
        var frames = 0
        while try d.next() != nil { frames += 1 }
        let info = d.info
        return (frames, Int(info.width), Int(info.height), info.pix_fmt)
    }
}

/// Every test shares the fixture and the tool libraries; running them one at a time keeps
/// timing assertions meaningful.
@Suite(.serialized) struct InProcessTests {}
