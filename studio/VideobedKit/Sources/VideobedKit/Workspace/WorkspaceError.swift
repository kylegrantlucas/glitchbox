import Foundation

public enum WorkspaceError: Error, LocalizedError, Equatable {
    case notARoot
    case emptySlug

    public var errorDescription: String? {
        switch self {
        case .notARoot: "not inside a videobed checkout; pass --root"
        case .emptySlug: "name must contain a letter or digit"
        }
    }
}
