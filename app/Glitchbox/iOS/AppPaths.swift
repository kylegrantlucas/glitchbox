import Foundation
import GlitchboxInProcess
import GlitchboxKit

/// Where the running app finds its base library and toolchain.
struct AppPaths {
    /// Base (read-only) library root: `Glitchbox.app/Toolchain/library`.
    let base: URL
    /// `Glitchbox.app/Toolchain`, holding `toolchain.json`, `ffglitch-scripts/`,
    /// `bender-presets/`, `licenses/` and `Credits.html` (staged by packaging/build.sh).
    let toolchain: URL

    static func current(bundle: Bundle = .main) -> AppPaths {
        let toolchain = bundle.bundleURL.appending(path: "Toolchain", directoryHint: .isDirectory)
        return AppPaths(base: toolchain.appending(path: "library", directoryHint: .isDirectory), toolchain: toolchain)
    }

    var manifest: URL { toolchain.appending(path: "toolchain.json") }
    var licenses: URL { toolchain.appending(path: "licenses", directoryHint: .isDirectory) }
    var credits: URL { toolchain.appending(path: "Credits.html") }
}

/// Loads `Glitchbox.app/Toolchain/toolchain.json`; tools run in-process (iOS cannot spawn).
enum ToolchainLoader {
    static func load(workspace: Workspace, paths: AppPaths) -> EnvState {
        guard RootLocator.isRoot(workspace.base) else {
            return .failed("no Glitchbox library at \(workspace.base.path) (needs plugins/ and pipelines/_lib.sh)")
        }
        do {
            let toolchain = try Toolchain.load(manifest: paths.manifest, contents: paths.toolchain, cacheDir: workspace.cache)
            return .ready(toolchain.toolEnvironment(base: workspace.base, parent: ProcessInfo.processInfo.environment,
                                                    runner: InProcessRunner()))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
