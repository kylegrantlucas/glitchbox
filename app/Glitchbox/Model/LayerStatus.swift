enum LayerStatus: Hashable {
    case idle
    case unavailable(String)
    case running(step: Int, of: Int, name: String)
    case done(cached: Bool)
    case failed(String)
    case disabled
}
