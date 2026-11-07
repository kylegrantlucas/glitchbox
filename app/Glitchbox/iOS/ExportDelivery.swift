import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Share, Save to Photos, or Save to Files for a finished export in the sandbox.
struct ExportDeliveryButtons: View {
    let url: URL
    @Environment(StudioModel.self) private var model
    @State private var moving = false
    @State private var saving = false

    var body: some View {
        Menu {
            ShareLink(item: url)
            if let kind = PhotosSaver.kind(of: url) {
                Button("Save to Photos", systemImage: "photo.badge.plus") { save(kind) }
            }
            Button("Save to Files", systemImage: "folder") { moving = true }
        } label: {
            if saving { ProgressView() } else { Label("Save", systemImage: "square.and.arrow.up") }
        }
        .disabled(saving)
        .fileMover(isPresented: $moving, file: url) { result in
            switch result {
            case .success(let moved):
                model.exportOutcome = nil
                model.notices.append("Moved \(moved.lastPathComponent) to Files.")
            case .failure(let error):
                model.notices.append("Save to Files: \(error.localizedDescription)")
            }
        }
    }

    private func save(_ kind: PHAssetResourceType) {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await PhotosSaver.save(url, as: kind)
                model.notices.append("Saved \(url.lastPathComponent) to Photos.")
            } catch {
                model.notices.append("Save to Photos: \(error.localizedDescription)")
            }
        }
    }
}

enum PhotosSaver {
    /// Photos takes H.264/HEVC/ProRes in MP4/MOV, and still images (PNG frames, GIF).
    static func kind(of url: URL) -> PHAssetResourceType? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .mpeg4Movie) || type.conforms(to: .quickTimeMovie) { return .video }
        if type.conforms(to: .png) || type.conforms(to: .gif) { return .photo }
        return nil
    }

    static func save(_ url: URL, as kind: PHAssetResourceType) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw StudioError("Glitchbox isn't allowed to add to your photo library (Settings › Privacy › Photos).")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: kind, fileURL: url, options: options)
        }
    }
}
