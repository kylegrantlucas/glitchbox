import Foundation

/// What `ffprobe` reports about a file's first video and audio streams.
public struct MediaProbe: Hashable, Sendable {
    public struct Video: Hashable, Sendable {
        /// Coded size, before rotation and SAR.
        public var width: Int
        public var height: Int
        public var sarNumerator: Int
        public var sarDenominator: Int
        /// Display-matrix rotation in degrees (ffmpeg autorotates on decode).
        public var rotation: Int
        public var pixelFormat: String
        public var frameRate: Double?
        /// ffprobe names (`bt709`, `smpte170m`, ...); nil when unknown or unspecified.
        public var colorPrimaries: String?
        public var colorTransfer: String?
        public var colorSpace: String?
        /// `tv` or `pc`; nil when unknown.
        public var colorRange: String?

        public init(width: Int, height: Int, sarNumerator: Int = 1, sarDenominator: Int = 1, rotation: Int = 0,
                    pixelFormat: String = "yuv420p", frameRate: Double? = nil, colorPrimaries: String? = nil,
                    colorTransfer: String? = nil, colorSpace: String? = nil, colorRange: String? = nil) {
            self.width = width; self.height = height
            self.sarNumerator = sarNumerator; self.sarDenominator = sarDenominator
            self.rotation = rotation; self.pixelFormat = pixelFormat; self.frameRate = frameRate
            self.colorPrimaries = colorPrimaries; self.colorTransfer = colorTransfer
            self.colorSpace = colorSpace; self.colorRange = colorRange
        }

        public var sar: Double { Double(sarNumerator) / Double(sarDenominator) }
        public var hasSquarePixels: Bool { sarNumerator == sarDenominator }

        /// Size as decoded and autorotated, before any SAR correction.
        public var rotatedSize: (width: Int, height: Int) {
            abs(rotation) % 180 == 90 ? (height, width) : (width, height)
        }

        /// Size after autorotation and `scale=trunc(iw*sar/2)*2:ih`. A 90° autorotate
        /// (`transpose`) inverts the SAR along with the axes.
        public var squareSize: (width: Int, height: Int) {
            let (w, h) = rotatedSize
            guard !hasSquarePixels else { return (w, h) }
            let ratio = abs(rotation) % 180 == 90 ? 1 / sar : sar
            return (Int(Double(w) * ratio / 2) * 2, h)
        }

        public var isRGB: Bool {
            let f = pixelFormat
            return f.hasPrefix("rgb") || f.hasPrefix("bgr") || f.hasPrefix("gbr") || f.hasPrefix("argb")
                || f.hasPrefix("abgr") || f.hasPrefix("0rgb") || f.hasPrefix("0bgr") || f.hasPrefix("pal")
        }
    }

    public struct Audio: Hashable, Sendable {
        public var codec: String
        public var sampleFormat: String
        /// Bits per sample of the stored audio; nil for lossy codecs.
        public var bitDepth: Int?

        public init(codec: String, sampleFormat: String, bitDepth: Int? = nil) {
            self.codec = codec; self.sampleFormat = sampleFormat; self.bitDepth = bitDepth
        }

        /// True for lossless or PCM sources stored with more than 16 bits.
        public var isDeeperThan16Bit: Bool { (bitDepth ?? 0) > 16 }
    }

    public var duration: Double?
    public var video: Video?
    public var audio: Audio?

    public init(duration: Double? = nil, video: Video? = nil, audio: Audio? = nil) {
        self.duration = duration; self.video = video; self.audio = audio
    }

    // MARK: Parsing

    private struct Output: Decodable {
        struct Stream: Decodable {
            var codec_type: String?
            var codec_name: String?
            var width: Int?
            var height: Int?
            var sample_aspect_ratio: String?
            var pix_fmt: String?
            var avg_frame_rate: String?
            var r_frame_rate: String?
            var color_range: String?
            var color_space: String?
            var color_transfer: String?
            var color_primaries: String?
            var sample_fmt: String?
            var bits_per_sample: Int?
            var bits_per_raw_sample: String?
            var duration: String?
            var disposition: [String: Int]?
            var tags: [String: String]?
            var side_data_list: [SideData]?
        }
        struct SideData: Decodable {
            var rotation: Double?
        }
        struct Format: Decodable {
            var duration: String?
        }
        var streams: [Stream]?
        var format: Format?
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams` output.
    public static func parse(_ data: Data) throws -> MediaProbe {
        let out = try JSONDecoder().decode(Output.self, from: data)
        let streams = out.streams ?? []
        var probe = MediaProbe()
        if let v = streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }),
           let w = v.width, let h = v.height, w > 0, h > 0 {
            let sar = ratio(v.sample_aspect_ratio, separator: ":")
            let validSAR = sar.map { $0.0 > 0 && $0.1 > 0 } ?? false
            let rotation = v.side_data_list?.compactMap(\.rotation).first.map { Int($0.rounded()) }
                ?? v.tags?["rotate"].flatMap { Int($0) } ?? 0
            let fps = [v.avg_frame_rate, v.r_frame_rate].lazy.compactMap { ratio($0, separator: "/") }
                .first { $0.0 > 0 && $0.1 > 0 }.map { Double($0.0) / Double($0.1) }
            probe.video = Video(width: w, height: h,
                                sarNumerator: validSAR ? sar!.0 : 1, sarDenominator: validSAR ? sar!.1 : 1,
                                rotation: rotation, pixelFormat: v.pix_fmt ?? "",
                                frameRate: fps,
                                colorPrimaries: known(v.color_primaries), colorTransfer: known(v.color_transfer),
                                colorSpace: known(v.color_space), colorRange: known(v.color_range))
        }
        if let a = streams.first(where: { $0.codec_type == "audio" }) {
            let raw = a.bits_per_raw_sample.flatMap { Int($0) } ?? 0
            let depth = raw > 0 ? raw : (a.bits_per_sample ?? 0) > 0 ? a.bits_per_sample : nil
            probe.audio = Audio(codec: a.codec_name ?? "", sampleFormat: a.sample_fmt ?? "", bitDepth: depth)
        }
        let durations = [out.format?.duration] + streams.map(\.duration)
        probe.duration = durations.lazy.compactMap { $0.flatMap(Double.init) }.first { $0 > 0 }
        return probe
    }

    private static func known(_ s: String?) -> String? {
        guard let s, !s.isEmpty, !["unknown", "unspecified", "reserved", "N/A"].contains(s) else { return nil }
        return s
    }

    private static func ratio(_ s: String?, separator: Character) -> (Int, Int)? {
        guard let parts = s?.split(separator: separator), parts.count == 2,
              let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    // MARK: Running ffprobe

    /// Runs the toolchain's ffprobe on `url`.
    public static func probe(_ url: URL, env: ToolEnvironment) async throws -> MediaProbe {
        guard let ffprobe = env.which("ffprobe") else { throw RenderError.commandNotFound(plugin: "probe", command: "ffprobe") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "glitchbox-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let json = dir.appending(path: "probe.json")
        let log = dir.appending(path: "log.txt")
        let code = try await Spawner.run(
            executable: ffprobe,
            arguments: ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-o", json.path, url.path],
            environment: env.variables, cwd: dir, log: log)
        guard code == 0, let data = try? Data(contentsOf: json) else {
            throw ExportError.probeFailed(url, tail: LayerRunner.tail(log, lines: 10))
        }
        return try parse(data)
    }
}
