import Darwin
import Foundation
import GlitchboxKit

extension CLI {
    static func export(_ ws: Workspace, args: [String], cwd: URL,
                       environment: () throws -> ToolEnvironment) async throws -> Int32 {
        var p = Arguments(args)
        var s = ExportSettings()
        var output: String?
        var container: ExportContainer?
        var boxFit = FitMode.fit
        var box: (Int, Int)?

        // --settings first, so the other flags override it wherever they appear.
        if let i = args.firstIndex(of: "--settings") {
            guard i + 1 < args.count else { throw CLIError("--settings needs a value") }
            let url = URL(filePath: args[i + 1], relativeTo: cwd)
            do { s = try JSONDecoder().decode(ExportSettings.self, from: Data(contentsOf: url)) } catch {
                throw CLIError("cannot read export settings \(url.path): \(error.localizedDescription)")
            }
        }

        func choice<T>(_ flag: String, _ v: String, _ table: [String: T]) throws -> T {
            guard let t = table[v] else { throw CLIError("\(flag): expected \(table.keys.sorted().joined(separator: "|")), got '\(v)'") }
            return t
        }

        while p.i < args.count {
            if try p.parseCommon() { p.i += 1; continue }
            let a = p.flag
            switch a {
            case "--settings": _ = try p.value()
            case "-o", "--output": output = try p.value()
            case "--format":
                s.format = try choice(a, try p.value(), ["h264": .h264, "hevc": .hevc, "prores": .prores, "ffv1": .ffv1,
                                                        "gif": .gif, "png": .pngSequence])
            case "--quality": s.quality = try choice(a, try p.value(), ["good": .good, "high": .high, "max": .max])
            case "--encoder": s.h264Encoder = try choice(a, try p.value(), ["vt": .videoToolbox, "x264": .x264])
            case "--crf": s.x264CRF = try p.integer(a, in: 0...51)
            case "--x264-preset": s.x264Preset = try choice(a, try p.value(), Dictionary(uniqueKeysWithValues: H264Encoder.x264Presets.map { ($0, $0) }))
            case "--vt-quality": s.videoToolboxQuality = try p.integer(a, in: 1...100)
            case "--prores":
                s.proresProfile = try choice(a, try p.value(), ["lt": .lt, "422": .standard, "standard": .standard, "hq": .hq, "4444": .p4444])
            case "--container": container = try choice(a, try p.value(), ["mp4": .mp4, "mov": .mov])
            case "--size":
                let v = try p.value()
                if v == "native" { s.size = .asRendered; box = nil }
                else if let h = Int(v), h > 0 { s.size = .shortSide(h); box = nil }
                else if case let parts = v.split(separator: "x"), parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
                    box = (w, h)
                } else { throw CLIError("--size: expected native, a short side like 720, or WxH; got '\(v)'") }
            case "--fit": boxFit = try choice(a, try p.value(), ["fit": .fit, "fill": .fill, "stretch": .stretch])
            case "--no-upscale": s.allowUpscale = false
            case "--upscale": s.allowUpscale = true
            case "--audio":
                let v = try p.value()
                switch v {
                case "none": s.audio = .none
                case "source": s.audio = .source
                default: s.audio = .file(URL(filePath: v, relativeTo: cwd).standardizedFileURL.path)
                }
            case "--audio-codec":
                s.audioCodec = try choice(a, try p.value(), ["aac": .aac, "alac": .alac, "pcm16": .pcmS16, "pcm24": .pcmS24, "flac": .flac])
            case "--audio-bitrate": s.audioBitrate = try p.integer(a, in: 32...512)
            case "--gif-width":
                let v = try p.value()
                if v == "native" { s.gif.width = nil }
                else if let w = Int(v), w > 0 { s.gif.width = w }
                else { throw CLIError("--gif-width: expected a positive integer or 'native', got '\(v)'") }
            case "--gif-fps": s.gif.fps = try p.integer(a, in: 1...50)
            case "--dither": s.gif.dither = try choice(a, try p.value(), Dictionary(uniqueKeysWithValues: GIFDither.allCases.map { ($0.rawValue, $0) }))
            case "--bayer-scale": s.gif.bayerScale = try p.integer(a, in: 0...5)
            case "--palette": s.gif.palette = try choice(a, try p.value(), ["global": .global, "frame": .perFrame])
            case "--loop": s.gif.plays = try p.integer(a, in: 0...65535)
            default: throw CLIError("unknown flag: \(a)")
            }
            p.i += 1
        }
        if let box { s.size = .box(width: box.0, height: box.1, fit: boxFit) }
        guard let output else { throw CLIError("-o OUT is required") }
        let destination = URL(filePath: output, relativeTo: cwd).standardizedFileURL
        if let container { s.preferredContainer = container }
        else if s.format == .hevc { s.preferredContainer = destination.pathExtension.lowercased() == "mov" ? .mov : .mp4 }
        let chain = try loadChain(ws, p.chain, cwd: cwd)
        guard let input = p.input else { throw CLIError("INPUT is required") }
        let source = URL(filePath: input, relativeTo: cwd).standardizedFileURL
        let exporter = Exporter(env: try environment(), workspace: ws)
        let settings = s, render = p.settings

        let printer = ProgressPrinter(tty: isatty(STDERR_FILENO) == 1)
        let job = Task {
            let url = try await exporter.export(source: source, layers: chain.layers, render: render, settings: settings,
                                                to: destination, events: printer.show)
            print(url.path)
        }
        // Ctrl-C or SIGTERM cancels the job, and `job.value` returns once ffmpeg (in its own
        // process group, so the signal never reaches it) is gone and the partial deleted.
        let sources = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig)
            source.setEventHandler { job.cancel() }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }
        do {
            try await job.value
        } catch is CancellationError {
            StandardError.print("\ncancelled")
            return 130
        } catch let e as ExportError {
            for line in e.tail { StandardError.print("  \(line)") }
            throw e
        }
        return 0
    }
}
