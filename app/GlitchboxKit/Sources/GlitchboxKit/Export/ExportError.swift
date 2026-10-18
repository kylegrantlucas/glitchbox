import Foundation

public enum ExportError: Error, LocalizedError {
    case probeFailed(URL, tail: [String])
    case noVideo(URL)
    case missingAudioFile(String)
    case encodeFailed(code: Int32, log: URL, tail: [String])

    public var errorDescription: String? {
        switch self {
        case .probeFailed(let url, _): "ffprobe could not read \(url.path)"
        case .noVideo(let url): "\(url.lastPathComponent) has no video stream"
        case .missingAudioFile(let path): "audio file not found: \(path)"
        case .encodeFailed(let code, let log, _): "ffmpeg exited \(code); see \(log.path)"
        }
    }

    /// Last lines of the ffmpeg or ffprobe log.
    public var tail: [String] {
        switch self {
        case .probeFailed(_, let tail), .encodeFailed(_, _, let tail): tail
        default: []
        }
    }

    public var log: URL? {
        if case .encodeFailed(_, let log, _) = self { return log }
        return nil
    }
}
