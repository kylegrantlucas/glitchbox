import SwiftUI

struct RootPickerView: View {
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        ContentUnavailableView {
            Label("Choose a videobed checkout", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Select the folder containing flake.nix and pipelines/.")
        } actions: {
            Button("Choose Folder…") { importing = true }
        }
        .frame(minWidth: 600, minHeight: 400)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                if !store.choose(root: url) { error = "\(url.path) is not a videobed checkout (needs flake.nix and pipelines/_lib.sh)." }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
        .alert("Invalid folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}
