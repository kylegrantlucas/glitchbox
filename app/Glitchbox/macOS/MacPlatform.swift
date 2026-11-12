import AppKit
import GlitchboxKit
import SwiftUI
import UniformTypeIdentifiers

/// macOS halves of actions the shared views and menus trigger.
@MainActor
enum PlatformActions {
    /// Licence texts of every bundled tool, staged by packaging/build.sh (absent from Debug builds).
    private static let licenses = Bundle.main.bundleURL.appending(path: "Contents/Resources/licenses", directoryHint: .isDirectory)

    static var licensesAvailable: Bool { FileManager.default.fileExists(atPath: licenses.path) }

    static func showLicenses(_ model: StudioModel) { NSWorkspace.shared.open(licenses) }

    /// Asks where to save the frame under the playhead, then exports it.
    static func exportCurrentFrame(_ model: StudioModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let stem = model.source?.deletingPathExtension().lastPathComponent ?? "frame"
        panel.nameFieldStringValue = "\(stem)-glitchbox.png"
        panel.directoryURL = model.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportCurrentFrame(to: url)
    }

    static func revealInFinder(_ model: StudioModel) {
        guard let dir = model.viewedOutput?.dir ?? model.selectedItem?.output?.dir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// A save panel (movies, GIF) or folder chooser (PNG sequence) for an export.
    static func exportDestination(for settings: ExportSettings, contentType: UTType, model: StudioModel) -> URL? {
        if settings.format.isSequence {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export"
            panel.message = "Choose a folder for the PNG frames. Frames from an earlier export there are replaced."
            panel.directoryURL = model.exportDirectory
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = settings.defaultFileName(source: model.source)
        panel.directoryURL = model.exportDirectory
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// Shows a finished export in Finder.
struct ExportDeliveryButtons: View {
    let url: URL

    var body: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

/// The layer's enable checkbox.
struct LayerEnabledToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Enabled", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.checkbox)
    }
}

/// Accepts movie and image files dropped from Finder as the source.
struct SourceDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    @Environment(StudioModel.self) private var model

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.source = url
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Opens each editor request in its own window.
struct PluginEditorPresentation: ViewModifier {
    @Environment(StudioModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: model.editingPlugin) {
            guard let request = model.editingPlugin else { return }
            model.editingPlugin = nil
            openWindow(id: "plugin-editor", value: request.id)
        }
    }
}

extension View {
    func editorCloseGuard(isDirty: Bool, closer: WindowCloser, onAttemptClose: @escaping () -> Void) -> some View {
        background(WindowCloseGuard(isDirty: isDirty, closer: closer, onAttemptClose: onAttemptClose))
    }
}
