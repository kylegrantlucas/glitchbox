import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A movie or image received from Photos or a drag, copied to a private temporary folder
/// (the system deletes its own copy when the import closure returns).
struct ImportedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try receive($0.file) }
        FileRepresentation(importedContentType: .image) { try receive($0.file) }
    }

    private static func receive(_ file: URL) throws -> ImportedMedia {
        let dir = URL.temporaryDirectory.appending(path: "import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: dest)
        return ImportedMedia(url: dest)
    }
}

/// Picks the source from the photo library.
struct PhotoSourcePicker: View {
    @Environment(StudioModel.self) private var model
    @State private var item: PhotosPickerItem?
    @State private var loading = false

    var body: some View {
        let busy = loading
        PhotosPicker(selection: $item, matching: .any(of: [.videos, .images]), preferredItemEncoding: .current) {
            if busy {
                ProgressView()
            } else {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(loading)
        .accessibilityLabel("Choose from Photos")
        .onChange(of: item) {
            guard let item else { return }
            loading = true
            Task {
                defer { loading = false; self.item = nil }
                do {
                    if let media = try await item.loadTransferable(type: ImportedMedia.self) {
                        model.adoptImportedMedia(media)
                    }
                } catch {
                    model.notices.append("import: \(error.localizedDescription)")
                }
            }
        }
    }
}
