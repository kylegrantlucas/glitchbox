import GlitchboxKit

enum EnvState {
    case ready(ToolEnvironment)
    /// The toolchain or base library could not be loaded.
    case failed(String)

    var environment: ToolEnvironment? {
        if case .ready(let env) = self { return env }
        return nil
    }
}
