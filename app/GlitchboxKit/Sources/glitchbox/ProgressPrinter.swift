import Foundation
import GlitchboxKit
import Synchronization

/// Writes export phases to stderr: an updating line on a terminal, else one line per phase
/// and per 10% of encoding.
final class ProgressPrinter: Sendable {
    private struct State {
        var lastLabel = ""
        var lastTenth = -1
    }

    private let tty: Bool
    private let state = Mutex(State())

    init(tty: Bool) { self.tty = tty }

    func show(_ event: ExportEvent) {
        state.withLock { s in
            let label = event.label
            defer { s.lastLabel = label }
            switch event {
            case .rendering:
                if label != s.lastLabel { StandardError.print(label) }
            case .encoding(let f):
                if tty {
                    FileHandle.standardError.write(Data("\r\(label)   ".utf8))
                } else if let f, Int(f * 10) > s.lastTenth {
                    s.lastTenth = Int(f * 10)
                    StandardError.print(label)
                }
            case .finished:
                if tty { FileHandle.standardError.write(Data("\r\(label)          \n".utf8)) }
            }
        }
    }
}
