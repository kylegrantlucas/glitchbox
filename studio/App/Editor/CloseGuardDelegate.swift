import AppKit

/// Interposes `windowShouldClose` and forwards every other delegate call to
/// SwiftUI's own window delegate.
@MainActor
final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    // Read from the nonisolated NSObject overrides below; AppKit calls them on the main thread.
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    var isDirty = false
    var onAttemptClose: () -> Void = {}

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isDirty {
            onAttemptClose()
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }
}
