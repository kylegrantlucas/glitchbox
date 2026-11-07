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
                    Text(model.source?.lastPathComponent ?? "No source")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LayerStatusText(status: model.sourceStatus)
                }
                Spacer()
                #if os(iOS)
                PhotoSourcePicker()
                #endif
                Button("Choose…") { importing = true }
            }
            .help(model.source?.path ?? "Drop a movie or image here")
            RenderSettingsView()
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
