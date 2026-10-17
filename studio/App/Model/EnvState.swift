import VideobedKit

enum EnvState {
    case resolving
    case ready(ToolEnvironment)
    case failed(String)

    var environment: ToolEnvironment? {
        if case .ready(let env) = self { return env }
        return nil
    }
}
