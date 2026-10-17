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
                Button("Choose…") { importing = true }
            }
            .help(model.source?.path ?? "Drop a movie or image here")
            RenderSettingsView()
        }
        .padding(12)
        .background(dropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.source = url
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .image]) { result in
            if case .success(let url) = result { model.source = url }
        }
    }
}
