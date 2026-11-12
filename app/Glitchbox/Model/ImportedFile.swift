import Foundation
import GlitchboxKit
#if os(iOS)
import ImageIO
import UniformTypeIdentifiers
#endif

/// Makes a user-picked file usable by the engine.
///
/// macOS (not sandboxed) uses the file where it is. iOS copies it into
/// `<user library>/imports/<uuid>/<name>` under security-scoped access, since picked URLs
/// outside the container are only readable while the scope is held.
enum ImportedFile {
    /// Pass `asSource` for the session source: images the engine doesn't read as stills
    /// (HEIC from Photos, …) are converted to PNG on iOS.
    static func adopt(_ url: URL, into workspace: Workspace, asSource: Bool = false) throws -> URL {
        #if os(iOS)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try copy(url, into: workspace, asSource: asSource)
        #else
        return url
        #endif
    }

    #if os(iOS)
    static func importsDirectory(in workspace: Workspace) -> URL {
        workspace.user.appending(path: "imports", directoryHint: .isDirectory)
    }

    /// Copies (or, for a file the system hands over for good, moves) `url` into a fresh imports folder.
    static func copy(_ url: URL, into workspace: Workspace, move: Bool = false, asSource: Bool = false) throws -> URL {
        let fm = FileManager.default
        var imports = importsDirectory(in: workspace)
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        // Re-importable from the original; keep it out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? imports.setResourceValues(values)
        let dir = imports.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.lastPathComponent.isEmpty ? "import" : url.lastPathComponent
        do {
            if asSource, needsStillConversion(url) {
                let dest = dir.appending(path: (name as NSString).deletingPathExtension + ".png")
                try convertToPNG(url, to: dest)
                if move { try? fm.removeItem(at: url) }
                return dest
            }
            let dest = dir.appending(path: name)
            if move { try fm.moveItem(at: url, to: dest) } else { try fm.copyItem(at: url, to: dest) }
            return dest
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// A still image whose extension the engine doesn't treat as a still. GIFs stay as they
    /// are: they may be animated, and the engine reads them as video.
    private static func needsStillConversion(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !SourcePrep.stillExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .gif)
    }

    /// Decodes the first image at full resolution, upright per its EXIF orientation, as PNG.
    private static func convertToPNG(_ url: URL, to dest: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
        }
    }

    /// Deletes import folders nothing refers to. A folder is kept when its name appears in
    /// `references` (in-memory state) or in any JSON file of the user library (session, export
    /// settings, chains, presets, plugins), so anything still referenced survives.
    static func prune(in workspace: Workspace, references: [String]) {
        let fm = FileManager.default
        let imports = importsDirectory(in: workspace)
        guard let folders = try? fm.contentsOfDirectory(atPath: imports.path), !folders.isEmpty else { return }
        var unreferenced = Set(folders.filter { !$0.hasPrefix(".") })
        func scan(_ text: String) {
            unreferenced = unreferenced.filter { !text.contains($0) }
        }
        references.forEach(scan)
        let skip = [imports.standardizedFileURL.path, workspace.layersDir.standardizedFileURL.path]
        if let files = fm.enumerator(at: workspace.user, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let file as URL in files {
                if unreferenced.isEmpty { return }
                if skip.contains(file.standardizedFileURL.path) { files.skipDescendants(); continue }
                guard file.pathExtension.lowercased() == "json",
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                scan(text)
            }
        }
        for name in unreferenced {
            try? fm.removeItem(at: imports.appending(path: name, directoryHint: .isDirectory))
        }
    }
    #endif
}
