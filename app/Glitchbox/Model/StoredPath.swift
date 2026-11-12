import Foundation
import GlitchboxKit

/// How the app persists file locations (session source, export audio, export folder).
///
/// macOS stores absolute paths. iOS stores paths relative to the user library, or
/// `~/`-relative to the app container, because the container path changes across
/// app updates; absolute paths are still read so older files keep loading.
enum StoredPath {
    static func store(_ url: URL, in workspace: Workspace) -> String {
        #if os(iOS)
        let relative = workspace.storedFileValue(url)
        if !relative.hasPrefix("/") { return relative }
        let path = url.standardizedFileURL.path
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).standardizedFileURL.path
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(prefix) { return "~/" + path.dropFirst(prefix.count) }
        return path
        #else
        return url.path
        #endif
    }

    static func resolve(_ stored: String, in workspace: Workspace) -> URL {
        if stored.hasPrefix("~/") {
            return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: String(stored.dropFirst(2)))
        }
        if stored.hasPrefix("/") { return URL(filePath: stored) }
        return workspace.resolveFile(stored)
    }

    static func storeAudio(_ audio: ExportAudio, in workspace: Workspace) -> ExportAudio {
        guard case .file(let path) = audio else { return audio }
        return .file(store(URL(filePath: path), in: workspace))
    }

    static func resolveAudio(_ audio: ExportAudio, in workspace: Workspace) -> ExportAudio {
        guard case .file(let stored) = audio else { return audio }
        return .file(resolve(stored, in: workspace).path)
    }
}
