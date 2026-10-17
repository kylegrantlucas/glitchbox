import Foundation

/// The hermetic environment every render step, pipeline, and `glitchbox env` runs in.
public struct ToolEnvironment: Sendable {
    /// Keys the toolchain defines: `PATH`, `GLITCHBOX_*`, and toolchain.json `environment`.
    public let own: [String: String]
    /// `own` plus the pass-through parent variables; what child processes receive.
    public let variables: [String: String]
    /// toolchain.json `digest`; part of every layer cache key.
    public let digest: String

    public init(own: [String: String], passThrough: [String: String] = [:], digest: String) {
        self.own = own
        self.variables = passThrough.merging(own) { _, mine in mine }
        self.digest = digest
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

    /// `own` as sorted `export KEY='value'` lines for `eval "$(glitchbox env)"`.
    public func shellExports() -> String {
        own.keys.sorted().map { "export \($0)=\(Self.shellQuote(own[$0]!))\n" }.joined()
    }

    /// POSIX single-quoted `s`; an embedded `'` becomes `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
