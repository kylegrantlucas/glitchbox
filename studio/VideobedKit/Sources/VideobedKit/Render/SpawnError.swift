import Darwin
import Foundation

struct SpawnError: Error, LocalizedError {
    let path: String
    let code: Int32
    var errorDescription: String? { "cannot spawn \(path): \(String(cString: strerror(code)))" }
}
