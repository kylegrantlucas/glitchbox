import Foundation

public enum RootLocator {
    public static func isRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appending(path: "flake.nix").path)
            && fm.fileExists(atPath: url.appending(path: "pipelines/_lib.sh").path)
    }

    /// explicit → `VIDEOBED_ROOT` → walk up from `cwd`.
    public static func locate(explicit: String?, environment: [String: String], cwd: URL) throws -> URL {
        if let explicit {
            let url = URL(filePath: explicit, directoryHint: .isDirectory, relativeTo: cwd).standardizedFileURL
            guard isRoot(url) else { throw WorkspaceError.notARoot }
            return url
        }
        if let env = environment["VIDEOBED_ROOT"], !env.isEmpty {
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
        throw WorkspaceError.notARoot
    }
}
