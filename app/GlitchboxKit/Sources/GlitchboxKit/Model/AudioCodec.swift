public enum AudioCodec: String, Codable, CaseIterable, Sendable {
    case aac, alac, pcmS16, pcmS24, flac

    public var title: String {
        switch self {
        case .aac: "AAC"
        case .alac: "Apple Lossless"
        case .pcmS16: "PCM 16-bit"
        case .pcmS24: "PCM 24-bit"
        case .flac: "FLAC"
        }
    }

    /// ffmpeg encoder name.
    var encoder: String {
        switch self {
        case .aac: "aac_at"
        case .alac: "alac"
        case .pcmS16: "pcm_s16le"
        case .pcmS24: "pcm_s24le"
        case .flac: "flac"
        }
    }

    public var hasBitrate: Bool { self == .aac }

    /// AAC bitrates offered, in kbit/s.
    public static let aacBitrates = [128, 192, 256, 320]
}
