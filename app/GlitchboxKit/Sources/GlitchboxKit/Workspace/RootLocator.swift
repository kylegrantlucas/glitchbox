import Foundation

/// Finds the base library root: a dir with `plugins/` and `pipelines/_lib.sh`.
public enum RootLocator {
    public static func isRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.appending(path: "plugins").path, isDirectory: &isDir) && isDir.boolValue
            && fm.fileExists(atPath: url.appending(path: "pipelines/_lib.sh").path)
    }

    /// explicit → `GLITCHBOX_ROOT` → walk up from `cwd` → `<executable>/../../Resources/library`.
    public static func locate(explicit: String?, environment: [String: String], cwd: URL, executable: URL?) throws -> URL {
        if let explicit {
            let url = URL(filePath: explicit, directoryHint: .isDirectory, relativeTo: cwd).standardizedFileURL
            guard isRoot(url) else { throw WorkspaceError.notARoot }
            return url
        }
        if let env = environment["GLITCHBOX_ROOT"], !env.isEmpty {
            let url = URL(filePath: env, directoryHint: .isDirectory).standardizedFileURL
            if isRoot(url) { return url }
        }
        var dir = cwd.standardizedFileURL
        while true {
            if isRoot(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        if let executable {
            let library = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/library", directoryHint: .isDirectory).standardizedFileURL
            if isRoot(library) { return library }
        }
        throw WorkspaceError.notARoot
    }
}
