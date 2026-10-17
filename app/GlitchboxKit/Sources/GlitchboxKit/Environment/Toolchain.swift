import Foundation

/// The bundled tools described by `<Contents>/Resources/toolchain.json`.
public struct Toolchain: Sendable {
    /// The `Glitchbox.app/Contents` directory.
    public let contents: URL
    public let digest: String
    /// Bundled tool versions by name.
    public let tools: [String: String]
    /// Expanded toolchain.json `path`; searched before the library pipelines and system dirs.
    public let path: [String]
    /// Expanded toolchain.json `environment`.
    public let environment: [String: String]

    /// Parent variables a tool environment inherits (plus every `LC_*`); all others are dropped.
    public static let passThroughKeys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "TERM"]
    public static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func manifestURL(contents: URL) -> URL {
        contents.appending(path: "Resources/toolchain.json")
    }

    private struct File: Decodable {
        var schema: Int
        var digest: String
        var tools: [String: String]?
        var path: [String]
        var environment: [String: String]?
    }

    /// Reads toolchain.json, expanding `@contents` and `@cache` in its strings.
    public static func load(contents: URL, cacheDir: URL) throws -> Toolchain {
        let contents = contents.standardizedFileURL
        let url = manifestURL(contents: contents)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolchainError.missing(url) }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        } catch {
            throw ToolchainError.invalid(url, Workspace.describe(error))
        }
        guard file.schema == 1 else { throw ToolchainError.invalid(url, "schema must be 1 (got \(file.schema))") }
        guard !file.digest.isEmpty else { throw ToolchainError.invalid(url, "digest is empty") }

        let contentsPath = contents.path
        let cachePath = cacheDir.standardizedFileURL.path
        // One pass, so an expanded path that happens to contain "@cache" stays intact.
        func expand(_ s: String) -> String {
            s.replacing(/@(contents|cache)/) { $0.1 == "contents" ? contentsPath : cachePath }
        }
        return Toolchain(contents: contents, digest: file.digest, tools: file.tools ?? [:],
                         path: file.path.map(expand),
                         environment: (file.environment ?? [:]).mapValues(expand))
    }

    /// The hermetic tool environment for a base library at `base`.
    public func toolEnvironment(base: URL, parent: [String: String]) -> ToolEnvironment {
        let base = base.standardizedFileURL
        var own = environment
        own["PATH"] = (path + [base.appending(path: "pipelines").path] + Self.systemPath).joined(separator: ":")
        own["GLITCHBOX_ROOT"] = base.path
        own["GLITCHBOX_TOOLCHAIN"] = contents.path
        let passThrough = parent.filter { Self.passThroughKeys.contains($0.key) || $0.key.hasPrefix("LC_") }
        return ToolEnvironment(own: own, passThrough: passThrough, digest: digest)
    }

    /// `explicit` → `$GLITCHBOX_TOOLCHAIN` → `<executable>/../..` → `<root>/build/Glitchbox.app/Contents`.
    /// Returns a `Contents` dir; `load` reports a missing toolchain.json there.
    public static func locate(explicit: URL?, environment: [String: String], executable: URL?, root: URL) -> URL {
        if let explicit { return explicit.standardizedFileURL }
        var candidates: [URL] = []
        if let env = environment["GLITCHBOX_TOOLCHAIN"], !env.isEmpty {
            candidates.append(URL(filePath: env, directoryHint: .isDirectory))
        }
        if let executable {
            candidates.append(executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent())
        }
        let fm = FileManager.default
        if let found = candidates.first(where: { fm.fileExists(atPath: manifestURL(contents: $0).path) }) {
            return found.standardizedFileURL
        }
        return root.appending(path: "build/Glitchbox.app/Contents", directoryHint: .isDirectory).standardizedFileURL
    }
}
