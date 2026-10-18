public enum ExportContainer: String, Codable, CaseIterable, Sendable {
    case mp4, mov, mkv, gif
    /// A folder of numbered PNG frames.
    case folder

    public var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "QuickTime (MOV)"
        case .mkv: "Matroska (MKV)"
        case .gif: "GIF"
        case .folder: "Folder"
        }
    }

    /// Empty for `.folder`.
    public var fileExtension: String {
        switch self {
        case .folder: ""
        default: rawValue
        }
    }

    /// ffmpeg `-f` muxer name.
    var muxer: String {
        switch self {
        case .mp4: "mp4"
        case .mov: "mov"
        case .mkv: "matroska"
        case .gif: "gif"
        case .folder: "image2"
        }
    }

    /// Audio codecs this container takes; the first is the default.
    public var audioCodecs: [AudioCodec] {
        switch self {
        case .mp4: [.aac, .alac]
        case .mov: [.aac, .pcmS24, .pcmS16, .alac]
        case .mkv: [.flac, .pcmS24, .pcmS16]
        case .gif, .folder: []
        }
    }

    var supportsFaststart: Bool { self == .mp4 || self == .mov }
}
