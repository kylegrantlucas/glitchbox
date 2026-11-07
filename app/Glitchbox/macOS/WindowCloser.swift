import AppKit

/// Closes the hosting window without consulting the close guard.
@MainActor
final class WindowCloser {
    weak var window: NSWindow?

    func close() { window?.close() }
}
