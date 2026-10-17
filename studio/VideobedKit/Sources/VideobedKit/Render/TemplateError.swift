import Foundation

public enum TemplateError: Error, Equatable, LocalizedError {
    case unknownPlaceholder(String)
    case unterminated

    public var errorDescription: String? {
        switch self {
        case .unknownPlaceholder(let n): "unknown placeholder {\(n)}"
        case .unterminated: "unterminated '{' in template"
        }
    }
}
