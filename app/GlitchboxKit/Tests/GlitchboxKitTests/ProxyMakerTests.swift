import Foundation
import Testing
@testable import GlitchboxKit

/// ProxyMaker against a stub `ffmpeg` that writes its argv to the output file
/// and fails when asked for VideoToolbox if `$STUB_NO_VT` is set.
final class ProxyMakerTests {
    let root: URL
    let layer: LayerOutput

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "gbk-proxy-\(UUID().uuidString)", directoryHint: .isDirectory)
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appending(path: "ffmpeg")
        try """
        #!/bin/sh
        for a; do
          if [ "$a" = h264_videotoolbox ] && [ -n "${STUB_NO_VT:-}" ]; then echo "vt: no session" >&2; exit 1; fi
          last=$a
        done
        echo "$*" > "$last"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let dir = root.appending(path: "layer", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        layer = LayerOutput(key: "k", dir: dir, output: dir.appending(path: "out.mkv"), cached: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func env(noVT: Bool) -> ToolEnvironment {
        var own = ["PATH": root.appending(path: "bin").path + ":/usr/bin:/bin"]
        if noVT { own["STUB_NO_VT"] = "1" }
        return ToolEnvironment(own: own, digest: "t")
    }

    @Test func prefersVideoToolbox() async throws {
        let url = try await ProxyMaker.proxy(for: layer, env: env(noVT: false))
        let argv = try String(contentsOf: url, encoding: .utf8)
        #expect(argv.contains("h264_videotoolbox"))
        #expect(!argv.contains("libx264"))
    }

    @Test func fallsBackToLibx264WhenVideoToolboxFails() async throws {
        let url = try await ProxyMaker.proxy(for: layer, env: env(noVT: true))
        #expect(url == layer.dir.appending(path: "proxy.mp4"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("libx264"))
        let log = try String(contentsOf: layer.dir.appending(path: "proxy.log"), encoding: .utf8)
        #expect(log.contains("falling back to libx264"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: layer.dir.path).filter { $0.hasPrefix("proxy.partial") }
        #expect(leftovers.isEmpty)
    }
}
