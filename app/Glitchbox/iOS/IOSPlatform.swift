import GlitchboxKit
import SwiftUI
import UniformTypeIdentifiers

/// iOS halves of actions the shared views and menus trigger. Exports are written into
/// `Documents/Exports` (visible in the Files app) and delivered from there.
@MainActor
enum PlatformActions {
    static var exportsDirectory: URL {
        URL.documentsDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    static var licensesAvailable: Bool {
        let paths = AppPaths.current()
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.licenses.path) || fm.fileExists(atPath: paths.credits.path)
    }

    static func showLicenses(_ model: StudioModel) { model.showLicenses = true }

    /// Saves the frame under the playhead into the exports folder.
    static func exportCurrentFrame(_ model: StudioModel) {
        let stem = model.source?.deletingPathExtension().lastPathComponent ?? "frame"
        guard let url = uniqueDestination(named: "\(stem)-glitchbox.png", model: model) else { return }
        model.exportCurrentFrame(to: url)
    }

    /// A fresh path in the exports folder; PNG sequences get a new, empty folder.
    static func exportDestination(for settings: ExportSettings, contentType: UTType, model: StudioModel) -> URL? {
        guard let url = uniqueDestination(named: settings.defaultFileName(source: model.source), model: model) else { return nil }
        if settings.format.isSequence {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch {
                model.notices.append("export: \(error.localizedDescription)")
                return nil
            }
        }
        return url
    }

    private static func uniqueDestination(named name: String, model: StudioModel) -> URL? {
        let dir = exportsDirectory
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            model.notices.append("export: \(error.localizedDescription)")
            return nil
        }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = dir.appending(path: name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// The layer's enable switch: a tappable icon, since checkboxes don't exist on iOS.
struct LayerEnabledToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button(isOn ? "Disable Layer" : "Enable Layer", systemImage: isOn ? "checkmark.circle.fill" : "circle") {
            isOn.toggle()
        }
        .labelStyle(.iconOnly)
        .imageScale(.large)
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .buttonStyle(.borderless)
    }
}

/// Accepts movies and images dragged in from other apps (iPad) as the source.
struct SourceDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    @Environment(StudioModel.self) private var model

    func body(content: Content) -> some View {
        content.dropDestination(for: ImportedMedia.self) { items, _ in
            guard let item = items.first else { return false }
            model.adoptImportedMedia(item)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

extension StudioModel {
    /// Moves a received movie or image into the user library's imports and makes it the source.
    func adoptImportedMedia(_ media: ImportedMedia) {
        do {
            source = try ImportedFile.copy(media.url, into: workspace, move: true, asSource: true)
            try? FileManager.default.removeItem(at: media.url.deletingLastPathComponent())
        } catch {
            notices.append("import: \(error.localizedDescription)")
        }
    }
}

/// Shows the plugin editor as a sheet with its own navigation bar.
struct PluginEditorPresentation: ViewModifier {
    @Environment(StudioModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.sheet(item: $model.editingPlugin) { request in
            NavigationStack {
                PluginEditorWindow(pluginID: request.id)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationSizing(.page)
        }
    }
}

/// Dismisses the editor sheet without consulting the close guard.
@MainActor
final class WindowCloser {
    var dismiss: DismissAction?

    func close() { dismiss?() }
}

/// Blocks swipe-to-dismiss while there are unsaved edits and asks instead; adds a Close button.
private struct EditorCloseGuard: ViewModifier {
    let isDirty: Bool
    let closer: WindowCloser
    let onAttemptClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty)
            .onAppear { closer.dismiss = dismiss }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        if isDirty { onAttemptClose() } else { dismiss() }
                    }
                }
            }
    }
}

extension View {
    func editorCloseGuard(isDirty: Bool, closer: WindowCloser, onAttemptClose: @escaping () -> Void) -> some View {
        modifier(EditorCloseGuard(isDirty: isDirty, closer: closer, onAttemptClose: onAttemptClose))
    }
}
