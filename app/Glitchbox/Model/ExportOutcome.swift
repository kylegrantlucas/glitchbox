import Foundation

/// The result of the last export, shown until dismissed.
enum ExportOutcome: Equatable {
    case finished(URL)
    case failed(message: String, tail: [String])
}
