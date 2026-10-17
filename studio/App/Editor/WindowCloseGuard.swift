import AppKit
import SwiftUI

/// Asks before closing a window with unsaved changes.
struct WindowCloseGuard: NSViewRepresentable {
    let isDirty: Bool
    let closer: WindowCloser
    let onAttemptClose: () -> Void

    func makeCoordinator() -> CloseGuardDelegate { CloseGuardDelegate() }

    func makeNSView(context: Context) -> WindowAttachView {
        let view = WindowAttachView()
        let coordinator = context.coordinator
        let closer = closer
        view.onWindow = { window in
            coordinator.install(on: window)
            closer.window = window
        }
        return view
    }

    func updateNSView(_ view: WindowAttachView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.onAttemptClose = onAttemptClose
    }
}
