import Foundation

/// The resolved devshell environment that every render step runs in.
public struct ToolEnvironment: Sendable {
    public let root: URL
    public let variables: [String: String]

    public init(root: URL, variables: [String: String]) {
        self.root = root; self.variables = variables
    }

    /// Absolute executable for `cmd`, searched on `variables["PATH"]`.
    public func which(_ cmd: String) -> URL? {
        let fm = FileManager.default
        if cmd.contains("/") {
            let url = URL(filePath: cmd)
            return cmd.hasPrefix("/") && fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        for dir in (variables["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            let url = URL(filePath: String(dir), directoryHint: .isDirectory).appending(path: cmd)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public func missing(_ requires: [String]) -> [String] {
        requires.filter { which($0) == nil }
    }
}
