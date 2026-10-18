import Foundation

public enum ExportEvent: Sendable, Equatable {
    /// `layer` counts enabled layers from 1 to `of`; 0 is the source.
    case rendering(layer: Int, of: Int, plugin: String)
    /// Fraction of the encode written, when ffmpeg has reported a time.
    case encoding(Double?)
    case finished(URL)

    /// Shared phase text for the app and CLI.
    public var label: String {
        switch self {
        case .rendering(0, _, _): "Rendering source"
        case .rendering(let k, let n, _): "Rendering layer \(k)/\(n)"
        case .encoding(let f?): "Encoding \(Int((f * 100).rounded(.down)))%"
        case .encoding(nil): "Encoding"
        case .finished: "Done"
        }
    }
}
