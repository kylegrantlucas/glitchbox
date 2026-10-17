import Foundation

public enum WorkspaceError: Error, LocalizedError, Equatable {
    case notARoot
    case emptySlug
    /// `path` exists only in the read-only base library.
    case builtin(path: String)
    case notFound(path: String)

    public var errorDescription: String? {
        switch self {
        case .notARoot: "no Glitchbox library found (needs plugins/ and pipelines/_lib.sh); pass --root or set GLITCHBOX_ROOT"
        case .emptySlug: "name must contain a letter or digit"
        case .builtin(let path): "\(path) is built in and cannot be deleted"
        case .notFound(let path): "\(path) not found in the library"
        }
    }
}
