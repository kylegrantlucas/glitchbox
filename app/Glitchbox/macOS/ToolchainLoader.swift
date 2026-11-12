import Foundation
import GlitchboxKit

/// Loads `Contents/Resources/toolchain.json`; tools run as child processes.
enum ToolchainLoader {
    static func load(workspace: Workspace, paths: AppPaths) -> EnvState {
        guard RootLocator.isRoot(workspace.base) else {
            return .failed("no Glitchbox library at \(workspace.base.path) (needs plugins/ and pipelines/_lib.sh)")
        }
        do {
            let toolchain = try Toolchain.load(contents: paths.toolchain, cacheDir: workspace.cache)
            return .ready(toolchain.toolEnvironment(base: workspace.base, parent: ProcessInfo.processInfo.environment))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
