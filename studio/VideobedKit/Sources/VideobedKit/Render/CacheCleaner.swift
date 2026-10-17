import Foundation

public enum CacheCleaner {
    public static func clear(root: URL) throws {
        let dir = Workspace(root: root).layersDir
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
