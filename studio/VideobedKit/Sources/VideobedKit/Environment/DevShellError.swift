import Foundation

public enum DevShellError: Error, LocalizedError {
    case nixNotFound
    case developFailed(Int32)
    case incompleteEnvironment

    public var errorDescription: String? {
        switch self {
        case .nixNotFound: "nix not found"
        case .developFailed(let code): "nix develop failed (exit \(code)); see out/studio/devshell.log"
        case .incompleteEnvironment: "devshell env missing VIDEOBED_ROOT/PATH"
        }
    }
}
