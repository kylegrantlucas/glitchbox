import CryptoKit
import Foundation

/// Captures the `nix develop` environment once per flake revision and caches it.
public enum DevShellResolver {
    static let droppedKeys: Set<String> = ["TMPDIR", "TMP", "TEMP", "TEMPDIR", "NIX_BUILD_TOP", "PWD", "OLDPWD", "SHLVL", "_"]

    public static func progressLog(root: URL) -> URL {
        root.appending(path: "out/studio/devshell.log")
    }

    public static func resolve(root: URL, forceRefresh: Bool, progressLog: URL) async throws -> ToolEnvironment {
        let root = root.standardizedFileURL
        let process = ProcessInfo.processInfo.environment
        if let r = process["VIDEOBED_ROOT"], samePath(r, root.path), process["FFGLITCH_SCRIPTS"] != nil {
            return ToolEnvironment(root: root, variables: process)
        }

        let cache = root.appending(path: "out/studio/devshell-\(try cacheKey(root: root)).env0")
        if !forceRefresh, let data = try? Data(contentsOf: cache) {
            let vars = parseEnv0(data)
            if let r = vars["VIDEOBED_ROOT"], samePath(r, root.path), !(vars["PATH"] ?? "").isEmpty {
                return ToolEnvironment(root: root, variables: vars)
            }
        }

        let fm = FileManager.default
        let user = process["USER"] ?? NSUserName()
        let candidates = ["/nix/var/nix/profiles/default/bin/nix", "/run/current-system/sw/bin/nix", "/etc/profiles/per-user/\(user)/bin/nix"]
        guard let nix = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { throw DevShellError.nixNotFound }

        try fm.createDirectory(at: progressLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("== nix develop \(root.path) ==\n".utf8).write(to: progressLog)
        let tmp = fm.temporaryDirectory.appending(path: "vb-devshell-\(UUID().uuidString).env0")
        defer { try? fm.removeItem(at: tmp) }

        let code = try await Spawner.run(
            executable: URL(filePath: nix),
            arguments: ["develop", root.path, "--command", "/bin/bash", "-c", "env -0 > \"$1\"", "_", tmp.path],
            environment: process, cwd: root, log: progressLog)
        guard code == 0 else { throw DevShellError.developFailed(code) }

        let data = try Data(contentsOf: tmp)
        let vars = parseEnv0(data)
        guard let r = vars["VIDEOBED_ROOT"], samePath(r, root.path), !(vars["PATH"] ?? "").isEmpty else {
            throw DevShellError.incompleteEnvironment
        }
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodeEnv0(vars).write(to: cache, options: .atomic)
        return ToolEnvironment(root: root, variables: vars)
    }

    /// Splits `env -0` output and drops shell-session variables.
    public static func parseEnv0(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for entry in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let eq = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            guard let key = String(data: Data(entry[entry.startIndex..<eq]), encoding: .utf8),
                  let value = String(data: Data(entry[entry.index(after: eq)...]), encoding: .utf8),
                  !key.isEmpty, !droppedKeys.contains(key) else { continue }
            out[key] = value
        }
        return out
    }

    static func encodeEnv0(_ vars: [String: String]) -> Data {
        var data = Data()
        for key in vars.keys.sorted() {
            data.append(contentsOf: Array("\(key)=\(vars[key]!)".utf8))
            data.append(0)
        }
        return data
    }

    /// First 12 hex of sha256 over flake.nix, flake.lock, and pkgs/*.nix.
    static func cacheKey(root: URL) throws -> String {
        var hasher = SHA256()
        let fm = FileManager.default
        var files = [root.appending(path: "flake.nix"), root.appending(path: "flake.lock")]
        let pkgs = (try? fm.contentsOfDirectory(at: root.appending(path: "pkgs"), includingPropertiesForKeys: nil)) ?? []
        files += pkgs.filter { $0.pathExtension == "nix" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            if let d = try? Data(contentsOf: f) { hasher.update(data: d) }
        }
        return String(Hashing.hex(hasher.finalize()).prefix(12))
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(filePath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(filePath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
