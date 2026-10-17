import Foundation

public enum RenderError: Error, LocalizedError {
    case unknownPlugin(String)
    case unavailable(plugin: String, missing: [String])
    case missingFile(plugin: String, param: String)
    case missingAsset(plugin: String, path: String)
    case missingSource(URL)
    case commandNotFound(plugin: String, command: String)
    case stepFailed(plugin: String, step: String, code: Int32, log: URL, tail: [String])
    case noOutput(plugin: String, log: URL)

    public var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): "unknown plugin '\(id)'"
        case .unavailable(_, let missing): "unavailable: missing \(missing.joined(separator: ", "))"
        case .missingFile(_, let param): "file param '\(param)' is not set or does not exist"
        case .missingAsset(_, let path): "asset '\(path)' not found"
        case .missingSource(let url): "source not found: \(url.path)"
        case .commandNotFound(_, let cmd): "command '\(cmd)' not found on the toolchain PATH"
        case .stepFailed(_, let step, let code, let log, _): "step '\(step)' exited \(code) — see \(log.path)"
        case .noOutput(_, let log): "produced no output — see \(log.path)"
        }
    }

    /// Log file to show for this failure, when there is one.
    public var log: URL? {
        switch self {
        case .stepFailed(_, _, _, let log, _), .noOutput(_, let log): log
        default: nil
        }
    }

    public var tail: [String] {
        if case .stepFailed(_, _, _, _, let tail) = self { return tail }
        return []
    }
}
