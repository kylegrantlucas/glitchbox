import CryptoKit
import Darwin
import Foundation
import GlitchboxKit
import Testing
@testable import GlitchboxInProcess

/// Perf-pass benchmark (opt-in, skipped unless GB_BENCH is set): renders one plugin layer
/// over GB_BENCH_SRC (default /tmp/gbperf/src/clip1080.mp4, 5 s) in-process and prints
/// `BENCH <plugin> wall cpu peak_footprint_mb`. The source layer is rendered first (cached in
/// GB_BENCH_CACHE across runs) and excluded from the timing; the plugin layer is removed first.
/// Run each plugin in its own process so the lifetime footprint peak belongs to it:
///   GB_BENCH=bender swift test -c release -Xswiftc -enable-testing --filter InProcessBench
struct InProcessBench {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GB_BENCH"] != nil))
    func renderOnePlugin() async throws {
        let e = ProcessInfo.processInfo.environment
        let plugin = e["GB_BENCH"]!
        let fm = FileManager.default
        let dir = URL(filePath: e["GB_BENCH_DIR"] ?? "/tmp/gbperf-ios", directoryHint: .isDirectory)
        let cache = dir.appending(path: "cache", directoryHint: .isDirectory)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let repo = Fixture.repo
        let scriptsParent = dir.appending(path: "ffglitch-scripts", directoryHint: .isDirectory)
        if !fm.fileExists(atPath: scriptsParent.path) {
            try fm.createDirectory(at: scriptsParent, withIntermediateDirectories: true)
            let tarball = try #require(try fm.contentsOfDirectory(atPath: repo.appending(path: "build/downloads").path)
                .first { $0.hasPrefix("ffglitch-scripts-") && $0.hasSuffix(".tar.gz") })
            _ = try Fixture.run("/usr/bin/tar", ["-xzf", repo.appending(path: "build/downloads/\(tarball)").path,
                                                 "-C", scriptsParent.path])
        }
        let scripts = try scriptsParent.appending(path: #require(fm.contentsOfDirectory(atPath: scriptsParent.path).first),
                                                  directoryHint: .isDirectory)
        let contents = dir.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let manifest = contents.appending(path: "toolchain.json")
        let json: [String: Any] = ["schema": 1, "digest": "inprocess-bench", "tools": ["ffmpeg": "8.1.2"],
                                   "path": [], "environment": ["FFGLITCH_SCRIPTS": scripts.path]]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: manifest)
        let toolchain = try Toolchain.load(manifest: manifest, contents: contents, cacheDir: cache)
        let env = toolchain.toolEnvironment(base: repo, parent: [:], runner: InProcessRunner())
        let workspace = Workspace(base: repo, user: dir.appending(path: "user", directoryHint: .isDirectory), cache: cache)
        let renderer = Renderer(env: env, workspace: workspace)
        let still = plugin == "still-motion"
        let src = URL(filePath: still ? (e["GB_BENCH_STILL"] ?? "/tmp/gbperf/src/still.jpg")
                                      : (e["GB_BENCH_SRC"] ?? "/tmp/gbperf/src/clip1080.mp4"))
        let settings = RenderSettings(duration: 5)
        let ts = Date(), cs = Self.cpu()
        _ = try await renderer.render(source: src, layers: [], settings: settings, emit: { _ in })
        if plugin == "source" {
            print(String(format: "BENCH source\t%.2f\t%.2f\t%.0f\t-", Date().timeIntervalSince(ts), Self.cpu() - cs,
                         Self.peakFootprintMB()))
            return
        }
        for name in try fm.contentsOfDirectory(atPath: workspace.layersDir.path) where name.hasPrefix("\(plugin)-") {
            try fm.removeItem(at: workspace.layersDir.appending(path: name))
        }
        var params: [String: ParamValue] = [:]
        if let p = e["GB_BENCH_PARAMS"], !p.isEmpty, let d = p.data(using: .utf8) {
            params = try JSONDecoder().decode([String: ParamValue].self, from: d)
        }
        let cpu0 = Self.cpu(), t0 = Date()
        let (out, _) = try await renderer.render(source: src, layers: [LayerSpec(plugin: plugin, params: params)],
                                                 settings: settings, emit: { _ in })
        let wall = Date().timeIntervalSince(t0), cpu = Self.cpu() - cpu0
        print(String(format: "BENCH %@\t%.2f\t%.2f\t%.0f\t%@", plugin, wall, cpu, Self.peakFootprintMB(), out.output.path))
    }

    static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Lifetime peak phys_footprint (what jetsam counts).
    static func peakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1048576 : -1
    }
}

struct DecodeProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GB_DECODE"] != nil))
    func decode() throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["GB_DECODE"]!)
        let fmt = ProcessInfo.processInfo.environment["GB_FMT"] ?? "yuv420p"
        let t0 = Date(), c0 = InProcessBench.cpu()
        let d = try MediaDecoder(url: url, pixelFormat: fmt)
        var n = 0
        var md5 = Insecure.MD5()
        while let f = try d.next() {
            let planes = fmt == "yuv420p" ? 3 : 1
            for p in 0..<planes {
                let (ptr, ls) = p == 0 ? (f.data.0!, f.linesize.0) : p == 1 ? (f.data.1!, f.linesize.1) : (f.data.2!, f.linesize.2)
                let rows = p == 0 ? Int(f.height) : (fmt == "yuv420p" ? Int(f.height) / 2 : Int(f.height))
                let bytes = p == 0 ? (fmt == "yuv420p" ? Int(f.width) : Int(f.width) * 4) : Int(f.width) / 2
                for y in 0..<rows { md5.update(bufferPointer: UnsafeRawBufferPointer(start: ptr + y * Int(ls), count: bytes)) }
            }
            n += 1
        }
        print(String(format: "DECODE %d frames %.2fs cpu %.2f md5 %@", n, Date().timeIntervalSince(t0), InProcessBench.cpu() - c0, md5.finalize().map { String(format: "%02x", $0) }.joined()))
    }
}

struct HashProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GB_HASH"] != nil))
    func hash() async throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["GB_HASH"]!)
        let before = InProcessBench.peakFootprintMB()
        if ProcessInfo.processInfo.environment["GB_HASH_POOL"] != nil {
            let fh = try FileHandle(forReadingFrom: url)
            var hasher = SHA256()
            while try autoreleasepool(invoking: {
                guard let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }) {}
            _ = hasher.finalize()
        } else {
            _ = try Hashing.sha256Hex(fileAt: url)
        }
        print(String(format: "HASH peak before %.0f after %.0f", before, InProcessBench.peakFootprintMB()))
    }
}
