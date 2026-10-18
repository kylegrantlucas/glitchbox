import Foundation

/// Encode settings for an export; shared by the app (`export.json`) and `glitchbox export`.
public struct ExportSettings: Codable, Hashable, Sendable {
    public var format: ExportFormat
    /// Used when `format` offers more than one container (HEVC: MP4 or MOV).
    public var preferredContainer: ExportContainer
    public var quality: ExportQuality
    public var h264Encoder: H264Encoder
    /// Overrides the quality scale for x264.
    public var x264CRF: Int?
    public var x264Preset: String
    /// Overrides the quality scale for VideoToolbox (1–100).
    public var videoToolboxQuality: Int?
    public var proresProfile: ProResProfile
    public var size: OutputSize
    public var allowUpscale: Bool
    public var audio: ExportAudio
    /// nil uses the container's default.
    public var audioCodec: AudioCodec?
    /// AAC bitrate in kbit/s.
    public var audioBitrate: Int
    public var gif: GIFOptions

    public init(format: ExportFormat = .h264, preferredContainer: ExportContainer = .mp4, quality: ExportQuality = .high,
                h264Encoder: H264Encoder = .videoToolbox, x264CRF: Int? = nil, x264Preset: String = "medium",
                videoToolboxQuality: Int? = nil, proresProfile: ProResProfile = .hq, size: OutputSize = .asRendered,
                allowUpscale: Bool = false, audio: ExportAudio = .source, audioCodec: AudioCodec? = nil,
                audioBitrate: Int = 192, gif: GIFOptions = GIFOptions()) {
        self.format = format; self.preferredContainer = preferredContainer; self.quality = quality
        self.h264Encoder = h264Encoder; self.x264CRF = x264CRF; self.x264Preset = x264Preset
        self.videoToolboxQuality = videoToolboxQuality; self.proresProfile = proresProfile; self.size = size
        self.allowUpscale = allowUpscale; self.audio = audio; self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate; self.gif = gif
    }

    public var container: ExportContainer {
        format.containers.contains(preferredContainer) ? preferredContainer : format.containers[0]
    }

    /// The chosen audio codec when the container takes it, else the container's default.
    /// ProRes defaults to 24-bit PCM, the usual pairing in editing workflows.
    public var effectiveAudioCodec: AudioCodec? {
        let allowed = container.audioCodecs
        if let audioCodec, allowed.contains(audioCodec) { return audioCodec }
        if format == .prores { return .pcmS24 }
        return allowed.first
    }

    public var effectiveX264CRF: Int { x264CRF ?? quality.x264CRF }
    public var effectiveVideoToolboxQuality: Int { videoToolboxQuality ?? quality.videoToolboxQuality }

    /// `<source-stem>-glitchbox.<ext>`, or the bare name for a PNG sequence folder.
    public func defaultFileName(source: URL?) -> String {
        let stem = source?.deletingPathExtension().lastPathComponent ?? "export"
        let ext = container.fileExtension
        return ext.isEmpty ? "\(stem)-glitchbox" : "\(stem)-glitchbox.\(ext)"
    }
}
