import Foundation

public enum ToolchainError: Error, LocalizedError, Equatable {
    /// No toolchain.json at this path.
    case missing(URL)
    case invalid(URL, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let url): "no Glitchbox toolchain at \(url.path); run `just app` to build it"
        case .invalid(let url, let why): "invalid toolchain \(url.path): \(why); run `just app` to rebuild it"
        }
    }
}
