import SwiftUI
import VideobedKit

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
    private var issues: [ValidationIssue] { ManifestValidator.validate(manifest, fileName: nil, root: model.workspace.root) }
    private var dirty: Bool { manifest != baseline }

    var body: some View {
        Form {
            Section("Plugin") {
                LabeledContent("ID", value: draft.id)
                TextField("Name", text: $draft.name)
                TextField("Summary", text: $draft.summary)
                TextField("Requires", text: $draft.requiresText, prompt: Text("ffmpeg, ffgac"))
                    .help("Commands that must be on the devshell PATH, comma-separated")
                LabeledContent("Assets") {
                    TextEditor(text: $draft.assetsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 44)
                }
                .help("Repo-relative files hashed into the cache key, one per line")
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
                Button("Delete Plugin", systemImage: "trash", role: .destructive) { confirmDelete = true }
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
        .confirmationDialog("Delete plugin “\(draft.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                do {
                    try model.workspace.deletePlugin(id: draft.id)
                    model.reloadLibrary()
                    closer.close()
                } catch {
                    saveError = error.localizedDescription
                }
            }
        } message: {
            Text("Removes plugins/\(draft.id).json. Layers using it become unavailable.")
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
}
