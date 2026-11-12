import SwiftUI
import UniformTypeIdentifiers

struct SourceSection: View {
    @Environment(StudioModel.self) private var model
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "film")
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.source?.lastPathComponent ?? (model.mode == .simple ? "Choose a photo or video" : "No source"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // The Simple prompt must fit beside Choose… in the iPad's narrow column; file names truncate as before.
                        .minimumScaleFactor(model.source == nil ? 0.8 : 1)
                    // Simple mode has no Render button to explain an idle source.
                    if model.mode == .advanced || model.sourceStatus != .idle {
                        LayerStatusText(status: model.sourceStatus)
                    }
                }
                Spacer()
                #if os(iOS)
                // Photos or Files.
                SourceChooser { importing = true }
                #else
                Button("Choose…") { importing = true }
                #endif
            }
            .help(model.source?.path ?? "Drop a movie or image here")
            if model.mode == .advanced {
                RenderSettingsView()
            } else if model.source != nil, !model.sourceIsStill, model.renderOptions.range == .inOut {
                Text("Previewing a short section. Export renders the whole clip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(dropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .modifier(SourceDropModifier(isTargeted: $dropTargeted))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .image]) { result in
            guard case .success(let url) = result else { return }
            do { model.source = try ImportedFile.adopt(url, into: model.workspace, asSource: true) } catch {
                model.notices.append("import: \(error.localizedDescription)")
            }
        }
    }
}
