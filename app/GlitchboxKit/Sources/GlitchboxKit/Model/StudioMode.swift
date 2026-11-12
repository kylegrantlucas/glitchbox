/// The app's two views of one session: Simple (looks and a few sliders) or Advanced (library, stack, inspector).
public enum StudioMode: String, Codable, Sendable, CaseIterable {
    case simple, advanced
}
