public enum ExportAudio: Codable, Hashable, Sendable {
    case none
    /// The source's first audio track, trimmed like the video.
    case source
    /// An audio file, trimmed to the export's duration from its start.
    case file(String)
}
