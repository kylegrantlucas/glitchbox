import SwiftUI
import GlitchboxKit

struct PluginEditorView: View {
    @Environment(StudioModel.self) private var model
    @State private var draft: EditorDraft
    @State private var baseline: PluginManifest
    @State private var closer = WindowCloser()
    @State private var askClose = false
    @State private var confirmDelete = false
    @State private var saveError: String?

    init(initial: PluginManifest) {
        let draft = EditorDraft(initial)
        _draft = State(initialValue: draft)
        _baseline = State(initialValue: draft.manifest)
    }

    private var manifest: PluginManifest { draft.manifest }
    private var issues: [ValidationIssue] {
        ManifestValidator.validate(manifest, fileName: nil, roots: [model.workspace.user, model.workspace.base])
    }
    private var dirty: Bool { manifest != baseline }
    private var origin: LibraryOrigin? { model.pluginOrigins[draft.id] }

    private var originText: String {
        switch origin {
        case .builtin: "Built-in; saving creates your own copy"
        case .user: "Your plugin"
        case .overridden: "Your copy of a built-in plugin"
        case nil: "Not saved"
        }
    }

    var body: some View {
        Form {
            Section("Plugin") {
                LabeledContent("ID", value: draft.id)
                LabeledContent("Library", value: originText)
                TextField("Name", text: $draft.name)
                TextField("Summary", text: $draft.summary)
                TextField("Requires", text: $draft.requiresText, prompt: Text("ffmpeg, ffgac"))
                    .help("Commands that must be on the toolchain PATH, comma-separated")
                LabeledContent("Assets") {
                    TextEditor(text: $draft.assetsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 44)
                }
                .help("Library-relative files hashed into the cache key, one per line")
            }
            Section("Parameters") {
                ParamSpecEditor(params: $draft.params)
            }
            Section("Steps") {
                StepEditor(steps: $draft.steps)
            }
            Section("Validation") {
                if issues.isEmpty {
                    Label("No issues", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    ForEach(issues, id: \.message) { issue in
                        Label(issue.message, systemImage: "xmark.octagon").foregroundStyle(.red)
                    }
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if origin == .overridden {
                    Button("Revert to Built-in", systemImage: "arrow.uturn.backward", role: .destructive) { confirmDelete = true }
                } else {
                    Button("Delete Plugin", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(origin != .user)
                        .help(origin == .builtin ? "Built-in plugins cannot be deleted" : "Delete this plugin")
                }
                Button("Save", systemImage: "square.and.arrow.down") { _ = save() }
                    .keyboardShortcut("s")
                    .disabled(!issues.isEmpty || !dirty)
            }
        }
        .background(WindowCloseGuard(isDirty: dirty, closer: closer) { askClose = true })
        .confirmationDialog("Save changes to “\(draft.name)”?", isPresented: $askClose) {
            if issues.isEmpty {
                Button("Save") { if save() { closer.close() } }
            }
            Button("Discard Changes", role: .destructive) { closer.close() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(issues.isEmpty ? "Your changes will be lost if you don't save them." : "The plugin has validation issues and cannot be saved.")
        }
        .confirmationDialog(origin == .overridden ? "Revert “\(draft.name)” to the built-in version?" : "Delete plugin “\(draft.name)”?",
                            isPresented: $confirmDelete) {
            Button(origin == .overridden ? "Revert" : "Delete", role: .destructive, action: deleteUserCopy)
        } message: {
            let file = model.workspace.user.appending(path: "plugins/\(draft.id).json").path
            if origin == .overridden {
                Text("Discards your copy (\(file)) and any unsaved changes.")
            } else {
                Text("Removes \(file). Layers using it become unavailable.")
            }
        }
    }

    private func save() -> Bool {
        do {
            let m = manifest
            try model.workspace.savePlugin(m)
            baseline = m
            saveError = nil
            model.reloadLibrary()
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Deletes a user plugin and closes, or reverts an overridden one and reloads the built-in.
    private func deleteUserCopy() {
        let reverting = origin == .overridden
        do {
            try model.deletePlugin(id: draft.id)
            saveError = nil
            if reverting {
                let builtin = try model.workspace.builtinPlugin(id: draft.id)
                draft = EditorDraft(builtin)
                baseline = draft.manifest
            } else {
                closer.close()
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
